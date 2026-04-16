#!/bin/bash
# Unified gate for leanMultisig autoresearch loop.
#
# Runs iai → paired → revert-A/B in sequence, applies the combined decision
# table, and outputs a single KEEP/DISCARD verdict.
#
# Usage:
#   eval_gate.sh                         # default: HEAD~1 vs HEAD
#   eval_gate.sh --baseline <ref> --candidate <ref>
#
# Outputs:
#   /tmp/eval_gate_summary.json — verdict + all fields needed for iters.tsv
#   Exit: 0 = KEEP, 1 = DISCARD, 2 = infra error
#
# The agent does NOT need to interpret the decision table manually.
# For debugging, individual scripts are available: eval_iai.sh, eval_paired.sh,
# eval_revert_ab.sh (see shared/README.md).

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}

# Thresholds (from config.env)
source "$SHARED_DIR/config.env" 2>/dev/null || true
KEEP_THRESHOLD_PCT=${KEEP_THRESHOLD_PCT:-1.5}
MARGINAL_MULT=${MARGINAL_MULT:-2.0}
WALLCLOCK_REGRESSION_PCT=${WALLCLOCK_REGRESSION_PCT:-0.5}

BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)  BASELINE_REF="$2"; shift 2 ;;
    --candidate) CANDIDATE_REF="$2"; shift 2 ;;
    *)           echo "[gate] unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[gate] $*"; }

# Detect [wallclock-only] tag in the candidate commit message body
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")
COMMIT_BODY=$(cd "$LM_REPO" && git log --format="%b" -1 "$CANDIDATE_SHA")
WALLCLOCK_ONLY=false
if echo "$COMMIT_BODY" | grep -qi '\[wallclock-only\]'; then
  WALLCLOCK_ONLY=true
  log "detected [wallclock-only] tag — skipping iai gate"
fi

# -----------------------------------------------------------------------
# Stage 1: iai
# -----------------------------------------------------------------------
IAI_DECISION="SKIP"
IAI_DELTA="-"
IAI_TIME=0

if [[ "$WALLCLOCK_ONLY" == "false" ]]; then
  log "Stage 1: iai gate..."
  T0=$(date +%s)
  bash "$SHARED_DIR/eval_iai.sh" --baseline "$BASELINE_REF" --candidate "$CANDIDATE_REF" \
    > /tmp/eval_gate_iai.log 2>&1 || true
  T1=$(date +%s)
  IAI_TIME=$((T1-T0))

  if [[ -f /tmp/eval_iai_summary.json ]]; then
    IAI_DECISION=$(python3 -c "import json; print(json.load(open('/tmp/eval_iai_summary.json'))['decision'])")
    IAI_DELTA=$(python3 -c "import json; print(f\"{json.load(open('/tmp/eval_iai_summary.json'))['total_tracked_delta_pct']:+.4f}\")")
  else
    IAI_DECISION="ERROR"
  fi

  log "iai: decision=$IAI_DECISION  delta=${IAI_DELTA}%  time=${IAI_TIME}s"

  if [[ "$IAI_DECISION" == "FAIL" ]]; then
    log "VERDICT: DISCARD (iai failed, no wallclock-only tag)"
    python3 -c "
import json
print(json.dumps({
  'verdict': 'DISCARD',
  'status': 'discard_iai',
  'stage1_iai_delta': '$IAI_DELTA',
  'stage1_iai_decision': '$IAI_DECISION',
  'stage2_median_pct': '-',
  'stage2_p': '-',
  'revert_ab': 'n/a',
  'base_hash': '-',
  'cand_hash': '-',
  'gate_time_s': $IAI_TIME,
}, indent=2))
" > /tmp/eval_gate_summary.json
    cat /tmp/eval_gate_summary.json
    exit 1
  fi
fi

# -----------------------------------------------------------------------
# Stage 2: paired wall-clock
# -----------------------------------------------------------------------
log "Stage 2: paired wall-clock..."
T0=$(date +%s)
bash "$SHARED_DIR/eval_paired.sh" --baseline "$BASELINE_REF" --candidate "$CANDIDATE_REF" --n 1 \
  > /tmp/eval_gate_paired.log 2>&1 || true
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

log "paired: delta=${PAIRED_DELTA}%  p=${PAIRED_P}  time=${PAIRED_TIME}s"

TOTAL_TIME=$((IAI_TIME + PAIRED_TIME))

