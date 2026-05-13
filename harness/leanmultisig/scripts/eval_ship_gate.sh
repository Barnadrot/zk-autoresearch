#!/bin/bash
# Criterion-based slow-tier ship gate.
#
# Wraps cargo bench --bench xmss_leaf with Criterion's save-baseline /
# compare-baseline workflow. Use this when you want bootstrap CIs,
# outlier detection, and Criterion's regression-detection — typically
# before opening a PR to upstream-with-confidence.
#
# Per-sample alternation, Tukey outlier exclusion, and adaptive sample
# size are Criterion's defaults — no flags needed.
#
# Usage:
#   # 1. Establish a baseline at the current HEAD
#   eval_ship_gate.sh --save-baseline <name>
#
#   # 2. Compare HEAD against a saved baseline (Criterion prints
#   #    "Performance has improved/regressed by X% (p = ...)" verdict)
#   eval_ship_gate.sh --baseline <name>
#
#   # 3. Full paired cycle: save baseline at <ref>, then compare HEAD
#   eval_ship_gate.sh --paired <baseline_ref>
#
# Output:
#   /tmp/eval_ship_gate_last.txt  — full Criterion stdout
#   /tmp/eval_ship_gate_summary.json — distilled summary (Δ%, p, verdict)
#   target/criterion/ — HTML reports (open in browser)
#
# Exit codes:
#   0 = ship-eligible (improved OR no change, no regression)
#   1 = regression detected
#   2 = infrastructure error (build fail, env preflight fail, etc.)

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanmultisig/bench}
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
BENCH_NAME=${BENCH_NAME:-xmss_leaf}
# Default filter matches xmss_leaf_<N_SIGS>sigs from bench source (N_SIGS=1550 currently).
# Just "xmss_leaf" prefix-matches any size variant.
BENCH_FILTER=${BENCH_FILTER:-xmss_leaf}
SAMPLE_SIZE=${SHIP_GATE_SAMPLE_SIZE:-10}
MEASURE_SECS=${SHIP_GATE_MEASURE_SECS:-60}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}

export RUSTFLAGS="-C target-cpu=native"

# --- args ---
MODE=""
BASELINE_NAME=""
BASELINE_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --save-baseline) MODE="save"; BASELINE_NAME="$2"; shift 2 ;;
    --baseline)      MODE="compare"; BASELINE_NAME="$2"; shift 2 ;;
    --paired)        MODE="paired"; BASELINE_REF="$2"; shift 2 ;;
    --sample-size)   SAMPLE_SIZE="$2"; shift 2 ;;
    --measure-secs)  MEASURE_SECS="$2"; shift 2 ;;
    *)               echo "[eval_ship_gate] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "[eval_ship_gate] usage:" >&2
  echo "  --save-baseline <name>  | --baseline <name> | --paired <baseline_ref>" >&2
  exit 2
fi

# --- env preflight ---
if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
  if ! bash "$SHARED_DIR/env_preflight.sh" --json-only > /tmp/eval_ship_gate_preflight.json 2>/dev/null; then
    echo "[eval_ship_gate][err] env_preflight FAILED — refusing to measure" >&2
    bash "$SHARED_DIR/env_preflight.sh" >/dev/null
    exit 2
  fi
fi

log() { echo "[eval_ship_gate] $*"; }

CRIT_FLAGS="--sample-size $SAMPLE_SIZE --measurement-time $MEASURE_SECS --noplot"

run_save() {
  local name="$1"
  log "saving Criterion baseline '$name' (sample-size=$SAMPLE_SIZE, measure=${MEASURE_SECS}s)..."
  (cd "$BENCH_CRATE" && cargo bench --bench "$BENCH_NAME" -- "$BENCH_FILTER" \
    --save-baseline "$name" $CRIT_FLAGS) 2>&1 | tee /tmp/eval_ship_gate_last.txt
  log "saved baseline '$name'"
}

run_compare() {
  local name="$1"
  log "comparing HEAD vs Criterion baseline '$name'..."
  (cd "$BENCH_CRATE" && cargo bench --bench "$BENCH_NAME" -- "$BENCH_FILTER" \
    --baseline "$name" $CRIT_FLAGS) 2>&1 | tee /tmp/eval_ship_gate_last.txt
}

# --- mode dispatch ---
case "$MODE" in
  save)
    run_save "$BASELINE_NAME"
    exit 0
    ;;

  compare)
    run_compare "$BASELINE_NAME"
    ;;

  paired)
    # Capture current state to restore
    ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
    ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD)
    BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
    CANDIDATE_SHA="$ORIG_HEAD"

    if [[ "$BASELINE_SHA" == "$CANDIDATE_SHA" ]]; then
      echo "[eval_ship_gate][err] baseline == HEAD — nothing to compare" >&2
      exit 2
    fi

    trap '(cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null) || true' EXIT

    log "paired mode: baseline ref=$BASELINE_REF ($BASELINE_SHA), candidate=HEAD ($CANDIDATE_SHA)"

    # Step 1: checkout baseline ref, save baseline
    (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
    run_save "ship_gate_paired"

    # Step 2: checkout candidate (original HEAD), compare
    (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
    run_compare "ship_gate_paired"
    ;;
esac

# --- parse Criterion output ---
CHANGE=$(grep -oP 'change:\s*\[[^\]]+\]\s*\([+-]?\d+\.\d+%\)' /tmp/eval_ship_gate_last.txt | head -1 || echo "")
PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' /tmp/eval_ship_gate_last.txt | head -1 || echo "")
VERDICT=$(grep -E 'Performance has (regressed|improved)|No change in performance|change within noise threshold' /tmp/eval_ship_gate_last.txt | head -1 || echo "(no verdict)")

echo ""
echo "=== SHIP GATE SUMMARY ==="
echo "change : ${CHANGE:-N/A}"
echo "p-value: ${PVAL:-N/A}"
echo "verdict: $VERDICT"

# Write distilled summary JSON
python3 - <<PY > /tmp/eval_ship_gate_summary.json
import json
print(json.dumps({
    "bench": "$BENCH_NAME",
    "filter": "$BENCH_FILTER",
    "sample_size": $SAMPLE_SIZE,
    "measure_secs": $MEASURE_SECS,
    "change_line": "$CHANGE",
    "p_value": "$PVAL",
    "verdict": "$VERDICT"
}, indent=2))
PY

# Exit code based on Criterion verdict
if echo "$VERDICT" | grep -q "regressed"; then
  exit 1
fi
exit 0
