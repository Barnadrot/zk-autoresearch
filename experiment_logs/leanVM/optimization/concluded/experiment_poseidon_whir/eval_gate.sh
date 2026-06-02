#!/bin/bash
# Three-tier gate for leanMultisig experiment 5 (Poseidon + WHIR).
#
# Tier 1: Poseidon microbenchmark — fast local signal check (~30s)
# Tier 2: Criterion e2e (xmss_leaf_1400sigs) — keep/discard decision (~5min)
# Tier 3: Production (fancy-aggregation) — only on keeps (~20min)
#
# Usage:
#   eval_gate.sh                                     # HEAD~1 vs HEAD
#   eval_gate.sh --baseline <ref> --candidate <ref>
#   eval_gate.sh --skip-micro                        # skip Tier 1, go straight to Criterion
#
# Outputs:
#   /tmp/eval_gate_summary.json — verdict + all fields for iters.tsv
#   Exit: 0 = KEEP, 1 = DISCARD, 2 = infra error
#
# Tier 1 (microbench) is a pre-filter, not a gate: if the local Poseidon
# improvement is <MICRO_MIN_LOCAL_PCT%, the change can't clear 1% e2e
# (25.9% share × local improvement). Saves ~5min of Criterion time on
# changes that have no chance. Override with --skip-micro for non-Poseidon
# changes (e.g. WHIR structural changes that don't touch permute_mut).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/../shared" && pwd)"
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/leanMultisig-bench}

source "$SHARED_DIR/config.env" 2>/dev/null || true
KEEP_THRESHOLD_PCT=${KEEP_THRESHOLD_PCT:-1.0}

# Microbench pre-filter: need ~4% local Poseidon improvement to have a
# chance at 1% e2e (25.9% share, some dilution).
MICRO_MIN_LOCAL_PCT=${MICRO_MIN_LOCAL_PCT:-3.0}
MICRO_BENCH_FILTER="poseidon_permute_packed"
MICRO_SAMPLE_SIZE=10
MICRO_MEASUREMENT_TIME=10

BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"
SKIP_MICRO=false

export RUSTFLAGS="-C target-cpu=native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)    BASELINE_REF="$2"; shift 2 ;;
    --candidate)   CANDIDATE_REF="$2"; shift 2 ;;
    --skip-micro)  SKIP_MICRO=true; shift ;;
    *)             echo "[gate] unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[gate] $*"; }

ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")

trap 'cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

log "baseline  : $BASELINE_REF ($BASELINE_SHA)"
log "candidate : $CANDIDATE_REF ($CANDIDATE_SHA)"

# -----------------------------------------------------------------------
# Tier 1: Poseidon microbenchmark (pre-filter)
# -----------------------------------------------------------------------
MICRO_DELTA="-"
MICRO_DECISION="SKIP"
MICRO_TIME=0

