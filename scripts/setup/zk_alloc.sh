#!/usr/bin/env bash
# Server setup script for zk-alloc experiments on Hetzner AX42-U
# Run once after provisioning: bash setup_zk_alloc.sh
# Assumes: Ubuntu 22.04/24.04, user with sudo, GitHub SSH key configured
#
# What this sets up:
#   - System packages + Rust toolchain
#   - zk-autoresearch repo (experiment logs, bench crate, reference repos)
#   - leanVM on zk-alloc-integration branch
#   - zk-alloc crate (standalone git repo under leanVM/)
#   - Reference repos: mimalloc, snmalloc (shallow clones)
#   - cgroup for 16GB memory pressure simulation
#   - Criterion + eval_paired.sh benchmarking infrastructure

set -euo pipefail

echo "=== zk-alloc Experiment Setup ==="
echo ""

# ── 1. System packages ──────────────────────────────────────────────────────
echo "[1/9] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libssl-dev \
    git \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    tmux \
    htop \
    perf-tools-unstable \
    linux-tools-common \
    linux-tools-generic \
    cgroup-tools \
    numactl

# ── 2. Rust toolchain ───────────────────────────────────────────────────────
echo ""
echo "[2/9] Installing Rust..."
if command -v rustup &>/dev/null; then
    echo "  rustup already installed, updating..."
    rustup update stable
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
fi

rustup toolchain install nightly --profile minimal
echo "  Rust version: $(rustc --version)"

# ── 3. Clone repos ──────────────────────────────────────────────────────────
echo ""
echo "[3/9] Cloning repositories..."
WORK_DIR="$HOME/zk-autoresearch"

if [ ! -d "$WORK_DIR" ]; then
    git clone git@github.com:Barnadrot/zk-autoresearch.git "$WORK_DIR"
fi
cd "$WORK_DIR"

# leanVM (upstream + myfork)
if [ ! -d "$WORK_DIR/leanVM" ]; then
    git clone git@github.com:Barnadrot/leanVM.git "$WORK_DIR/leanVM"
fi
cd "$WORK_DIR/leanVM"
git remote add myfork git@github.com:Barnadrot/leanVM.git 2>/dev/null || true
git fetch myfork
git checkout zk-alloc-integration 2>/dev/null || git checkout -b zk-alloc-integration myfork/zk-alloc-integration

# zk-alloc (standalone repo, lives under leanVM/)
if [ ! -d "$WORK_DIR/leanVM/zk-alloc" ]; then
    git clone git@github.com:Barnadrot/zk-alloc.git "$WORK_DIR/leanVM/zk-alloc"
fi

# Reference repos (shallow, read-only)
cd "$WORK_DIR"
if [ ! -d "$WORK_DIR/mimalloc" ]; then
    git clone --depth 1 https://github.com/microsoft/mimalloc.git
fi
if [ ! -d "$WORK_DIR/snmalloc" ]; then
    git clone --depth 1 https://github.com/microsoft/snmalloc.git
fi

echo "  Repos ready."

# ── 4. Git config ───────────────────────────────────────────────────────────
echo ""
echo "[4/9] Configuring git..."
cd "$WORK_DIR/leanVM"
git config user.email "autoresearch@local" || true
git config user.name "ZK Autoresearch" || true

cd "$WORK_DIR/leanVM/zk-alloc"
git config user.email "autoresearch@local" || true
git config user.name "ZK Autoresearch" || true

# ── 5. CPU feature check ────────────────────────────────────────────────────
echo ""
echo "[5/9] CPU feature check..."
echo "  CPU: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
echo "  Cores: $(nproc) ($(lscpu | grep 'Thread(s) per core' | awk '{print $NF}') threads/core)"
echo "  RAM: $(free -g | awk '/Mem:/ {print $2}') GB"

if grep -q avx2 /proc/cpuinfo; then
    echo "  AVX2:   YES"
else
    echo "  AVX2:   NO (performance will be degraded)"
fi
if grep -q avx512f /proc/cpuinfo; then
    echo "  AVX512: YES"
else
    echo "  AVX512: not detected"
fi

# NUMA topology
if command -v numactl &>/dev/null; then
    echo "  NUMA nodes: $(numactl --hardware 2>/dev/null | grep 'available' | awk '{print $2}')"
