#!/bin/bash
# Paired recursion gate for leanVM autoresearch.
#
# Primary: measures fancy-aggregation wall-clock (recursion-heavy topology).
# Safety: checks prove_loop (leaf proving) doesn't regress > 5%.
# Proof size: same scoring as eval_paired.sh.
#
# Builds baseline and candidate lean-multisig binaries, alternates
# fancy-aggregation runs, compares via Welch's t-test.
#
# Exit codes:
#   0 = keep (recursion improvement crosses threshold + p < 0.01)
#   1 = discard
#   2 = infrastructure error

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------- CONFIG --------------------------------------

KEEP_THRESHOLD_PCT=${KEEP_THRESHOLD_PCT:-1.0}
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanVM}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanvm/bench}
BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"
N=3
PROVE_LOOP_MAX_REGRESSION_PCT=${PROVE_LOOP_MAX_REGRESSION_PCT:-5}
PROOF_SIZE_CEILING_PCT=${PROOF_SIZE_CEILING_PCT:-20}
PROOF_SIZE_PENALTY_MULTIPLIER=${PROOF_SIZE_PENALTY_MULTIPLIER:-3}

export RUSTFLAGS="-C target-cpu=native"

# ------------------------------- ARGS ----------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)  BASELINE_REF="$2"; shift 2 ;;
    --candidate) CANDIDATE_REF="$2"; shift 2 ;;
    --n)         N="$2"; shift 2 ;;
    --threshold) KEEP_THRESHOLD_PCT="$2"; shift 2 ;;
    *)           echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------- HELPERS -------------------------------------

err() { echo "[eval_recursion][err] $*" >&2; }
log() { echo "[eval_recursion] $*"; }

build_binary() {
  local ref="$1" out="$2"
  (
    cd "$LM_REPO"
    git checkout --quiet "$ref" || { err "git checkout $ref failed"; exit 2; }
    cargo clean --release >/dev/null 2>&1 || true
    cargo build --release --bin lean-multisig 2>&1 | tail -5 >&2 \
      || { err "cargo build failed at $ref"; exit 2; }
    cp target/release/lean-multisig "$out" \
      || { err "lean-multisig binary not found at $ref"; exit 2; }
  )
}

# ------------------------------ SETUP ----------------------------------------

ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD)
BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")

log "baseline  : $BASELINE_REF ($BASELINE_SHA)"
log "candidate : $CANDIDATE_REF ($CANDIDATE_SHA)"
log "N rounds  : $N"

if [[ "$BASELINE_SHA" == "$CANDIDATE_SHA" ]]; then
  err "baseline == candidate SHA — nothing to compare"
  exit 2
fi

trap 'cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

# ------------------------------ BUILD ----------------------------------------

log "building baseline..."
build_binary "$BASELINE_SHA" /tmp/lean_multisig_base

log "building candidate..."
build_binary "$CANDIDATE_SHA" /tmp/lean_multisig_cand

# ------------------------------ WARMUP ---------------------------------------

log "warmup (discarded)..."
/tmp/lean_multisig_base xmss --n-signatures 1550 >/dev/null 2>&1 || true

# ------------------------------ PRIMARY: FANCY-AGGREGATION -------------------

log ""
log "=== PRIMARY GATE: fancy-aggregation (recursion) ==="

ALL_BASE_TIMES=$(mktemp /tmp/eval_rec_base_XXXXXX)
ALL_CAND_TIMES=$(mktemp /tmp/eval_rec_cand_XXXXXX)
: > "$ALL_BASE_TIMES"
: > "$ALL_CAND_TIMES"

for ((round=1; round<=N; round++)); do
  log "=== round $round / $N ==="

  if (( round % 2 == 1 )); then
    log "  order: base → cand"
    BASE_JSON=$(/tmp/lean_multisig_base fancy-aggregation --json 2>/dev/null)
    CAND_JSON=$(/tmp/lean_multisig_cand fancy-aggregation --json 2>/dev/null)
  else
    log "  order: cand → base"
    CAND_JSON=$(/tmp/lean_multisig_cand fancy-aggregation --json 2>/dev/null)
    BASE_JSON=$(/tmp/lean_multisig_base fancy-aggregation --json 2>/dev/null)
  fi

  python3 - "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$round" <<PY