if [[ "$SKIP_MICRO" == "false" ]]; then
  log "Tier 1: Poseidon microbenchmark..."
  T0=$(date +%s)

  # Build and run baseline
  log "  building baseline..."
  (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
  (cd "$BENCH_CRATE" && cargo clean --release >/dev/null 2>&1 || true)
  (cd "$BENCH_CRATE" && cargo build --release --bench poseidon_permute 2>&1 | tail -3 >&2)

  MICRO_BASE_BIN=$(ls -t "$BENCH_CRATE"/target/release/deps/poseidon_permute-* 2>/dev/null | grep -v '\.d$' | head -1)
  if [[ -z "$MICRO_BASE_BIN" ]]; then log "  ERROR: no baseline micro binary"; exit 2; fi

  log "  saving baseline..."
  (cd "$BENCH_CRATE" && "$MICRO_BASE_BIN" --bench "$MICRO_BENCH_FILTER" \
    --save-baseline micro_base \
    --sample-size "$MICRO_SAMPLE_SIZE" --measurement-time "$MICRO_MEASUREMENT_TIME" --noplot \
    >/dev/null 2>&1)

  # Build and run candidate
  log "  building candidate..."
  (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
  (cd "$BENCH_CRATE" && cargo clean --release >/dev/null 2>&1 || true)
  (cd "$BENCH_CRATE" && cargo build --release --bench poseidon_permute 2>&1 | tail -3 >&2)

  MICRO_CAND_BIN=$(ls -t "$BENCH_CRATE"/target/release/deps/poseidon_permute-* 2>/dev/null | grep -v '\.d$' | head -1)
  if [[ -z "$MICRO_CAND_BIN" ]]; then log "  ERROR: no candidate micro binary"; exit 2; fi

  MICRO_LOG=$(mktemp /tmp/eval_gate_micro.XXXXXX.log)
  log "  comparing..."
  (cd "$BENCH_CRATE" && "$MICRO_CAND_BIN" --bench "$MICRO_BENCH_FILTER" \
    --baseline micro_base \
    --sample-size "$MICRO_SAMPLE_SIZE" --measurement-time "$MICRO_MEASUREMENT_TIME" --noplot \
    > "$MICRO_LOG" 2>&1) || true

  # Parse criterion change output
  MICRO_DELTA=$(grep -oP 'change:\s*\[\s*[-+]?[0-9.]+%\s+\K[-+]?[0-9.]+' "$MICRO_LOG" | head -1 || echo "NA")
  MICRO_P=$(grep -oP 'change:\s*\[[^\]]+\]\s*\(p\s*=\s*\K[0-9.]+' "$MICRO_LOG" | head -1 || echo "NA")

  T1=$(date +%s)
  MICRO_TIME=$((T1-T0))

  log "  micro: delta=${MICRO_DELTA}%  p=${MICRO_P}  time=${MICRO_TIME}s"

  # Pre-filter: if improvement is too small, skip Criterion
  MICRO_DECISION=$(python3 -c "
d = '$MICRO_DELTA'
thr = $MICRO_MIN_LOCAL_PCT
if d == 'NA':
    print('PASS')  # can't parse → don't block, let Criterion decide
else:
    d = float(d)
    if d > -thr:
        print('FAIL')
    else:
        print('PASS')
")

  log "  micro decision: $MICRO_DECISION (threshold: -${MICRO_MIN_LOCAL_PCT}%)"

  if [[ "$MICRO_DECISION" == "FAIL" ]]; then
    log "VERDICT: DISCARD (micro pre-filter: ${MICRO_DELTA}% > -${MICRO_MIN_LOCAL_PCT}% threshold)"
    python3 -c "
import json
print(json.dumps({
  'verdict': 'DISCARD',
  'status': 'discard_micro',
  'tier1_micro': '$MICRO_DELTA',
  'tier2_criterion_pct': '-',
  'tier2_p': '-',
  'tier3_prod_pct': '-',
  'gate_time_s': $MICRO_TIME,
}, indent=2))
" > /tmp/eval_gate_summary.json
    cat /tmp/eval_gate_summary.json
    exit 1
  fi
fi

# -----------------------------------------------------------------------
# Tier 2: Criterion e2e (xmss_leaf_1400sigs)
# -----------------------------------------------------------------------
log "Tier 2: Criterion e2e..."
T0=$(date +%s)

# Restore git state for eval_paired (it does its own checkouts)
(cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true)

PAIRED_EXIT=0
bash "$SHARED_DIR/eval_paired.sh" \
  --baseline "$BASELINE_REF" --candidate "$CANDIDATE_REF" --n 1 \
  > /tmp/eval_gate_paired.log 2>&1 || PAIRED_EXIT=$?

T1=$(date +%s)
PAIRED_TIME=$((T1-T0))

PAIRED_DELTA="-"
PAIRED_P="-"
BASE_HASH="-"
CAND_HASH="-"

if [[ -f /tmp/eval_paired_summary.json ]]; then
  PAIRED_DELTA=$(python3 -c "import json; d=json.load(open('/tmp/eval_paired_summary.json')); print(f\"{d['deltas_pct'][0]:+.4f}\")")
  PAIRED_P=$(python3 -c "import json; d=json.load(open('/tmp/eval_paired_summary.json')); print(d['p_values'][0])")
  BASE_HASH=$(python3 -c "import json; d=json.load(open('/tmp/eval_paired_summary.json')); print(d.get('hash_base','-'))" 2>/dev/null || echo "-")
  CAND_HASH=$(python3 -c "import json; d=json.load(open('/tmp/eval_paired_summary.json')); print(d.get('hash_cand','-'))" 2>/dev/null || echo "-")
fi

log "criterion: delta=${PAIRED_DELTA}%  p=${PAIRED_P}  time=${PAIRED_TIME}s"

TOTAL_TIME=$((MICRO_TIME + PAIRED_TIME))

# Decision: keep if delta <= -KEEP_THRESHOLD_PCT AND p < 0.01
VERDICT=$(python3 -c "
delta_str, p_str, thr_str = '$PAIRED_DELTA', '$PAIRED_P', '$KEEP_THRESHOLD_PCT'
try:
    delta, p, thr = float(delta_str), float(p_str), float(thr_str)
    if delta <= -thr and p < 0.01:
        print('KEEP')
    else:
        print('DISCARD:discard_wallclock')
except ValueError:
    print('DISCARD:infra_fail')
")

STATUS="${VERDICT#*:}"
VERDICT_CLEAN="${VERDICT%%:*}"
if [[ "$STATUS" == "$VERDICT_CLEAN" ]]; then
  STATUS="keep"
fi

log "VERDICT: $VERDICT_CLEAN  (status=$STATUS, total_time=${TOTAL_TIME}s)"

python3 -c "
import json
print(json.dumps({
  'verdict': '$VERDICT_CLEAN',
  'status': '$STATUS',
  'tier1_micro': '$MICRO_DELTA',
  'tier2_criterion_pct': '$PAIRED_DELTA',
  'tier2_p': '$PAIRED_P',
  'tier3_prod_pct': '-',
  'base_hash': '$BASE_HASH',
  'cand_hash': '$CAND_HASH',
  'gate_time_s': $TOTAL_TIME,
}, indent=2))
" > /tmp/eval_gate_summary.json

cat /tmp/eval_gate_summary.json

if [[ "$VERDICT_CLEAN" == "KEEP" ]]; then
  log "Tier 3 (production) should be run separately: bash $SCRIPT_DIR/reproduce_prod.sh"
  exit 0
else
  exit 1
fi
