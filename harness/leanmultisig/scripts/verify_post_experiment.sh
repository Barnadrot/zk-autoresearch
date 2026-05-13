#!/bin/bash
# Post-experiment manual verification script.
# Run this BEFORE asking Emile or Chaos to review any result.
# Not run by the agent — human-triggered only.
#
# Checks:
#   1. KoalaBear field arithmetic unit tests
#   2. Full WHIR proof integration test
#   3. Multi-size XMSS aggregate proof generation + verification (N=1, 10, 100)
#   4. Proof size invariant (must match baseline)
#
# Usage:
#   bash verify_post_experiment.sh                    — run all checks
#   bash verify_post_experiment.sh --save-baseline    — save proof size baseline (run once on clean main)

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/leanMultisig

BASELINE_FILE="/tmp/lm_proof_size_baseline.txt"

echo "================================================================"
echo " leanMultisig Post-Experiment Verification"
echo "================================================================"
echo ""

# ── Layer 1: Field arithmetic ─────────────────────────────────────────
echo "[1/4] KoalaBear field arithmetic unit tests..."
cargo test -p mt-koala-bear --release --quiet 2>&1
echo "      PASSED"
echo ""

# ── Layer 2: WHIR integration ─────────────────────────────────────────
echo "[2/4] Full WHIR proof integration test..."
cargo test -p mt-whir --release --quiet 2>&1
echo "      PASSED"
echo ""

# ── Layer 3: Multi-size proof generation ──────────────────────────────
# NOTE: upstream removed the xmss_aggregate example in PR #213 (type-2 aggregation).
# Use `cargo test --release -p rec_aggregation` which covers type-1 and type-2 aggregation.
echo "[3/4] rec_aggregation integration tests (type-1 + type-2 aggregation)..."
cargo test --release -p rec_aggregation --quiet 2>&1
echo "      PASSED"
echo ""

# Also run the full multisignature tests
echo "[3b/4] Full multisignature tests..."
cargo test --release --test test_multisignatures --quiet 2>&1
echo "      PASSED"
echo ""

# ── Layer 4: Proof size invariant ─────────────────────────────────────
echo "[4/4] Proof size invariant check (postcard-serialized type-1 aggregate, N_SIGS=100)..."
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanmultisig/bench}

# Build the proof_size_check binary (fast — small N_SIGS, but still needs DFT precompute)
(cd "$BENCH_CRATE" && cargo build --release --bin proof_size_check 2>&1 | tail -3)

# Run it and parse stdout
PROOF_SIZE_OUT=$("$BENCH_CRATE/target/release/proof_size_check" 2>&1) || {
  echo "      FAILED — proof_size_check binary returned non-zero"
  echo "$PROOF_SIZE_OUT" | tail -10
  exit 1
}
CURRENT_SIZE=$(echo "$PROOF_SIZE_OUT" | grep -oP 'proof_bytes=\K[0-9]+' | head -1)
if [[ -z "$CURRENT_SIZE" ]]; then
  echo "      FAILED — could not parse proof_bytes from output"
  echo "$PROOF_SIZE_OUT" | tail -5
  exit 1
fi

if [[ "$1" == "--save-baseline" ]]; then
  echo "$CURRENT_SIZE" > "$BASELINE_FILE"
  echo "      Baseline saved: $CURRENT_SIZE bytes (file: $BASELINE_FILE)"
else
  if [[ -f "$BASELINE_FILE" ]]; then
    BASELINE_SIZE=$(cat "$BASELINE_FILE")
    if [[ "$CURRENT_SIZE" == "$BASELINE_SIZE" ]]; then
      echo "      PASSED — proof size unchanged ($CURRENT_SIZE bytes)"
    else
      DELTA=$((CURRENT_SIZE - BASELINE_SIZE))
      DELTA_PCT=$(python3 -c "print(f'{($CURRENT_SIZE - $BASELINE_SIZE) / $BASELINE_SIZE * 100:+.2f}')")
      echo "      FAILED — proof size changed: baseline=$BASELINE_SIZE, current=$CURRENT_SIZE (Δ=${DELTA} bytes, ${DELTA_PCT}%)"
      echo "      Structural change in proof format. Investigate before submitting."
      echo "      If intentional (e.g., RATE/folding-factor change), re-save baseline with --save-baseline."
      exit 1
    fi
  else
    echo "      SKIPPED — no baseline saved. Current: $CURRENT_SIZE bytes."
    echo "      Run with --save-baseline on clean origin/main to establish."
  fi
fi

echo ""
echo "================================================================"
echo " All checks passed. Safe to request review."
echo "================================================================"
