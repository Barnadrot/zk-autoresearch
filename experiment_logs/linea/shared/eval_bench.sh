#!/usr/bin/env bash
# Linea benchmark gate — benchstat-based, two-tier gating.
#
# Usage:
#   eval_bench.sh                  # tier-1: fast LC benchmark, compare vs baseline
#   eval_bench.sh --save-baseline  # save current as baseline (both tiers)
#   eval_bench.sh --tier2          # tier-2: full VortexHash benchmark (for keeps only)
#
# Outputs:
#   benchstat comparison to stdout
#   /tmp/eval_bench_summary.json   # verdict + delta for iters.tsv
#
# Two-tier gating (FLAG 7):
#   Tier 1 (every iter): BenchmarkLinearCombination — fast (~1-5 min)
#   Tier 2 (keeps only): BenchmarkVortexHashPathsByRows — slower (~10-20 min)

set -e

export PATH="$PATH:$HOME/go/bin"

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SHARED_DIR/config.env"

PROVER_DIR=${PROVER_DIR:-$HOME/linea-monorepo/prover}
BENCH_DIR="$HOME/linea-bench"

mkdir -p "$BENCH_DIR"

cd "$PROVER_DIR"

log() { echo "[eval_bench] $*"; }

# Select tier
if [ "$1" = "--tier2" ]; then
    BENCH_PKG="./crypto/vortex/vortex_koalabear/..."
    BENCH_FILTER="BenchmarkVortexHashPathsByRows"
    BASELINE_FILE="$BENCH_DIR/baseline_tier2.txt"
    RESULT_FILE="$BENCH_DIR/current_tier2.txt"
    TIER="tier2"
    shift
else
    BENCH_PKG="./crypto/vortex/..."
    BENCH_FILTER="BenchmarkLinearCombination"
    BASELINE_FILE="$BENCH_DIR/baseline.txt"
    RESULT_FILE="$BENCH_DIR/current.txt"
    TIER="tier1"
fi

# Allow override from config.env or command line
BENCH_PKG=${BENCH_PKG_OVERRIDE:-$BENCH_PKG}
BENCH_FILTER=${BENCH_FILTER_OVERRIDE:-$BENCH_FILTER}

log "[$TIER] Running benchmark: $BENCH_FILTER (count=$COUNT)..."
GOGC=off go test \
    -bench="$BENCH_FILTER" \
    -benchmem \
    -count="$COUNT" \
    -benchtime=2s \
    -timeout=600s \
    -run='^$' \
    "$BENCH_PKG" > "$RESULT_FILE"

if [ "$1" = "--save-baseline" ]; then
    cp "$RESULT_FILE" "$BASELINE_FILE"
    log "[$TIER] Baseline saved to $BASELINE_FILE"
    exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
    log "ERROR: no baseline found. Run with --save-baseline first."
    exit 2
fi

log "[$TIER] Comparing with benchstat..."
BENCHSTAT_OUT=$(benchstat "$BASELINE_FILE" "$RESULT_FILE" 2>&1)
echo "$BENCHSTAT_OUT"

# Parse benchstat output for keep/discard decision
# benchstat v2 format: "BenchmarkName  old ± %  new ± %  delta ± %  p-value"
DELTA_PCT=$(echo "$BENCHSTAT_OUT" | grep -E "^BenchmarkLinearCombination|^geomean" | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /%/) print $i}' | tail -1 | sed 's/%//' || echo "unknown")
P_VALUE=$(echo "$BENCHSTAT_OUT" | grep -E "^BenchmarkLinearCombination|^geomean" | \
    awk '{print $NF}' | grep -E "^[0-9]|^p=" | sed 's/p=//' | tail -1 || echo "unknown")

log "[$TIER] Delta: ${DELTA_PCT}%, p-value: ${P_VALUE}"

# Write structured output for iters.tsv logging
cat > /tmp/eval_bench_summary.json <<EOF
{
  "tier": "$TIER",
  "bench_filter": "$BENCH_FILTER",
  "delta_pct": "$DELTA_PCT",
  "p_value": "$P_VALUE",
  "baseline": "$BASELINE_FILE",
  "result": "$RESULT_FILE"
}
EOF

log "[$TIER] Summary written to /tmp/eval_bench_summary.json"
