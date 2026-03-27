#!/usr/bin/env bash
# Server setup script for ZK Autoresearch on Hetzner CCX33
# Run once after provisioning: bash setup.sh
# Assumes: Ubuntu 22.04/24.04, user with sudo

set -euo pipefail

echo "=== ZK Autoresearch Setup ==="
echo ""

# ── 1. System packages ────────────────────────────────────────────────────────
echo "[1/5] Installing system packages..."
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
    htop

# ── 2. Rust (stable, edition 2024 requires ≥1.85) ────────────────────────────
echo ""
echo "[2/5] Installing Rust..."
if command -v rustup &>/dev/null; then
    echo "  rustup already installed, updating..."
    rustup update stable
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
fi

# Nightly only needed for rustfmt
rustup toolchain install nightly --profile minimal

echo "  Rust version: $(rustc --version)"

# ── 3. Python virtual environment ─────────────────────────────────────────────
echo ""
echo "[3/5] Setting up Python venv..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
echo "  anthropic SDK installed: $(python3 -c 'import anthropic; print(anthropic.__version__)')"

# ── 4. Git config for experiment commits ──────────────────────────────────────
echo ""
echo "[4/5] Configuring git in Plonky3/..."
cd "$SCRIPT_DIR/Plonky3"
git config user.email "autoresearch@local" || true
git config user.name "ZK Autoresearch" || true
# Tag the clean starting point
git tag -f baseline HEAD 2>/dev/null || true
echo "  Git baseline tag set at $(git rev-parse --short HEAD)"

# ── 5. Verify AVX support ─────────────────────────────────────────────────────
echo ""
echo "[5/5] CPU feature check..."
if grep -q avx2 /proc/cpuinfo; then
    echo "  AVX2:   YES"
else
    echo "  AVX2:   NO (performance will be degraded)"
fi
if grep -q avx512f /proc/cpuinfo; then
    echo "  AVX512: YES"
else
    echo "  AVX512: not detected (AVX2 path will be used)"
fi

# ── 6. First compile (populates cargo cache) ──────────────────────────────────
echo ""
echo "[6/6] Pre-compiling Plonky3 (first compile is slow — ~5min)..."
cd "$SCRIPT_DIR/Plonky3"
cargo build -p p3-dft --features p3-dft/parallel --release 2>&1 | tail -5

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. export ANTHROPIC_API_KEY=sk-ant-..."
echo "  2. source .venv/bin/activate"
echo "  3. Run a quick bench sanity check:"
echo "       cd Plonky3 && bash bench.sh"
echo "  4. Start the loop in tmux:"
echo "       tmux new -s autoresearch"
echo "       python3 loop.py"
echo "       # Ctrl+B D to detach"
echo ""
echo "  Monitor progress:"
echo "       tail -f experiments.jsonl | python3 watch.py"
echo "       tmux attach -t autoresearch"
echo ""
echo "  Graceful stop: touch STOP"
