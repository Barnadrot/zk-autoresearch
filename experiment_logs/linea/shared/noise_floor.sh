#!/usr/bin/env bash
# Noise floor characterization — run ONCE before first experiment.
# Runs 10 identical bench runs with no code changes, reports σ.
# Use output to calibrate KEEP_THRESHOLD_PCT and COUNT in config.env.
#
# Expected: σ ~1-2% (Go GC, OS scheduling). Set threshold = 2×σ.

set -e

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SHARED_DIR/config.env"

PROVER_DIR=${PROVER_DIR:-$HOME/linea-monorepo/prover}
NOISE_DIR="$HOME/linea-bench/noise"
mkdir -p "$NOISE_DIR"

BENCH_PKG=${BENCH_PKG:-"./crypto/vortex/vortex_koalabear/..."}
BENCH_FILTER=${BENCH_FILTER:-"BenchmarkVortexHashPathsByRows"}

cd "$PROVER_DIR"

echo "[noise] Running 10 identical bench runs (no code changes)..."
for i in $(seq 1 10); do
    echo "[noise] Run $i/10..."
    GOGC=off go test \
        -bench="$BENCH_FILTER" \
        -benchmem \
        -count=5 \
        -benchtime=2s \
        -timeout=600s \
        "$BENCH_PKG" > "$NOISE_DIR/run_$i.txt"
done

echo "[noise] Characterizing variance with benchstat..."
benchstat "$NOISE_DIR"/run_*.txt

echo ""
echo "[noise] Use the geomean σ above to set KEEP_THRESHOLD_PCT = 2×σ in config.env"
