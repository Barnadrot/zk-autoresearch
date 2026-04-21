#!/bin/bash
# Reproduce production mimalloc A/B: fancy-aggregation single-invocation.
#
# This measures the real-world production improvement (expected ~25% on c7a.2xlarge).
# Criterion tight-loop shows ~37%; production is slightly lower due to non-allocation overhead.
#
# Run from the zk-autoresearch/ root:
#   chmod +x reproduce_prod.sh && ./reproduce_prod.sh
#
# Prerequisites:
#   - Rust toolchain (cargo, rustc)
#   - leanMultisig cloned at ./leanMultisig

set -eo pipefail

LM_REPO="leanMultisig"
BASELINE_REF="b1a58a8"
CANDIDATE_REF="feat/mimalloc-allocator-clean"
RUNS=${RUNS:-3}  # number of timed runs per variant (median is reported)

export RUSTFLAGS="-C target-cpu=native"

log() { echo "[reproduce-prod] $*"; }
err() { echo "[reproduce-prod][ERROR] $*" >&2; }

# ── Sanity checks ──────────────────────────────────────────────────────

if [[ ! -d "$LM_REPO" ]]; then
  err "leanMultisig/ not found. Clone it first:"
  err "  git clone https://github.com/Barnadrot/leanMultisig.git"
  exit 2
fi

# Save current state
ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
trap 'log "restoring git state..."; cd "'"$LM_REPO"'" && git checkout --quiet "'"$ORIG_BRANCH"'" 2>/dev/null || git checkout --quiet "'"$ORIG_HEAD"'" 2>/dev/null || true' EXIT

# ── Helper: timed run ──────────────────────────────────────────────────

run_fancy() {
  # Runs the pre-built binary directly (not cargo run, which may recompile)
  local start end
  start=$(date +%s.%N)
  (cd "$LM_REPO" && ./target/release/lean-multisig fancy-aggregation) >/dev/null 2>&1
  end=$(date +%s.%N)
  python3 -c "print(f'{$end - $start:.2f}')"
}

# ── Step 1: Build & measure BASELINE ───────────────────────────────────

log "checking out BASELINE ($BASELINE_REF) in $LM_REPO..."
(cd "$LM_REPO" && git checkout --quiet "$BASELINE_REF")

log "cleaning (required to avoid stale binary)..."
(cd "$LM_REPO" && cargo clean)

log "building baseline..."
(cd "$LM_REPO" && cargo build --release) 2>&1

BASE_BIN=$(ls -t "$LM_REPO"/target/release/lean-multisig* 2>/dev/null | grep -v '\.d$' | head -1 || true)
HASH_BASE=$(md5sum "$BASE_BIN" 2>/dev/null | awk '{print $1}' || echo "unknown")
log "baseline binary hash: $HASH_BASE"

BASE_TIMES=()
for ((i=1; i<=RUNS; i++)); do
  log "baseline run $i/$RUNS..."
  t=$(run_fancy)
  BASE_TIMES+=("$t")
  log "  → ${t}s"
done

# ── Step 2: Build & measure CANDIDATE ──────────────────────────────────

log "checking out CANDIDATE ($CANDIDATE_REF) in $LM_REPO..."
(cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_REF")

log "cleaning (required to avoid stale binary)..."
(cd "$LM_REPO" && cargo clean)

log "building candidate..."
(cd "$LM_REPO" && cargo build --release) 2>&1

CAND_BIN=$(ls -t "$LM_REPO"/target/release/lean-multisig* 2>/dev/null | grep -v '\.d$' | head -1 || true)
HASH_CAND=$(md5sum "$CAND_BIN" 2>/dev/null | awk '{print $1}' || echo "unknown")
log "candidate binary hash: $HASH_CAND"

if [[ "$HASH_BASE" == "$HASH_CAND" ]]; then
  err "WARNING: baseline and candidate binaries have IDENTICAL hashes!"
  err "The result below is invalid — cargo reused a stale binary."
  exit 1
fi

CAND_TIMES=()
for ((i=1; i<=RUNS; i++)); do
  log "candidate run $i/$RUNS..."
  t=$(run_fancy)
  CAND_TIMES+=("$t")
  log "  → ${t}s"
done

# ── Summary ────────────────────────────────────────────────────────────

echo ""
echo "=== RESULTS ==="
python3 - "${BASE_TIMES[*]}" "${CAND_TIMES[*]}" "$HASH_BASE" "$HASH_CAND" <<'PY'
import sys, statistics as s

base_str, cand_str, h_base, h_cand = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base = sorted(float(x) for x in base_str.split())
cand = sorted(float(x) for x in cand_str.split())

med_base = s.median(base)
med_cand = s.median(cand)
delta_pct = (med_cand - med_base) / med_base * 100

print(f"Baseline  times: {', '.join(f'{t:.2f}s' for t in base)}  (median {med_base:.2f}s)")
print(f"Candidate times: {', '.join(f'{t:.2f}s' for t in cand)}  (median {med_cand:.2f}s)")
print(f"Delta: {delta_pct:+.2f}%  (negative = improvement)")
print(f"Binary hashes: base={h_base}  cand={h_cand}")
if delta_pct < -2:
    print(f"✓ Production improvement confirmed at {abs(delta_pct):.1f}%")
elif delta_pct < 0:
    print(f"~ Marginal improvement ({abs(delta_pct):.1f}%), within noise range")
else:
    print(f"✗ No improvement detected")
PY
