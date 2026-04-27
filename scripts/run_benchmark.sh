#!/bin/bash
# Cross-branch Criterion benchmark comparison.
# Saves origin/main as baseline, then compares each experiment branch directly.
# Run overnight on the prover machine (no other workload).
#
# Usage: bash run_benchmark.sh [--skip-main] [--multisize] [--multisize-isolated]
#   --skip-main          Skip the main baseline run (reuse existing Criterion baseline)
#   --multisize          Run all sizes in one pass (faster, but thermal cross-contamination)
#   --multisize-isolated Run each size with sleep between baseline+branch (clean p-values)
#
# Output: ~/bench_results/ with per-branch logs + final summary
#
# ── IMPORTANT: RUSTFLAGS is set explicitly below ─────────────────────────────
# Without `-C target-cpu=native` cargo builds the bench WITHOUT AVX-512 on
# an AVX-512 machine and measurements come out ~2× slow across every size.
# `cargo bench --no-run` happily reuses a stale cached bench binary across
# RUSTFLAGS changes, so forgetting this produces silently-wrong comparisons
# that look like huge "regressions" when switching branches. Do NOT remove
# the export below without understanding this.
#
# ── Note on what the origin/main comparison measures ─────────────────────────
# `origin/main` does NOT include the bench-harness fix
# (`iter_batched(LargeInput)`) that this PR introduces. When comparing
# `origin/main` vs the PR branch, Criterion is measuring two *different*
# regions: on main the timed region includes `messages.clone()` (~1 GB
# alloc + page faults), on the PR branch the clone is in setup. The apparent
# "improvement" therefore combines (a) the harness fix moving ~54% of noise
# out of the measurement window and (b) the ~1-3% compute-side wins. See
# report.md / pr_description.md for a clean compute-only comparison (PR's
# bench_fix commit vs its tip).

set -e
cd ~/zk-autoresearch/Plonky3

# AVX-512 must be enabled at compile time; see header comment above.
export RUSTFLAGS="-C target-cpu=native"
echo "RUSTFLAGS=${RUSTFLAGS}"

BENCH_FLAGS="--features p3-dft/parallel --bench fft"
RESULTS=~/bench_results
SKIP_MAIN=0
MULTISIZE=0
MULTISIZE_ISOLATED=0
SLEEP_SECS=240  # cool-down between baseline and branch per size
BRANCH="perf/exp-cli-monty-bench-fix-pr"
MEASURE_ISOLATED="--measurement-time 60"

for arg in "$@"; do
  [[ "$arg" == "--skip-main" ]]          && SKIP_MAIN=1
  [[ "$arg" == "--multisize" ]]          && MULTISIZE=1
  [[ "$arg" == "--multisize-isolated" ]] && MULTISIZE_ISOLATED=1
done

if [[ $MULTISIZE -eq 1 ]]; then
  BENCH_FILTER="coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel"
  MEASURE="--measurement-time 30 --noplot"
  BASELINE_NAME="main_multisize"
else
  BENCH_FILTER="coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256/1048576"
  MEASURE="--measurement-time 60 --noplot"
  BASELINE_NAME="main"
fi

mkdir -p "$RESULTS"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY="$RESULTS/summary_${TIMESTAMP}.txt"