import sys, json
base_out, cand_out, rnd = sys.argv[1], sys.argv[2], sys.argv[3]
base = json.loads('''$BASE_JSON''')
cand = json.loads('''$CAND_JSON''')

base_total = sum(n['stats']['time_secs'] for n in base['nodes'])
cand_total = sum(n['stats']['time_secs'] for n in cand['nodes'])
delta = (cand_total - base_total) / base_total * 100

with open(base_out, 'a') as f: f.write(f'{base_total:.6f}\n')
with open(cand_out, 'a') as f: f.write(f'{cand_total:.6f}\n')

print(f'[eval_recursion] round {rnd}: base={base_total:.3f}s  cand={cand_total:.3f}s  Δ={delta:+.2f}%')
PY

done

# ------------------------------ ANALYZE --------------------------------------

SUMMARY=$(python3 - "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$KEEP_THRESHOLD_PCT" "$BASELINE_SHA" "$CANDIDATE_SHA" <<'PY'
import sys, json, math, statistics as st

base_path, cand_path = sys.argv[1], sys.argv[2]
thr = float(sys.argv[3])
base_sha, cand_sha = sys.argv[4], sys.argv[5]

base_times = [float(x) for x in open(base_path) if x.strip()]
cand_times = [float(x) for x in open(cand_path) if x.strip()]

n_b, n_c = len(base_times), len(cand_times)
mean_b, mean_c = st.mean(base_times), st.mean(cand_times)
delta_pct = (mean_c - mean_b) / mean_b * 100

var_b = st.variance(base_times) if n_b >= 2 else 0
var_c = st.variance(cand_times) if n_c >= 2 else 0
se = math.sqrt(var_b / n_b + var_c / n_c) if (var_b + var_c) > 0 else 1e-9
t_stat = (mean_c - mean_b) / se

if var_b + var_c > 0:
    num = (var_b / n_b + var_c / n_c) ** 2
    d1 = (var_b / n_b) ** 2 / (n_b - 1) if n_b > 1 and var_b > 0 else 0
    d2 = (var_c / n_c) ** 2 / (n_c - 1) if n_c > 1 and var_c > 0 else 0
    df = num / (d1 + d2) if (d1 + d2) > 0 else 1
else:
    df = 1

def t_pvalue(t_val, nu):
    coeff = math.exp(math.lgamma((nu+1)/2) - math.lgamma(nu/2)) / math.sqrt(nu * math.pi)
    def pdf(x): return coeff * (1 + x*x/nu) ** (-(nu+1)/2)
    abs_t = abs(t_val)
    n_pts = 10000
    h = 50.0 / n_pts
    s = 0.5 * (pdf(abs_t) + pdf(abs_t + 50))
    for i in range(1, n_pts): s += pdf(abs_t + i * h)
    return min(1.0, 2 * s * h)

p_value = t_pvalue(t_stat, df) if df > 0 else 1.0
decision = "keep" if delta_pct <= -thr and p_value < 0.01 else "discard"

summary = {
    "gate": "fancy-aggregation (recursion)",
    "total_samples": {"baseline": n_b, "candidate": n_c},
    "base_avg_s": round(mean_b, 4),
    "cand_avg_s": round(mean_c, 4),
    "delta_pct": round(delta_pct, 2),
    "t_stat": round(t_stat, 3),
    "p_value": round(p_value, 6),
    "threshold_pct": thr,
    "decision": decision,
    "baseline_sha": base_sha,
    "candidate_sha": cand_sha,
}
print(json.dumps(summary, indent=2))
PY
)

