#!/bin/bash
set -e

echo "=== Installing system dependencies ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    git \
    curl \
    tmux \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    libclang-dev \
    linux-tools-common \
    linux-tools-generic \
    linux-tools-$(uname -r)

echo "=== Installing Rust ==="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly
rustup component add rustfmt clippy

echo "=== Installing Go 1.25.7 ==="
wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz
rm go1.25.7.linux-amd64.tar.gz
echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' >> ~/.bashrc
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"

echo "=== Installing Go tools ==="
go install golang.org/x/perf/cmd/benchstat@latest

echo "=== Enabling Transparent Huge Pages ==="
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
# Make persistent across reboots
echo 'echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled' | sudo tee /etc/rc.local
sudo chmod +x /etc/rc.local

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

# Linea prover + gnark-crypto (primary targets)
git clone https://github.com/Consensys/linea-monorepo
git clone https://github.com/Consensys/gnark-crypto

# Reference repos
git clone https://github.com/leanEthereum/leanMultisig
git clone https://github.com/Plonky3/Plonky3
git clone https://github.com/a16z/jolt
git clone https://github.com/succinctlabs/sp1

echo "=== Setting up Linea prover ==="
cd ~/zk-autoresearch/linea-monorepo
git fetch origin prover/dev-small-fields
git checkout prover/dev-small-fields
cd prover

# Wire gnark-crypto fork via replace directive
echo "" >> go.mod
echo "replace github.com/consensys/gnark-crypto => ../../gnark-crypto" >> go.mod

# Verify compilation
go build ./crypto/vortex/...
echo "Linea prover vortex package compiles OK"

# Run correctness gate to verify
bash ~/zk-autoresearch/experiment_logs/linea/shared/correctness.sh
echo "Correctness gate passes"

# Save initial benchmark baseline
echo "=== Saving benchmark baseline (both tiers, ~11 min) ==="
bash ~/zk-autoresearch/experiment_logs/linea/shared/eval_bench.sh --save-baseline

echo "=== Setting environment variables ==="
cat >> ~/.bashrc << 'EOF'

# zk-autoresearch — linea
export RUSTFLAGS="-C target-cpu=native"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
EOF
source ~/.bashrc

echo "=== Pre-building reference repos (release) ==="
cd ~/zk-autoresearch/leanMultisig
cargo build --release

cd ~/zk-autoresearch/Plonky3
cargo build --release

cd ~/zk-autoresearch/jolt
cargo build --release

# SP1 requires CUDA (GPU) and the 'succinct' custom Rust toolchain.
# On CPU-only servers it fails to link. Clone is kept for source reference.

echo "=== Setting git identity ==="
git config --global user.name "Barnadrot"
git config --global user.email "kbarna.drot@gmail.com"

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. claude login"
echo "  2. gh auth login"
echo "  3. source ~/.bashrc   (or open a new shell)"
echo "  4. claude --version && gh --version   (verify both work)"
echo ""
echo "Verify setup:"
echo "  cat /sys/kernel/mm/transparent_hugepage/enabled   (should show [always])"
echo "  go version                                        (should show 1.25.7)"
echo "  benchstat --help                                  (should work)"
echo "  ls ~/linea-bench/baseline_tier*.txt               (baselines saved)"
echo ""
echo "Then start the agent:"
echo "  cd ~/zk-autoresearch && claude --dangerously-skip-permissions"
