#!/bin/bash
# Cross-branch Criterion benchmark comparison.
# Saves origin/main as baseline, then compares each experiment branch directly.
# Run overnight on the prover machine (no other workload).
#
# Usage: bash run_benchmark.sh [--skip-main]
#   --skip-main  Skip the main baseline run (reuse existing Criterion baseline)
#
# Output: ~/bench_results/ with per-branch logs + final summary

set -e
cd ~/zk-autoresearch/Plonky3

BENCH_FILTER="coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256/1048576"
BENCH_FLAGS="--features p3-dft/parallel --bench fft"
MEASURE="--measurement-time 60 --noplot"
RESULTS=~/bench_results
SKIP_MAIN=0

for arg in "$@"; do
  [[ "$arg" == "--skip-main" ]] && SKIP_MAIN=1
done

mkdir -p "$RESULTS"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY="$RESULTS/summary_${TIMESTAMP}.txt"

echo "=== Benchmark run: $TIMESTAMP ===" | tee "$SUMMARY"
echo "Filter: $BENCH_FILTER" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# ── 1. Save main as Criterion baseline ────────────────────────────────────────
if [[ $SKIP_MAIN -eq 0 ]]; then
  echo "=== [1/5] BASELINE — origin/main ===" | tee -a "$SUMMARY"
  git checkout origin/main
  cargo bench -p p3-dft $BENCH_FLAGS -- "$BENCH_FILTER" \
    --save-baseline main $MEASURE \
    2>&1 | tee "$RESULTS/bench_main_${TIMESTAMP}.txt"
  echo "Baseline saved." | tee -a "$SUMMARY"
else
  echo "=== [1/5] Skipping main baseline (--skip-main) ===" | tee -a "$SUMMARY"
fi

# ── Helper: run one branch and compare vs main baseline ───────────────────────
run_branch() {
  local label="$1"
  local branch="$2"
  local step="$3"
  local logfile="$RESULTS/bench_${label}_${TIMESTAMP}.txt"

  echo "" | tee -a "$SUMMARY"
  echo "=== [$step] $label — $branch ===" | tee -a "$SUMMARY"
  git checkout "$branch"
  cargo bench -p p3-dft $BENCH_FLAGS -- "$BENCH_FILTER" \
    --baseline main $MEASURE \
    2>&1 | tee "$logfile"

  # Extract median and p-value from Criterion output
  MEDIAN=$(grep -oP '\d+\.\d+(?= ms)' "$logfile" | head -1 || echo "N/A")
  PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' "$logfile" | head -1 || echo "N/A")
  CHANGE=$(grep -E 'Performance has (regressed|improved)' "$logfile" | head -1 || echo "(no verdict)")

  echo "  Median: ${MEDIAN}ms  |  p=${PVAL}  |  ${CHANGE}" | tee -a "$SUMMARY"
}

# ── 2–6. Experiment branches ───────────────────────────────────────────────────
run_branch "round1"  "perf/dft-butterfly-optimizations"              "2/6"
run_branch "round2"  "myfork/perf/dft-butterfly-layer-fusion-exp-2"  "3/6"
run_branch "round3"  "perf/dft-exp3-round3-improvements"             "4/6"
run_branch "exp4"    "exp-4-monty31-avx512"                          "5/6"
run_branch "monty"   "perf/monty31-addsub-port-pressure"             "6/6"

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" | tee -a "$SUMMARY"
echo "=== ALL DONE ===" | tee -a "$SUMMARY"
echo "Results in: $RESULTS/" | tee -a "$SUMMARY"
cat "$SUMMARY"
