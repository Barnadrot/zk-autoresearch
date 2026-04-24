#!/bin/bash
# Server setup for zk-alloc experiments on Hetzner AX42-U (bare metal)
# Run once after provisioning: bash setup_zk_alloc_server.sh
# Assumes: Ubuntu 22.04/24.04, user with sudo
set -e

echo "=== Installing system dependencies ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    git \
    curl \
    tmux \
    htop \
    pkg-config \
    libssl-dev \
    libclang-dev \
    linux-tools-common \
    linux-tools-generic \
    linux-tools-$(uname -r) \
    cgroup-tools \
    numactl

echo "=== Installing Rust ==="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly
rustup component add rustfmt clippy

echo "=== Installing Claude CLI ==="
curl -fsSL https://claude.ai/install.sh | bash

echo "=== Installing GitHub CLI ==="
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

echo "=== Cloning repos ==="
cd ~
git clone https://github.com/Barnadrot/zk-autoresearch
cd ~/zk-autoresearch
git checkout zk-alloc-exp
git clone https://github.com/leanEthereum/leanMultisig
git clone --depth 1 https://github.com/microsoft/mimalloc
git clone --depth 1 https://github.com/microsoft/snmalloc

echo "=== Downloading glibc malloc source (reference) ==="
mkdir -p ~/zk-autoresearch/glibc-malloc
curl -sL "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=malloc/malloc.c;hb=HEAD" -o ~/zk-autoresearch/glibc-malloc/malloc.c
curl -sL "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=malloc/arena.c;hb=HEAD" -o ~/zk-autoresearch/glibc-malloc/arena.c
curl -sL "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=malloc/malloc-internal.h;hb=HEAD" -o ~/zk-autoresearch/glibc-malloc/malloc-internal.h

echo "=== Cloning SP1 (reference: guest bump allocator) ==="
git clone --depth 1 --filter=blob:none --sparse https://github.com/succinctlabs/sp1.git
cd ~/zk-autoresearch/sp1
git sparse-checkout set crates/zkvm/entrypoint/src/allocators
cd ~/zk-autoresearch

echo "=== Setting up leanMultisig ==="
cd ~/zk-autoresearch/leanMultisig
git remote add myfork https://github.com/Barnadrot/leanMultisig.git
git fetch myfork
git checkout -b zk-alloc-integration myfork/zk-alloc-integration

echo "=== Cloning zk-alloc ==="
git clone https://github.com/Barnadrot/zk-alloc.git ~/zk-autoresearch/leanMultisig/zk-alloc

echo "=== Setting environment variables ==="
cat >> ~/.bashrc << 'EOF'

# zk-autoresearch
export RUSTFLAGS="-C target-cpu=native"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
EOF
source ~/.bashrc

echo "=== Setting git identity ==="
git config --global user.name "Barnadrot"
git config --global user.email "kbarna.drot@gmail.com"

echo "=== Setting up cgroup for 16GB memory pressure (used in exp4+) ==="
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "  cgroups v2 detected"
    sudo mkdir -p /sys/fs/cgroup/bench16g
    echo "16G" | sudo tee /sys/fs/cgroup/bench16g/memory.max > /dev/null
    echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control > /dev/null 2>&1 || true
    echo "  bench16g cgroup created (memory.max=16G)"
else
    echo "  cgroups v1 detected"
    sudo cgcreate -g memory:bench16g 2>/dev/null || true
    echo 16G | sudo tee /sys/fs/cgroup/memory/bench16g/memory.limit_in_bytes > /dev/null 2>/dev/null || true
    echo "  bench16g cgroup created (16G limit)"
fi

echo "=== Pre-building leanMultisig (release) ==="
cd ~/zk-autoresearch/leanMultisig
cargo build --release
cargo build --release --features zkalloc

echo "=== Running correctness tests ==="
echo "  zk-alloc unit tests..."
cd ~/zk-autoresearch/leanMultisig/zk-alloc
cargo test 2>&1 | tail -3

echo "  leanMultisig integration tests (glibc)..."
cd ~/zk-autoresearch/leanMultisig
cargo test --release --test test_lean_multisig 2>&1 | tail -3

echo "  leanMultisig integration tests (zkalloc)..."
cargo test --release --features zkalloc --test test_lean_multisig 2>&1 | tail -3

echo "=== CPU/Memory info ==="
echo "  CPU: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
echo "  Cores: $(nproc)"
echo "  RAM: $(free -g | awk '/Mem:/ {print $2}') GB"
grep -q avx512f /proc/cpuinfo && echo "  AVX512: YES" || echo "  AVX512: NO"
sudo sysctl -w kernel.perf_event_paranoid=-1

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. claude login"
echo "  2. gh auth login"
echo "  3. source ~/.bashrc"
echo ""
echo "Benchmarking:"
echo "  # Criterion glibc vs zk-alloc:"
echo "  cd leanMultisig && N=3 bash ../leanMultisig-bench/eval_paired.sh"
echo ""
echo "  # Under 16GB pressure (cgroups v2):"
echo "  sudo bash -c 'echo \$\$ > /sys/fs/cgroup/bench16g/cgroup.procs && exec sudo -u $USER bash eval_paired.sh'"
echo ""
echo "Start the agent:"
echo "  cd ~/zk-autoresearch && claude --dangerously-skip-permissions"
