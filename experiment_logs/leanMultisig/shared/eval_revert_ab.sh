#!/bin/bash
# Revert-A/B check: confirm a kept change is not a noise rider.
#
# Called AFTER a change has been committed as a keep, BEFORE the next iter.
# Creates a temporary revert commit on top of HEAD, runs paired A/B (HEAD~1 =
# the keep, HEAD = reverted), then unwinds the temporary revert.
#
# Expected outcome: Δ > +claim_delta_pct  (i.e. reverting makes things slower
# by approximately the originally claimed improvement magnitude). If not, the
# keep was a noise rider and MUST be unwound manually by the caller.
#
# Usage:
#   eval_revert_ab.sh <claim_delta_pct>
#     claim_delta_pct: the positive magnitude the original keep claimed
#                      (e.g. if the keep showed -1.2%, pass 1.2)
#
# Exit: 0 = keep confirmed, 1 = revert showed insufficient Δ (noise rider),
#       2 = infrastructure error.

set -eo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: eval_revert_ab.sh <claim_delta_pct>" >&2
  exit 2
fi

CLAIM_PCT="$1"
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
SHARED_DIR="$(dirname "$0")"

# Tolerance: revert must reproduce at least half of the claimed improvement.
MIN_REPRODUCE_FRACTION=${MIN_REPRODUCE_FRACTION:-0.5}

ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)

cleanup() {
  # Always return the tree to ORIG_HEAD (remove any revert commit we added)
  (cd "$LM_REPO" && git reset --hard "$ORIG_HEAD" 2>/dev/null || true)
}
trap cleanup EXIT

# Step 1: create a revert commit on top of ORIG_HEAD
(cd "$LM_REPO" && git revert --no-edit "$ORIG_HEAD") >/dev/null || {
  echo "[revert_ab][err] git revert failed" >&2
  exit 2
}

# Step 2: paired A/B with HEAD~1 (the keep) as baseline and HEAD (reverted) as candidate
#         If the keep is real, reverting SHOULD make it slower → Δ positive.
bash "$SHARED_DIR/eval_paired.sh" --baseline 'HEAD~1' --candidate 'HEAD' --n 1 --threshold 0.0 \
     > /tmp/revert_ab.log 2>&1 || true

# eval_paired prints JSON summary; grab its decision + median
MED=$(python3 -c '
import json
d = json.load(open("/tmp/eval_paired_summary.json"))
print(d["median_pct"])')
P=$(python3 -c '
import json
d = json.load(open("/tmp/eval_paired_summary.json"))
print(d["p_values"][0])')

cleanup
trap - EXIT

# Decision: revert Δ should be >= CLAIM_PCT * MIN_REPRODUCE_FRACTION (positive)
echo "[revert_ab] revert Δ = ${MED}%  p = ${P}  claim_pct = ${CLAIM_PCT}"
python3 - "$MED" "$P" "$CLAIM_PCT" "$MIN_REPRODUCE_FRACTION" <<'PY'
import sys
med, p, claim, frac = map(float, sys.argv[1:])
expected = claim * frac
if med >= expected and p < 0.05:
    print(f"[revert_ab] PASS: revert reproduced {med:.3f}% (expected >= {expected:.3f}%)")
    sys.exit(0)
print(f"[revert_ab] FAIL: revert delta {med:.3f}% below threshold {expected:.3f}% (p={p})")
sys.exit(1)
PY
