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
echo "[3/4] Multi-size XMSS aggregate proof generation + verification..."
for N in 1 10 100; do
  echo -n "      N=$N sigs... "
  cargo run --release -p rec_aggregation --example xmss_aggregate -- --n-signatures $N 2>&1 | tail -1
  echo "      PASSED"
done
echo ""

# ── Layer 4: Proof size invariant ─────────────────────────────────────
echo "[4/4] Proof size invariant check..."
CURRENT_SIZE=$(cargo run --release -p rec_aggregation --example xmss_aggregate -- --n-signatures 10 --print-proof-size 2>&1 | grep -oP 'proof size: \K\d+' || echo "unknown")

if [[ "$1" == "--save-baseline" ]]; then
  echo "$CURRENT_SIZE" > "$BASELINE_FILE"
  echo "      Baseline saved: $CURRENT_SIZE bytes"
else
  if [[ -f "$BASELINE_FILE" ]]; then
    BASELINE_SIZE=$(cat "$BASELINE_FILE")
    if [[ "$CURRENT_SIZE" == "$BASELINE_SIZE" ]]; then
      echo "      PASSED — proof size unchanged ($CURRENT_SIZE bytes)"
    else
      echo "      FAILED — proof size changed: baseline=$BASELINE_SIZE, current=$CURRENT_SIZE"
      echo "      This may indicate a structural change. Investigate before submitting."
      exit 1
    fi
  else
    echo "      SKIPPED — no baseline saved. Run with --save-baseline on clean main first."
  fi
fi

echo ""
echo "================================================================"
echo " All checks passed. Safe to request review."
echo "================================================================"