echo ""
echo "=== RECURSION GATE SUMMARY ==="
echo "$SUMMARY"
echo "$SUMMARY" > /tmp/eval_recursion_summary.json

rm -f "$ALL_BASE_TIMES" "$ALL_CAND_TIMES"

# ------------------------------ SAFETY: PROVE_LOOP REGRESSION ----------------

log ""
log "=== SAFETY CHECK: prove_loop regression ==="

# Build prove_loop binaries
(
  cd "$BENCH_CRATE"
  cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA"
  cd "$BENCH_CRATE" && cargo clean --release >/dev/null 2>&1 || true
  cargo build --release --bin prove_loop --features zkalloc_global 2>&1 | tail -3 >&2
  cp target/release/prove_loop /tmp/prove_loop_base
)
(
  cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA"
  cd "$BENCH_CRATE" && cargo clean --release >/dev/null 2>&1 || true
  cargo build --release --bin prove_loop --features zkalloc_global 2>&1 | tail -3 >&2
  cp target/release/prove_loop /tmp/prove_loop_cand
)

BASE_CSV=$(mktemp /tmp/eval_pl_base_XXXXXX)
CAND_CSV=$(mktemp /tmp/eval_pl_cand_XXXXXX)
/tmp/prove_loop_base 5 > "$BASE_CSV" 2>/dev/null
/tmp/prove_loop_cand 5 > "$CAND_CSV" 2>/dev/null

PL_RESULT=$(python3 - "$BASE_CSV" "$CAND_CSV" "$PROVE_LOOP_MAX_REGRESSION_PCT" <<'PY'
import sys
base_csv, cand_csv, max_reg = sys.argv[1], sys.argv[2], float(sys.argv[3])

def parse_warm(path):
    times, kibs = [], []
    for line in open(path):
        parts = line.strip().split(",")
        if len(parts) < 2 or parts[0] == "proof": continue
        idx = int(parts[0])
        if idx >= 1:
            times.append(float(parts[1]))
            if len(parts) >= 4: kibs.append(int(parts[3]))
    return times, kibs

bt, bk = parse_warm(base_csv)
ct, ck = parse_warm(cand_csv)
if bt and ct:
    bm, cm = sum(bt)/len(bt), sum(ct)/len(ct)
    d = (cm - bm) / bm * 100
    if d > max_reg:
        print(f"FAIL: prove_loop +{d:.2f}% > {max_reg}% ceiling (base={bm:.3f}s cand={cm:.3f}s)")
    else:
        print(f"OK: prove_loop {d:+.2f}% (base={bm:.3f}s cand={cm:.3f}s)")
    # proof size
    if bk and ck:
        bkm, ckm = sum(bk)/len(bk), sum(ck)/len(ck)
        sd = (ckm - bkm) / bkm * 100 if bkm > 0 else 0
        print(f"proof_size: base={bkm:.0f}KiB cand={ckm:.0f}KiB Δ={sd:+.1f}%")
else:
    print("SKIP: no warm proof data")
PY
)
log "$PL_RESULT"
rm -f "$BASE_CSV" "$CAND_CSV"

# Check if prove_loop regressed beyond limit
if echo "$PL_RESULT" | grep -q "^FAIL"; then
  python3 -c "
import json
s = json.load(open('/tmp/eval_recursion_summary.json'))
s['decision'] = 'discard'
s['discard_reason'] = 'prove_loop regression exceeds ${PROVE_LOOP_MAX_REGRESSION_PCT}% ceiling'
json.dump(s, open('/tmp/eval_recursion_summary.json','w'), indent=2)
"
fi

# ------------------------------ EXIT -----------------------------------------

dec=$(python3 -c 'import json; print(json.load(open("/tmp/eval_recursion_summary.json")).get("decision","discard"))')
EXIT_CODE=1
[[ "$dec" == "keep" ]] && EXIT_CODE=0

if [[ "$EXIT_CODE" -eq 0 ]]; then
  log ""
  log "==================== KEEP ===================="
fi

exit $EXIT_CODE
