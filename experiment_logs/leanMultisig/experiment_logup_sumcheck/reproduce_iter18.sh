#!/bin/bash
# Reproduce iter 18: mimalloc A/B on Criterion bench (expected ~25-33% improvement).
#
# Place this script in the zk-autoresearch/ root and run:
#   chmod +x reproduce_iter18.sh && ./reproduce_iter18.sh
#
# Prerequisites:
#   - Rust toolchain (cargo, rustc)
#   - leanMultisig cloned at ./leanMultisig (the bench crate has path deps to it)
#
# What it does:
#   1. Checks out baseline (c5130b3^, no mimalloc) in zk-autoresearch
#   2. cargo clean + build + bench → saves Criterion baseline
#   3. Checks out candidate (c5130b3, with mimalloc) in zk-autoresearch
#   4. cargo clean + build + bench → Criterion prints the delta
#
# The cargo clean before EACH build is critical. Without it cargo may reuse
# a stale binary from the previous checkout and you compare the same binary
# against itself (this is what caused the first failed reproduction).

set -eo pipefail

BASELINE_REF="c5130b3^"
CANDIDATE_REF="c5130b3"
BENCH_CRATE="leanMultisig-bench"
BENCH_NAME="xmss_leaf"
BASELINE_TAG="iter18_base"

export RUSTFLAGS="-C target-cpu=native"

log() { echo "[reproduce] $*"; }
err() { echo "[reproduce][ERROR] $*" >&2; }

# ── Sanity checks ──────────────────────────────────────────────────────

if [[ ! -d "$BENCH_CRATE" ]]; then
  err "Run this script from the zk-autoresearch root (expected ./$BENCH_CRATE to exist)"
  exit 2
fi

if [[ ! -d "leanMultisig" ]]; then
  err "leanMultisig/ not found. Clone it first:"
  err "  git clone https://github.com/Barnadrot/leanMultisig.git"
  exit 2
fi

# Save current state to restore on exit
ORIG_HEAD=$(git rev-parse HEAD)
ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Stash ALL local changes first so git checkout won't fail
log "stashing local changes (will restore on exit)..."
git stash --quiet || { err "git stash failed — check for permission issues in untracked files"; exit 2; }
STASHED_GIT=1

# Move pgo_runner.rs and trace_runner.rs out of the way if they exist —
# they reference mimalloc and won't compile against the baseline commit.
STASHED_FILES=()
for f in "$BENCH_CRATE/src/bin/pgo_runner.rs" "$BENCH_CRATE/src/bin/trace_runner.rs"; do
  if [[ -f "$f" ]]; then
    mv "$f" "$f.bak"
    STASHED_FILES+=("$f")
    log "stashed $f (would break baseline build)"
  fi
done
restore_stashed() {
  for f in "${STASHED_FILES[@]}"; do
    [[ -f "$f.bak" ]] && mv "$f.bak" "$f"
  done
}

cleanup() {
  restore_stashed
  log "restoring git state..."
  git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true
  [[ "${STASHED_GIT:-0}" == "1" ]] && git stash pop --quiet 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 1: Build & run BASELINE ───────────────────────────────────────

log "checking out BASELINE ($BASELINE_REF)..."
git checkout --quiet "$BASELINE_REF"

log "cleaning bench crate (this is required!)..."
(cd "$BENCH_CRATE" && cargo clean)

log "building + running BASELINE bench (this takes ~5-10 min)..."
(cd "$BENCH_CRATE" && cargo bench --bench "$BENCH_NAME" -- --save-baseline "$BASELINE_TAG")

# Grab binary hash for the guard check
BASE_BIN=$(ls -t "$BENCH_CRATE"/target/release/deps/${BENCH_NAME}-* 2>/dev/null | grep -v '\.d$' | head -1)
HASH_BASE=$(md5sum "$BASE_BIN" 2>/dev/null | awk '{print $1}')
log "baseline binary hash: $HASH_BASE"

# ── Step 2: Build & run CANDIDATE ──────────────────────────────────────

# Preserve Criterion baseline data before cleaning
log "saving criterion baseline data..."
cp -r "$BENCH_CRATE/target/criterion" /tmp/criterion_iter18_backup

log "checking out CANDIDATE ($CANDIDATE_REF)..."
git checkout --quiet "$CANDIDATE_REF"

log "cleaning bench crate (this is required!)..."
(cd "$BENCH_CRATE" && cargo clean)

# Restore Criterion baseline data after clean
mkdir -p "$BENCH_CRATE/target"
cp -r /tmp/criterion_iter18_backup "$BENCH_CRATE/target/criterion"

log "building + running CANDIDATE bench (this takes ~5-10 min)..."
(cd "$BENCH_CRATE" && cargo bench --bench "$BENCH_NAME" -- --baseline "$BASELINE_TAG")

# Binary hash guard
CAND_BIN=$(ls -t "$BENCH_CRATE"/target/release/deps/${BENCH_NAME}-* 2>/dev/null | grep -v '\.d$' | head -1)
HASH_CAND=$(md5sum "$CAND_BIN" 2>/dev/null | awk '{print $1}')
log "candidate binary hash: $HASH_CAND"

if [[ "$HASH_BASE" == "$HASH_CAND" ]]; then
  err "WARNING: baseline and candidate binaries have IDENTICAL hashes!"
  err "This means cargo reused a stale binary. The result above is invalid."
  err "Try: rm -rf $BENCH_CRATE/target && re-run this script."
  exit 1
fi

echo ""
log "Done. Criterion printed the delta above (look for the 'change: [...]' line)."
log "Expected: approximately -25% to -33% improvement."
