#!/usr/bin/env bash
# leanVM setup for macOS on Apple Silicon (Sequoia 15.x or newer)
# Works on Scaleway M2-L / M4-M / M4-XL etc.
#
# Usage:
#   bash leanvm-macos.sh
# OR remote:
#   ssh m1@<ip> 'bash -s' < scripts/setup/leanvm-macos.sh
#
# Idempotent: safe to re-run. Skips work that's already done.

set -euo pipefail

echo "=== leanVM macOS setup ==="
echo "Host: $(hostname) | macOS: $(sw_vers -productVersion) | Arch: $(uname -m)"
echo

# ── 1. Xcode Command Line Tools ───────────────────────────────────────────────
echo "[1/8] Xcode Command Line Tools..."
if xcode-select -p &>/dev/null; then
  echo "  already installed at $(xcode-select -p)"
else
  echo "  installing — accept the GUI prompt that appears"
  xcode-select --install || true
  # Wait for install to complete (non-interactive — caller should re-run if this fails)
  until xcode-select -p &>/dev/null; do sleep 5; done
fi

# ── 2. Homebrew ───────────────────────────────────────────────────────────────
echo "[2/8] Homebrew..."
if ! command -v brew &>/dev/null; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    < /dev/null
fi
# Ensure brew is in PATH for current shell + future shells
if [ -x /opt/homebrew/bin/brew ]; then
  BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
  BREW=/usr/local/bin/brew
else
  echo "  brew not found after install; aborting"
  exit 1
fi
eval "$($BREW shellenv)"
echo "  brew: $($BREW --version | head -1)"

# Persist brew + cargo + ~/.local/bin in shell rc files.
# IMPORTANT: ~/.zprofile is what zsh login shells (including non-interactive `ssh host "cmd"`)
# source. Without it the coordinator's ssh+tmux dispatch can't find brew/claude on PATH.
for RC in ~/.zprofile ~/.zshrc ~/.bash_profile; do
  touch "$RC"
  grep -q 'brew shellenv' "$RC" || echo "eval \"\$($BREW shellenv)\"" >> "$RC"
  grep -q 'cargo/env' "$RC" || echo '[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"' >> "$RC"
  grep -q '\.local/bin' "$RC" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
  grep -q 'RUSTFLAGS' "$RC" || echo 'export RUSTFLAGS="-C target-cpu=native"' >> "$RC"
done

# ── 3. Brew packages ──────────────────────────────────────────────────────────
echo "[3/8] Brew packages (git, tmux, htop, gh, pkg-config, jq)..."
$BREW install --quiet git tmux htop gh pkg-config jq || true

# ── 4. Rust (stable + nightly for rustfmt) ────────────────────────────────────
echo "[4/8] Rust..."
if command -v rustup &>/dev/null; then
  rustup update stable
else
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
  source "$HOME/.cargo/env"
fi
rustup component add rustfmt clippy --toolchain stable
rustup toolchain install nightly --profile minimal
echo "  $(rustc --version)"

# ── 5. Claude CLI ─────────────────────────────────────────────────────────────
echo "[5/8] Claude CLI..."
if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
fi
echo "  claude: $(claude --version 2>/dev/null || echo 'install path may need ~/.local/bin in PATH')"

# ── 6. Clone repos ────────────────────────────────────────────────────────────
echo "[6/8] Cloning repos..."
cd ~
if [ ! -d zk-autoresearch ]; then
  git clone https://github.com/Barnadrot/zk-autoresearch
fi
cd ~/zk-autoresearch
for repo_url in \
    "https://github.com/leanEthereum/leanVM" \
    "https://github.com/Plonky3/Plonky3" \
    "https://github.com/Barnadrot/zk-alloc"; do
  dir=$(basename "$repo_url")
  if [ ! -d "$dir" ]; then
    git clone --quiet "$repo_url"
    echo "  cloned $dir"
  else
    echo "  $dir exists, skipping"
  fi
done

# ── 7. Git identity ──────────────────────────────────────────────────────────
echo "[7/8] Git identity..."
git config --global user.name "Barnadrot"
git config --global user.email "kbarna.drot@gmail.com"

# ── 8. Pre-build leanVM (release, target-cpu=native) ───────────────────
echo "[8/8] Pre-building leanVM (~5-10 min first time)..."
cd ~/zk-autoresearch/leanVM
export RUSTFLAGS="-C target-cpu=native"
cargo build --release 2>&1 | tail -5 || echo "  build failed — investigate manually"

echo
echo "=== Setup complete ==="
echo
echo "Profiling note: macOS has no \`perf\`. Use:"
echo "  - \`sample <pid> 10\` — quick stack sample, no setup"
echo "  - \`xcrun xctrace record --template 'Time Profiler' --output trace.trace --launch <bin>\` — Instruments equivalent"
echo "  - \`sudo dtrace\` — kernel-level tracing (requires SIP-disabled or signed binaries)"
echo
echo "To start interactive Claude:"
echo "  cd ~/zk-autoresearch && claude --dangerously-skip-permissions"
echo
echo "To run a quick prove_loop benchmark:"
echo "  cd ~/zk-autoresearch/harness/leanvm/bench"
echo "  cargo build --release --bin prove_loop --features zkalloc_global"
echo "  /usr/bin/time -lp target/release/prove_loop 5"