fi

# ── 6. cgroup setup for memory pressure simulation ──────────────────────────
echo ""
echo "[6/9] Setting up cgroup for 16GB memory pressure..."

# cgroups v2 (Ubuntu 22.04+)
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "  cgroups v2 detected"
    sudo mkdir -p /sys/fs/cgroup/bench16g
    echo "16G" | sudo tee /sys/fs/cgroup/bench16g/memory.max > /dev/null
    echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control > /dev/null 2>&1 || true
    echo "  Created: /sys/fs/cgroup/bench16g (memory.max=16G)"
    echo ""
    echo "  Usage:"
    echo "    # Run under 16GB pressure:"
    echo "    sudo bash -c 'echo \$\$ > /sys/fs/cgroup/bench16g/cgroup.procs && exec sudo -u $USER bash eval_paired.sh'"
    echo ""
    echo "    # Or with cgexec (if available):"
    echo "    sudo cgexec -g memory:bench16g bash eval_paired.sh"
else
    echo "  cgroups v1 detected"
    sudo cgcreate -g memory:bench16g 2>/dev/null || true
    echo 16G | sudo tee /sys/fs/cgroup/memory/bench16g/memory.limit_in_bytes > /dev/null 2>/dev/null || true
    echo "  Created: memory:bench16g (16G limit)"
fi

# ── 7. Pre-compile ──────────────────────────────────────────────────────────
echo ""
echo "[7/9] Pre-compiling leanVM (first build is slow — ~3min)..."
cd "$WORK_DIR/leanVM"

# Build without zkalloc (glibc baseline)
echo "  Building glibc baseline..."
cargo build --release 2>&1 | tail -3

# Build with zkalloc
echo "  Building with zk-alloc..."
cargo build --release --features zkalloc 2>&1 | tail -3

# ── 8. Run correctness tests ────────────────────────────────────────────────
echo ""
echo "[8/9] Running correctness tests..."

echo "  zk-alloc unit tests..."
cd "$WORK_DIR/leanVM/zk-alloc"
cargo test 2>&1 | tail -3

echo "  leanVM integration tests (glibc)..."
cd "$WORK_DIR/leanVM"
cargo test --release --test test_lean_multisig 2>&1 | tail -3

echo "  leanVM integration tests (zkalloc)..."
cargo test --release --features zkalloc --test test_lean_multisig 2>&1 | tail -3

# ── 9. Python environment for experiment loop ───────────────────────────────
echo ""
echo "[9/9] Setting up Python environment..."
cd "$WORK_DIR"
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
pip install --quiet --upgrade pip
if [ -f requirements.txt ]; then
    pip install --quiet -r requirements.txt
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
echo ""
echo "Repos:"
echo "  leanVM:  $WORK_DIR/leanVM (branch: zk-alloc-integration)"
echo "  zk-alloc:      $WORK_DIR/leanVM/zk-alloc"
echo "  experiment logs: $WORK_DIR/experiment_logs/zk-alloc/"
echo "  mimalloc (ref):  $WORK_DIR/mimalloc"
echo "  snmalloc (ref):  $WORK_DIR/snmalloc"
echo ""
echo "Benchmarking:"
echo "  # Criterion (glibc baseline vs zk-alloc)"
echo "  cd leanVM && N=3 bash ../leanVM-bench/eval_paired.sh"
echo ""
echo "  # Production (glibc vs zk-alloc)"
echo "  bash reproduce_prod.sh"
echo ""
echo "  # Under 16GB memory pressure (cgroups v2):"
echo "  sudo bash -c 'echo \$\$ > /sys/fs/cgroup/bench16g/cgroup.procs && exec sudo -u $USER bash eval_paired.sh'"
echo ""
echo "Experiments:"
echo "  exp1_scaffold  — make zk-alloc correct (in progress)"
echo "  exp2_baseline  — match glibc performance"
echo "  exp3_contention — beat glibc on contention (-10%+ target)"
echo "  exp4_pressure  — solve 16GB/64GB tradeoff"
echo "  exp5_phase     — phase-aware bulk deallocation"
echo ""
echo "Next: run exp1_scaffold to fix memory safety bugs in zk-alloc"
