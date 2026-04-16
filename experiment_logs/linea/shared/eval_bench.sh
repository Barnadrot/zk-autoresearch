#!/usr/bin/env bash
# Linea benchmark gate — benchstat-based.
# Equivalent of leanMultisig's eval_paired.sh.
#
# Usage:
#   eval_bench.sh                  # compare candidate vs saved baseline
#   eval_bench.sh --save-baseline  # save current as baseline
#
# Outputs:
#   benchstat comparison to stdout
#   /tmp/eval_bench_summary.json   # verdict + delta for iters.tsv
#
# ⚠️ QUESTION: noise floor on Plonky3 server not yet characterized.
#    Run noise_floor.sh before first experiment to set COUNT and KEEP_THRESHOLD_PCT.

set -e

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SHARED_DIR/config.env"

PROVER_DIR=${PROVER_DIR:-$HOME/linea-monorepo/prover}
BENCH_DIR="$HOME/linea-bench"
BASELINE_FILE="$BENCH_DIR/baseline.txt"
RESULT_FILE="$BENCH_DIR/current.txt"

mkdir -p "$BENCH_DIR"

# ⚠️ QUESTION (Friday): confirm production benchmark filter.
# BenchmarkVortexHashPathsByRows is the lightweight profile target (1700s run).
# BenchmarkLinearCombination does not yet exist — must be written (Phase 2a).
# BenchmarkCompilerWithSelfRecursion needs 64GB RAM — not runnable on Plonky3 server (16GB).
BENCH_PKG=${BENCH_PKG:-"./crypto/vortex/vortex_koalabear/..."}
BENCH_FILTER=${BENCH_FILTER:-"BenchmarkVortexHashPathsByRows"}

cd "$PROVER_DIR"

log() { echo "[eval_bench] $*"; }

log "Running benchmark: $BENCH_FILTER (count=$COUNT)..."
GOGC=off go test \
    -bench="$BENCH_FILTER" \
    -benchmem \
    -count="$COUNT" \
    -benchtime=2s \
    -timeout=600s \
    "$BENCH_PKG" > "$RESULT_FILE"

if [ "$1" = "--save-baseline" ]; then
    cp "$RESULT_FILE" "$BASELINE_FILE"
    log "Baseline saved to $BASELINE_FILE"
    exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
    log "ERROR: no baseline found. Run with --save-baseline first."
    exit 2
fi

log "Comparing with benchstat..."
benchstat "$BASELINE_FILE" "$RESULT_FILE"

# Parse benchstat output for keep/discard decision
DELTA=$(benchstat "$BASELINE_FILE" "$RESULT_FILE" 2>/dev/null | \
    grep -E "^Benchmark" | awk '{print $NF}' | head -1 || echo "unknown")

log "Delta: $DELTA"
