#!/bin/bash
# Cumulative wall-clock measurement: origin/main vs HEAD.
#
# Used to anchor cumulative attribution after a keep lands. The per-iter
# eval_paired.sh measures marginal (HEAD~1 vs HEAD) which compounds poorly
# under machine-state drift (see pw4 audit, 2026-05-13). This script
# measures the full cumulative win vs the experiment's starting baseline,
# giving an interpretable wall-clock-vs-main number that is comparable
# across iterations and immune to per-iter baseline drift.
#
# Designed to be invoked automatically by eval_paired.sh after a KEEP
# decision, OR manually by the agent / orchestrator on demand.
#
# Usage:
#   bash eval_cumulative.sh                                   # origin/main vs HEAD, N=5
#   bash eval_cumulative.sh --anchor <ref> --n <int>
#
# Defaults:
#   ANCHOR_REF = origin/main
#   N = 5  (paired rounds — higher than the per-iter --n 1 default since
#           this measurement carries more weight)
#
# Output:
#   stdout: human-readable summary
#   /tmp/eval_cumulative_summary.json — full eval_paired output
#   experiment_logs/<exp>/report/cumulative_<timestamp>.json — archived (if EXPERIMENT_DIR set)
#
# Exit codes: inherit from eval_paired.sh
#   0 = win confirmed crosses threshold
#   1 = win below threshold (still measured, just not gate-crossing)
#   2 = infrastructure error

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
ANCHOR_REF="origin/main"
N=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --anchor) ANCHOR_REF="$2"; shift 2 ;;
    --n)      N="$2"; shift 2 ;;
    *)        echo "[eval_cumulative] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Pre-flight env check first
bash "$SHARED_DIR/env_preflight.sh" --json-only > /tmp/env_preflight_cumulative.json
PREFLIGHT_EXIT=$?
if [[ "$PREFLIGHT_EXIT" -ne 0 ]]; then
  echo "[eval_cumulative] env_preflight FAILED — refusing to measure" >&2
  bash "$SHARED_DIR/env_preflight.sh" >/dev/null  # re-run for human-readable stderr
  exit 2
fi

echo "[eval_cumulative] anchor=$ANCHOR_REF  N=$N"
echo "[eval_cumulative] delegating to eval_paired.sh..."

bash "$SHARED_DIR/eval_paired.sh" --baseline "$ANCHOR_REF" --candidate HEAD --n "$N"
PAIRED_EXIT=$?

# Save summary to standard cumulative path
if [[ -f /tmp/eval_paired_summary.json ]]; then
  cp /tmp/eval_paired_summary.json /tmp/eval_cumulative_summary.json

  # Archive under experiment dir if EXPERIMENT_DIR is set
  if [[ -n "${EXPERIMENT_DIR:-}" && -d "$EXPERIMENT_DIR" ]]; then
    TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    mkdir -p "$EXPERIMENT_DIR/report"
    ARCHIVE="$EXPERIMENT_DIR/report/cumulative_${TS}.json"
    cp /tmp/eval_cumulative_summary.json "$ARCHIVE"
    echo "[eval_cumulative] archived to $ARCHIVE"
  fi
fi

exit $PAIRED_EXIT
