#!/usr/bin/env bash
# Linea benchmark gate — benchstat-based, two-tier gating.
#
# Usage:
#   eval_bench.sh                  # tier-1 + tier-2 combined (~4-5 min)
#   eval_bench.sh --save-baseline  # save current as baseline (both tiers)
#   eval_bench.sh --tier1-only     # tier-1 only: LC microbench (~2 min)
#   eval_bench.sh --tier2-only     # tier-2 only: VortexHash commitment (~2 min)
#
# Outputs:
#   benchstat comparison to stdout
#   /tmp/eval_bench_summary.json   # verdict + delta for iters.tsv
#
# Two-tier gating:
#   Tier 1: BenchmarkLinearCombination — opening phase hot path (~2 min)
#   Tier 2: BenchmarkVortexHashPathsByRows (filtered) — commitment phase (~2 min)
#
# Total iteration budget: correctness (~4s) + bench (~4-5 min) = ~5 min

set -e

export PATH="$PATH:$HOME/go/bin"

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SHARED_DIR/config.env"

PROVER_DIR=${PROVER_DIR:-$HOME/zk-autoresearch/linea-monorepo/prover}
BENCH_DIR="$HOME/linea-bench"

mkdir -p "$BENCH_DIR"

cd "$PROVER_DIR"

log() { echo "[eval_bench] $*"; }

# --- Parse args ---
RUN_TIER1=true
RUN_TIER2=true
SAVE_BASELINE=false

for arg in "$@"; do
    case "$arg" in
        --save-baseline) SAVE_BASELINE=true ;;
        --tier1-only)    RUN_TIER2=false ;;
        --tier2-only)    RUN_TIER1=false ;;
    esac
done

# --- Tier 1: LinearCombination (opening phase) ---
TIER1_BASELINE="$BENCH_DIR/baseline_tier1.txt"
TIER1_RESULT="$BENCH_DIR/current_tier1.txt"

if $RUN_TIER1; then
    log "[tier1] Running BenchmarkLinearCombination (count=$COUNT)..."
    GOGC=off go test \
        -bench="BenchmarkLinearCombination" \
        -benchmem \
        -count="$COUNT" \
        -benchtime=2s \
        -timeout=300s \
        -run='^$' \
        ./crypto/vortex/... > "$TIER1_RESULT"

    if $SAVE_BASELINE; then
        cp "$TIER1_RESULT" "$TIER1_BASELINE"
        log "[tier1] Baseline saved."
    fi
fi

# --- Tier 2: VortexHashPathsByRows (commitment phase, filtered to 3-4 row counts) ---
TIER2_BASELINE="$BENCH_DIR/baseline_tier2.txt"
TIER2_RESULT="$BENCH_DIR/current_tier2.txt"
# Filter: rows 128, 512, 1024 (also catches 1280 — that's fine, more data)
TIER2_FILTER="BenchmarkVortexHashPathsByRows/rows_(128|512|1024)/"

if $RUN_TIER2; then
    log "[tier2] Running VortexHashPathsByRows filtered (count=$COUNT)..."
    GOGC=off go test \
        -bench="$TIER2_FILTER" \
        -benchmem \
        -count="$COUNT" \
        -benchtime=2s \
        -timeout=600s \
        -run='^$' \
        ./crypto/vortex/vortex_koalabear/... > "$TIER2_RESULT"

    if $SAVE_BASELINE; then
        cp "$TIER2_RESULT" "$TIER2_BASELINE"
        log "[tier2] Baseline saved."
    fi
fi

if $SAVE_BASELINE; then
    log "Baselines saved. Done."
    exit 0
fi

# --- Compare with benchstat ---
VERDICT="unknown"
DELTA_PCT="unknown"

for TIER in tier1 tier2; do
    if [ "$TIER" = "tier1" ] && ! $RUN_TIER1; then continue; fi
    if [ "$TIER" = "tier2" ] && ! $RUN_TIER2; then continue; fi

    BASELINE_VAR="${TIER^^}_BASELINE"
    RESULT_VAR="${TIER^^}_RESULT"
    BASELINE="${!BASELINE_VAR}"
    RESULT="${!RESULT_VAR}"

    if [ ! -f "$BASELINE" ]; then
        log "[$TIER] ERROR: no baseline found. Run with --save-baseline first."
        exit 2
    fi

    log "[$TIER] Comparing with benchstat..."
    BENCHSTAT_OUT=$(benchstat "$BASELINE" "$RESULT" 2>&1)
    echo "$BENCHSTAT_OUT"
    echo ""

    # Parse geomean deltas: sec/op (first geomean line), B/op (second), allocs/op (third)
    GEOMEANS=$(echo "$BENCHSTAT_OUT" | grep -i "geomean")
    TIER_DELTA=$(echo "$GEOMEANS" | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /%/) print $i}' | sed 's/%//' || echo "unknown")
    TIER_ALLOC_DELTA=$(echo "$GEOMEANS" | sed -n '3p' | awk '{for(i=1;i<=NF;i++) if($i ~ /%/) print $i}' | sed 's/%//' || echo "unknown")
    TIER_P=$(echo "$GEOMEANS" | head -1 | awk '{print $NF}' | grep -E "^[0-9]|^p=" | sed 's/p=//' || echo "unknown")

    log "[$TIER] ns/op delta: ${TIER_DELTA}%, allocs delta: ${TIER_ALLOC_DELTA}%, p-value: ${TIER_P}"
done

log "Done. Read benchstat output above for keep/discard decision."
log "Keep if: ns/op geomean improvement > 2.0% with p < 0.05, OR allocs/op reduced."
