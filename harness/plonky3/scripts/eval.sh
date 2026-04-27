#!/bin/bash
# Benchmark evaluation script for the CLI autoresearch experiment.
# Run from ~/zk-autoresearch/Plonky3 after making changes.
#
# Usage:
#   bash eval.sh              — compare current working tree vs saved baseline
#   bash eval.sh --save-baseline  — save current HEAD as the baseline (run once at start)
#
# Output: prints Criterion change CI, p-value, and verdict to stdout.
# Exit code: 0 always (agent reads the output, not the exit code).

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/Plonky3

BENCH_FLAGS="--features p3-dft/parallel --bench fft"
BENCH_FILTER="coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256/1048576"
BASELINE_NAME="cli_baseline"
MEASURE="--measurement-time 30 --noplot"

if [[ "$1" == "--save-baseline" ]]; then
  echo "[eval] Saving current HEAD as baseline '$BASELINE_NAME'..."
  cargo bench -p p3-dft $BENCH_FLAGS -- "$BENCH_FILTER" \
    --save-baseline $BASELINE_NAME $MEASURE
  echo "[eval] Baseline saved."
  exit 0
fi

echo "[eval] Running benchmark vs baseline '$BASELINE_NAME'..."
cargo bench -p p3-dft $BENCH_FLAGS -- "$BENCH_FILTER" \
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
