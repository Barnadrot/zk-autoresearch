#!/bin/bash
# Production gate for experiment 5 (Poseidon + WHIR).
#
# Measures fancy-aggregation wall-clock on baseline vs candidate.
# Only run after a Tier 2 (Criterion) keep — this takes ~20 minutes.
#
# Usage:
#   bash reproduce_prod.sh
#   bash reproduce_prod.sh --baseline <ref> --candidate <ref>
#   RUNS=5 bash reproduce_prod.sh
#
# Outputs production delta + qualitative assessment.
# Ship/no-ship decision based on production delta.

set -eo pipefail

LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
BASELINE_REF=${BASELINE_REF:-"origin/main"}
CANDIDATE_REF=${CANDIDATE_REF:-"HEAD"}
RUNS=${RUNS:-3}

export RUSTFLAGS="-C target-cpu=native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)    BASELINE_REF="$2"; shift 2 ;;
    --candidate)   CANDIDATE_REF="$2"; shift 2 ;;
    --runs)        RUNS="$2"; shift 2 ;;
    *)             echo "[prod] unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[prod] $*"; }
err() { echo "[prod][ERROR] $*" >&2; }

if [[ ! -d "$LM_REPO" ]]; then
  err "leanMultisig/ not found at $LM_REPO"
  exit 2
fi

ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")

trap 'log "restoring git state..."; cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

log "baseline  : $BASELINE_REF ($BASELINE_SHA)"
log "candidate : $CANDIDATE_REF ($CANDIDATE_SHA)"
log "runs      : $RUNS"

run_fancy() {
  local start end
  start=$(date +%s.%N)
  (cd "$LM_REPO" && ./target/release/lean-multisig fancy-aggregation) >/dev/null 2>&1
  end=$(date +%s.%N)
  python3 -c "print(f'{$end - $start:.2f}')"
}

# ── Baseline ──────────────────────────────────────────────────────────

log "checking out BASELINE ($BASELINE_REF)..."
(cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")

log "cleaning + building baseline..."
(cd "$LM_REPO" && cargo clean && cargo build --release) 2>&1 | tail -5

BASE_BIN=$(ls -t "$LM_REPO"/target/release/lean-multisig 2>/dev/null | head -1 || true)
HASH_BASE=$(md5sum "$BASE_BIN" 2>/dev/null | awk '{print $1}' || echo "unknown")
log "baseline binary hash: $HASH_BASE"

BASE_TIMES=()
for ((i=1; i<=RUNS; i++)); do
  log "baseline run $i/$RUNS..."
  t=$(run_fancy)
  BASE_TIMES+=("$t")
  log "  → ${t}s"
done

# ── Candidate ─────────────────────────────────────────────────────────

log "checking out CANDIDATE ($CANDIDATE_REF)..."
(cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")

log "cleaning + building candidate..."
(cd "$LM_REPO" && cargo clean && cargo build --release) 2>&1 | tail -5

CAND_BIN=$(ls -t "$LM_REPO"/target/release/lean-multisig 2>/dev/null | head -1 || true)
HASH_CAND=$(md5sum "$CAND_BIN" 2>/dev/null | awk '{print $1}' || echo "unknown")
log "candidate binary hash: $HASH_CAND"

if [[ "$HASH_BASE" == "$HASH_CAND" ]]; then
  err "IDENTICAL binary hashes — stale build. Result invalid."
  exit 1
fi

CAND_TIMES=()
for ((i=1; i<=RUNS; i++)); do
  log "candidate run $i/$RUNS..."
  t=$(run_fancy)
  CAND_TIMES+=("$t")
  log "  → ${t}s"
done

# ── Summary ───────────────────────────────────────────────────────────

echo ""
echo "=== PRODUCTION RESULTS ==="
python3 - "${BASE_TIMES[*]}" "${CAND_TIMES[*]}" "$HASH_BASE" "$HASH_CAND" <<'PY'
import sys, statistics as s, json

base_str, cand_str, h_base, h_cand = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base = sorted(float(x) for x in base_str.split())
cand = sorted(float(x) for x in cand_str.split())

med_base = s.median(base)
med_cand = s.median(cand)
delta_pct = (med_cand - med_base) / med_base * 100

result = {
    "experiment": "poseidon_whir (exp5)",
    "baseline_median_s": round(med_base, 2),
    "candidate_median_s": round(med_cand, 2),
    "delta_pct": round(delta_pct, 2),
    "hash_base": h_base[:8],
    "hash_cand": h_cand[:8],
    "runs": len(base),
}

print(f"Baseline  ({h_base[:8]}): {', '.join(f'{t:.2f}s' for t in base)}  (median {med_base:.2f}s)")
print(f"Candidate ({h_cand[:8]}): {', '.join(f'{t:.2f}s' for t in cand)}  (median {med_cand:.2f}s)")
print(f"Delta: {delta_pct:+.2f}%  (negative = improvement)")
print()

if delta_pct < -2:
    print(f"SHIP: production improvement confirmed at {abs(delta_pct):.1f}%")
    result["decision"] = "ship"
elif delta_pct < 0:
    print(f"MARGINAL: {abs(delta_pct):.1f}% improvement, within noise range — consider re-running with RUNS=5")
    result["decision"] = "marginal"
else:
    print(f"NO-SHIP: no production improvement detected")
    result["decision"] = "no-ship"

with open("/tmp/eval_prod_summary.json", "w") as f:
    json.dump(result, f, indent=2)
print(f"\nSummary written to /tmp/eval_prod_summary.json")
PY