# -----------------------------------------------------------------------
# Apply combined decision table
# -----------------------------------------------------------------------
VERDICT=$(python3 - "$IAI_DECISION" "$WALLCLOCK_ONLY" "$PAIRED_DELTA" "$PAIRED_P" \
  "$KEEP_THRESHOLD_PCT" "$WALLCLOCK_REGRESSION_PCT" <<'PY'
import sys
iai_dec, wc_only_str, delta_str, p_str, threshold_str, regr_str = sys.argv[1:]
wc_only = wc_only_str == "true"
try:
    delta = float(delta_str)
    p = float(p_str)
except ValueError:
    print("DISCARD:infra_fail")
    sys.exit(0)
threshold = float(threshold_str)
regr = float(regr_str)

if wc_only:
    # [wallclock-only]: strict wall-clock threshold
    if delta <= -threshold and p < 0.01:
        print("KEEP")
    else:
        print("DISCARD:discard_wallclock")
else:
    # iai passed (we already exited on FAIL above)
    # Check for clear wall-clock regression
    if delta >= regr and p < 0.05:
        print("DISCARD:discard_wallclock_regression")
    else:
        # iai passed + wall-clock not clearly regressing → KEEP
        print("KEEP")
PY
)

STATUS="${VERDICT#*:}"
VERDICT_CLEAN="${VERDICT%%:*}"

if [[ "$STATUS" == "$VERDICT_CLEAN" ]]; then
  # No colon → KEEP, derive status
  STATUS="keep"
fi

log "decision table: verdict=$VERDICT_CLEAN  status=$STATUS"

# -----------------------------------------------------------------------
# Stage 3: revert-A/B for marginal keeps
# -----------------------------------------------------------------------
REVERT_AB="n/a"
MARGINAL_THRESH=$(python3 -c "print(float('$KEEP_THRESHOLD_PCT') * float('$MARGINAL_MULT'))")

if [[ "$VERDICT_CLEAN" == "KEEP" ]]; then
  # Check if marginal
  ABS_DELTA=$(python3 -c "print(abs(float('$PAIRED_DELTA')))")
  IS_MARGINAL=$(python3 -c "print('yes' if float('$ABS_DELTA') < float('$MARGINAL_THRESH') else 'no')")

  if [[ "$IS_MARGINAL" == "yes" ]]; then
    log "Stage 3: marginal keep (|Δ|=${ABS_DELTA}% < ${MARGINAL_THRESH}%), running revert-A/B..."
    T0=$(date +%s)
    bash "$SHARED_DIR/eval_revert_ab.sh" "$ABS_DELTA" > /tmp/eval_gate_revert.log 2>&1
    REVERT_EXIT=$?
    T1=$(date +%s)
    TOTAL_TIME=$((TOTAL_TIME + T1 - T0))

    if [[ "$REVERT_EXIT" -eq 0 ]]; then
      REVERT_AB="pass"
      log "revert-A/B: PASS — keep confirmed"
    else
      REVERT_AB="fail"
      VERDICT_CLEAN="DISCARD"
      STATUS="revert_ab_failed"
      log "revert-A/B: FAIL — noise rider, discarding"
    fi
  else
    log "not marginal (|Δ|=${ABS_DELTA}% >= ${MARGINAL_THRESH}%), skipping revert-A/B"
  fi
fi

# -----------------------------------------------------------------------
# Output summary
# -----------------------------------------------------------------------
log "VERDICT: $VERDICT_CLEAN  (status=$STATUS, total_time=${TOTAL_TIME}s)"

python3 -c "
import json
print(json.dumps({
  'verdict': '$VERDICT_CLEAN',
  'status': '$STATUS',
  'stage1_iai_delta': '$IAI_DELTA',
  'stage1_iai_decision': '$IAI_DECISION',
  'stage2_median_pct': '$PAIRED_DELTA',
  'stage2_p': '$PAIRED_P',
  'revert_ab': '$REVERT_AB',
  'base_hash': '$BASE_HASH',
  'cand_hash': '$CAND_HASH',
  'gate_time_s': $TOTAL_TIME,
}, indent=2))
" > /tmp/eval_gate_summary.json

cat /tmp/eval_gate_summary.json

if [[ "$VERDICT_CLEAN" == "KEEP" ]]; then
  exit 0
else
  exit 1
fi
