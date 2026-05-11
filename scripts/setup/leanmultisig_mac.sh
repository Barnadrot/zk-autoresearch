#!/bin/bash
# Provisioning for Apple Silicon Asahi Linux (Fedora-based, aarch64).
# Mirrors leanmultisig.sh but uses dnf + arm64 binaries.
set -e

echo "=== Verifying environment ==="
. /etc/os-release
if [[ "$ID" != "fedora-asahi-remix" && "$ID_LIKE" != *"fedora"* ]]; then
    echo "WARNING: expected Fedora-Asahi, got $ID. Proceeding anyway."
fi
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    echo "ERROR: this script targets aarch64; got $ARCH. Use leanmultisig.sh on x86_64."
    exit 1
fi
echo "OS: $PRETTY_NAME, arch: $ARCH, page size: $(getconf PAGESIZE)"

echo "=== Installing system dependencies ==="
sudo dnf install -y \
    @development-tools \
    git curl wget tmux \
    pkgconf-pkg-config \
    openssl-devel \
    protobuf-compiler \
    clang clang-libs clang-devel \
    perf \
    util-linux \
    cmake \
    nano vim less

echo "=== Installing Rust ==="
if [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
. "$HOME/.cargo/env"
rustup toolchain install nightly
rustup component add rustfmt clippy

echo "=== Installing Go (aarch64) ==="
if ! command -v go &>/dev/null; then
    GO_VERSION=1.22.3
    cd /tmp
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz"
    sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-arm64.tar.gz"
    rm "go${GO_VERSION}.linux-arm64.tar.gz"
fi

echo "=== Installing Claude CLI ==="
curl -fsSL https://claude.ai/install.sh | bash

echo "=== Installing GitHub CLI ==="
sudo dnf install -y 'dnf-command(config-manager)'
sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh

echo "=== Cloning repos ==="
mkdir -p ~/zk-autoresearch
cd ~
if [[ ! -d zk-autoresearch/.git ]]; then
    rm -rf zk-autoresearch  # in case dir exists empty
    git clone https://github.com/Barnadrot/zk-autoresearch
fi
cd ~/zk-autoresearch
[[ -d leanMultisig ]] || git clone https://github.com/leanEthereum/leanMultisig
[[ -d Plonky3 ]]      || git clone https://github.com/Plonky3/Plonky3
[[ -d jolt ]]         || git clone https://github.com/a16z/jolt
[[ -d zk-alloc ]]     || git clone https://github.com/Barnadrot/zk-alloc
# SP1 omitted: requires CUDA + custom toolchain, irrelevant on Apple Silicon.

echo "=== Setting environment variables ==="
if ! grep -q "zk-autoresearch" ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc << 'EOF'

# zk-autoresearch (Asahi)
export RUSTFLAGS="-C target-cpu=native"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
EOF
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

echo "=== Pre-building leanMultisig (release) ==="
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo build --release

echo "=== Setting git identity ==="
git config --global user.name "Barnadrot"
git config --global user.email "kbarna.drot@gmail.com"

echo "=== Enabling perf for unprivileged use ==="
sudo sysctl -w kernel.perf_event_paranoid=-1 || \
    echo "  (warning: perf_event_paranoid sysctl write failed; perf may need sudo)"
echo "kernel.perf_event_paranoid = -1" | sudo tee /etc/sysctl.d/99-perf.conf >/dev/null

echo ""
echo "=== Done ==="
echo ""
echo "Next manual steps (require interactive login):"
echo "  1. claude login           # browser OAuth"
echo "  2. gh auth login          # browser OAuth"
echo "  3. claude --version && gh --version  # verify both work"
echo "  4. tmux new -s mac-perf   # start a tmux for the agent"
echo ""
echo "Then send the agent's program.md as the initial prompt."