echo "=== Benchmark run: $TIMESTAMP ===" | tee "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# ── Isolated multi-size mode: baseline+branch per size with cool-down sleeps ──
if [[ $MULTISIZE_ISOLATED -eq 1 ]]; then
  echo "Mode: --multisize-isolated (${SLEEP_SECS}s cool-down between runs)" | tee -a "$SUMMARY"
  BASE_FILTER="coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256"

  for logn in 14 16 18 20 22; do
    n=$((1 << logn))
    filter="${BASE_FILTER}/${n}"
    bname="main_size${logn}"
    logfile="$RESULTS/isolated_2e${logn}_${TIMESTAMP}.txt"

    echo "" | tee -a "$SUMMARY"
    echo "=== 2^${logn} (n=${n}) ===" | tee -a "$SUMMARY"

    echo "  [baseline] origin/main..." | tee -a "$SUMMARY"
    git checkout origin/main
    cargo clean
    cargo bench -p p3-dft $BENCH_FLAGS -- "$filter" \
      --save-baseline "$bname" $MEASURE_ISOLATED --noplot \
      2>&1 | tee "${logfile}.main"

    # Back up Criterion baseline before cargo clean destroys it
    CRITERION_BAK="$RESULTS/criterion_bak_${logn}"
    rm -rf "$CRITERION_BAK"
    cp -r target/criterion "$CRITERION_BAK"

    echo "  Sleeping ${SLEEP_SECS}s to cool CPU..." | tee -a "$SUMMARY"
    sleep $SLEEP_SECS

    echo "  [branch] $BRANCH..." | tee -a "$SUMMARY"
    git checkout "$BRANCH"
    cargo clean
    # Restore baseline so --baseline comparison can find it
    mkdir -p target/criterion
    cp -r "$CRITERION_BAK/." target/criterion/
    cargo bench -p p3-dft $BENCH_FLAGS -- "$filter" \
      --baseline "$bname" $MEASURE_ISOLATED --noplot \
      2>&1 | tee "$logfile"

    PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' "$logfile" | head -1 || echo "N/A")
    CHANGE_CI=$(grep -oP 'change:.*' "$logfile" | head -1 || echo "N/A")
    VERDICT=$(grep -E 'Performance has (regressed|improved)|No change|within noise' "$logfile" | head -1 || echo "(no verdict)")
    echo "  p=${PVAL} | ${CHANGE_CI}" | tee -a "$SUMMARY"
    echo "  ${VERDICT}" | tee -a "$SUMMARY"

    echo "  Sleeping ${SLEEP_SECS}s before next size..." | tee -a "$SUMMARY"
    sleep $SLEEP_SECS
  done

  echo "" | tee -a "$SUMMARY"
  echo "=== ALL DONE ===" | tee -a "$SUMMARY"
  echo "Results in: $RESULTS/" | tee -a "$SUMMARY"
  cat "$SUMMARY"
  exit 0
fi

# ── 1. Save main as Criterion baseline ────────────────────────────────────────
if [[ $SKIP_MAIN -eq 0 ]]; then
  echo "=== [1/2] BASELINE — origin/main ===" | tee -a "$SUMMARY"
  git checkout origin/main
  cargo bench -p p3-dft $BENCH_FLAGS -- "$BENCH_FILTER" \
    --save-baseline $BASELINE_NAME $MEASURE \
    2>&1 | tee "$RESULTS/bench_main_${TIMESTAMP}.txt"
  echo "Baseline saved." | tee -a "$SUMMARY"
else
  echo "=== [1/2] Skipping main baseline (--skip-main) ===" | tee -a "$SUMMARY"
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
    --baseline $BASELINE_NAME $MEASURE \
    2>&1 | tee "$logfile"

  # Extract median and p-value from Criterion output
  MEDIAN=$(grep -oP '\d+\.\d+(?= ms)' "$logfile" | head -1 || echo "N/A")
  PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' "$logfile" | head -1 || echo "N/A")
  CHANGE=$(grep -E 'Performance has (regressed|improved)' "$logfile" | head -1 || echo "(no verdict)")

  echo "  Median: ${MEDIAN}ms  |  p=${PVAL}  |  ${CHANGE}" | tee -a "$SUMMARY"
}

# ── 2. Monty branch ───────────────────────────────────────────────────────────
run_branch "monty"   "perf/monty31-addsub-port-pressure"             "2/2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" | tee -a "$SUMMARY"
echo "=== ALL DONE ===" | tee -a "$SUMMARY"
echo "Results in: $RESULTS/" | tee -a "$SUMMARY"
cat "$SUMMARY"
