#!/bin/bash
# Benchmark evaluation script for leanMultisig experiment 1.
#
# Usage:
#   bash eval.sh              — compare current vs saved baseline
#   bash eval.sh --save-baseline  — save current as baseline (run once at start)
#
# Exit code: 0 always (agent reads output, not exit code).

set -e
cd ~/zk-autoresearch/leanMultisig-bench

BENCH_FLAGS="--bench xmss_leaf"
BENCH_FILTER="xmss_leaf_100sigs"
BASELINE_NAME="exp1_baseline"
MEASURE="--measurement-time 30 --noplot"

if [[ "$1" == "--save-baseline" ]]; then
  echo "[eval] Saving current as baseline '$BASELINE_NAME'..."
  cargo bench $BENCH_FLAGS -- "$BENCH_FILTER" \
    --save-baseline $BASELINE_NAME $MEASURE
  echo "[eval] Baseline saved."
  exit 0
fi

echo "[eval] Running benchmark vs baseline '$BASELINE_NAME'..."
cargo bench $BENCH_FLAGS -- "$BENCH_FILTER" \
  --baseline $BASELINE_NAME $MEASURE \
  2>&1 | tee /tmp/eval_last.txt

echo ""
echo "=== SUMMARY ==="
CHANGE=$(grep -oP 'change:.*' /tmp/eval_last.txt | head -1 || echo "N/A")
PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' /tmp/eval_last.txt | head -1 || echo "N/A")
VERDICT=$(grep -E 'Performance has (regressed|improved)|No change|within noise' /tmp/eval_last.txt | head -1 || echo "(no verdict)")
echo "Change : $CHANGE"
echo "p-value: $PVAL"
echo "Verdict: $VERDICT"
echo "Keep if: improvement > 0.20% AND p < 0.05"
