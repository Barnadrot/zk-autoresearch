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

echo "=== Installing Go (required for SP1) ==="
wget -q https://go.dev/dl/go1.22.3.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.3.linux-amd64.tar.gz
rm go1.22.3.linux-amd64.tar.gz
echo 'export PATH="$PATH:/usr/local/go/bin"' >> ~/.bashrc
export PATH="$PATH:/usr/local/go/bin"

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
git clone https://github.com/leanEthereum/leanMultisig
git clone https://github.com/Plonky3/Plonky3
git clone https://github.com/a16z/jolt
git clone https://github.com/succinctlabs/sp1

echo "=== Setting environment variables ==="
cat >> ~/.bashrc << 'EOF'

# zk-autoresearch
export RUSTFLAGS="-C target-cpu=native"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
EOF
source ~/.bashrc

echo "=== Pre-building leanMultisig (release) ==="
cd ~/zk-autoresearch/leanMultisig
cargo build --release

echo "=== Pre-building Plonky3 (release) ==="
cd ~/zk-autoresearch/Plonky3
cargo build --release

echo "=== Pre-building Jolt (release) ==="
cd ~/zk-autoresearch/jolt
cargo build --release

# SP1 requires CUDA (GPU) and the 'succinct' custom Rust toolchain for its zkVM programs.
# On CPU-only servers it fails to link. Clone is kept for source reference — agent reads files.
# To build SP1: install succinct toolchain + CUDA toolkit first.

echo "=== Setting git identity ==="
git config --global user.name "Barnadrot"
git config --global user.email "kbarna.drot@gmail.com"

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. claude login"
echo "  2. gh auth login"
echo "  3. sudo sysctl -w kernel.perf_event_paranoid=-1"
echo "  4. source ~/.bashrc   (or open a new shell)"
echo "  5. claude --version && gh --version   (verify both work)"
echo ""
echo "Then start the agent:"
echo "  cd ~/zk-autoresearch && claude --dangerously-skip-permissions"
