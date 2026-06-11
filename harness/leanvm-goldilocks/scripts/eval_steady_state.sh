#!/bin/bash
# Steady-state wall-clock measurement for leanVM.
#
# Measures warm proof times at steady-state (after ~200 warmup proofs)
# rather than fresh-warm (proofs 1-4). Captures the regime production
# operates in — hundreds of consecutive proofs per process.
#
# Usage:
#   eval_steady_state.sh --baseline <sha> --candidate <sha>
#   eval_steady_state.sh --baseline-bin /tmp/base --candidate-bin /tmp/cand \
#                        --baseline <sha> --candidate <sha>
#
# When --baseline-bin / --candidate-bin are provided, skips the build
# step and reuses pre-built binaries (e.g. from eval_paired.sh).
# --baseline / --candidate SHAs are still needed for git checkout
# during measurement (runtime data safety).
#
# Output:
#   stdout: human-readable summary
#   /tmp/eval_steady_state_summary.json
#
# Exit codes:
#   0 = no regression at steady state
#   1 = regression detected (>1% with p<0.05)
#   2 = infrastructure error

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanVM}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanvm-goldilocks/bench}
STEADY_N_PROOFS=${STEADY_STATE_N_PROOFS:-250}
STEADY_MEASURE_LAST=${STEADY_STATE_MEASURE_LAST:-50}
TASKSET_CORES=${TASKSET_CORES:-"0-7"}

export RUSTFLAGS="-C target-cpu=native"

BASELINE_SHA=""
CANDIDATE_SHA=""
BASELINE_BIN=""
CANDIDATE_BIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)      BASELINE_SHA="$2"; shift 2 ;;
    --candidate)     CANDIDATE_SHA="$2"; shift 2 ;;
    --baseline-bin)  BASELINE_BIN="$2"; shift 2 ;;
    --candidate-bin) CANDIDATE_BIN="$2"; shift 2 ;;
    --proofs)        STEADY_N_PROOFS="$2"; shift 2 ;;
    --measure-last)  STEADY_MEASURE_LAST="$2"; shift 2 ;;
    *)               echo "[eval_steady_state] unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[eval_steady_state] $*"; }
err() { echo "[eval_steady_state][err] $*" >&2; }

drop_caches() {
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
}

run_pinned() {
  if command -v taskset > /dev/null 2>&1 && [[ -n "$TASKSET_CORES" ]]; then
    taskset -c "$TASKSET_CORES" "$@"
  else
    "$@"
  fi
}

# Resolve binaries
if [[ -z "$BASELINE_BIN" || -z "$CANDIDATE_BIN" ]]; then
  if [[ -z "$BASELINE_SHA" || -z "$CANDIDATE_SHA" ]]; then
    err "need --baseline/--candidate SHAs or --baseline-bin/--candidate-bin paths"
    exit 2
  fi
  build_prove_loop() {
    local ref="$1" out="$2"
    (cd "$LM_REPO" && git checkout --quiet "$ref")
    (
      cd "$BENCH_CRATE"
      cargo clean --release >/dev/null 2>&1 || true
      cargo build --release --bin prove_loop --features zkalloc_global 2>&1 | tail -3 >&2
      cp target/release/prove_loop "$out"
    )
  }
  log "building baseline..."
  build_prove_loop "$BASELINE_SHA" /tmp/prove_loop_ss_base
  log "building candidate..."
  build_prove_loop "$CANDIDATE_SHA" /tmp/prove_loop_ss_cand
  BASELINE_BIN="/tmp/prove_loop_ss_base"
  CANDIDATE_BIN="/tmp/prove_loop_ss_cand"
fi

if [[ -n "$BASELINE_SHA" ]]; then
  ORIG_HEAD_SS=$(cd "$LM_REPO" && git rev-parse HEAD)
  trap '(cd "$LM_REPO" && git checkout --quiet "$ORIG_HEAD_SS" 2>/dev/null) || true' EXIT
fi

CUTOFF=$((STEADY_N_PROOFS - STEADY_MEASURE_LAST))
log "proofs=$STEADY_N_PROOFS  measure_last=$STEADY_MEASURE_LAST  cutoff_idx=$CUTOFF"
log "estimated time: ~$((STEADY_N_PROOFS * 2 * 2))s (~$((STEADY_N_PROOFS * 2 * 2 / 60))min)"

# Run baseline
log "running baseline ($STEADY_N_PROOFS proofs)..."
[[ -n "$BASELINE_SHA" ]] && (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
drop_caches
BASE_CSV=$(mktemp /tmp/eval_ss_base.XXXXXX.csv)
run_pinned "$BASELINE_BIN" "$STEADY_N_PROOFS" > "$BASE_CSV" 2>/dev/null

# Run candidate
log "running candidate ($STEADY_N_PROOFS proofs)..."
[[ -n "$CANDIDATE_SHA" ]] && (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
drop_caches
CAND_CSV=$(mktemp /tmp/eval_ss_cand.XXXXXX.csv)
run_pinned "$CANDIDATE_BIN" "$STEADY_N_PROOFS" > "$CAND_CSV" 2>/dev/null

# Analyze
SUMMARY=$(python3 - "$BASE_CSV" "$CAND_CSV" "$CUTOFF" <<'PY'
import sys, json, math, statistics as st

base_path, cand_path, cutoff = sys.argv[1], sys.argv[2], int(sys.argv[3])

def parse_steady(path, cutoff):
    times = []
    for line in open(path):
        line = line.strip()
        if line.startswith("proof,"): continue
        parts = line.split(",")
        if len(parts) < 2: continue
        idx, secs = int(parts[0]), float(parts[1])
        if idx >= cutoff:
            times.append(secs)
    return times

base = parse_steady(base_path, cutoff)
cand = parse_steady(cand_path, cutoff)

if not base or not cand:
    print(json.dumps({"error": "no steady-state proof times collected"}))
    sys.exit(0)

n_b, n_c = len(base), len(cand)
mean_b, mean_c = st.mean(base), st.mean(cand)
delta_pct = (mean_c - mean_b) / mean_b * 100

var_b = st.variance(base) if n_b >= 2 else 0
var_c = st.variance(cand) if n_c >= 2 else 0
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
    def pdf(x):
        return coeff * (1 + x*x/nu) ** (-(nu+1)/2)
    abs_t = abs(t_val)
    upper = abs_t + 50
    n_pts = 10000
    h = (upper - abs_t) / n_pts
    s = 0.5 * (pdf(abs_t) + pdf(upper))
    for i in range(1, n_pts):
        s += pdf(abs_t + i * h)
    return min(1.0, 2 * s * h)

p_value = t_pvalue(t_stat, df) if df > 0 else 1.0

if delta_pct > 1.0 and p_value < 0.05:
    verdict = "regression"
elif delta_pct < -1.0 and p_value < 0.05:
    verdict = "improved"
else:
    verdict = "no_change"

summary = {
    "regime": "steady_state",
    "cutoff_idx": cutoff,
    "total_proofs_per_side": cutoff + n_b,
    "measured_proofs_per_side": n_b,
    "base_avg_s": round(mean_b, 4),
    "cand_avg_s": round(mean_c, 4),
    "base_std_s": round(st.stdev(base), 4) if n_b >= 2 else 0,
    "cand_std_s": round(st.stdev(cand), 4) if n_c >= 2 else 0,
    "delta_pct": round(delta_pct, 2),
    "t_stat": round(t_stat, 3),
    "p_value": round(p_value, 6),
    "df": round(df, 1),
    "verdict": verdict,
}
print(json.dumps(summary, indent=2))
PY
)

echo ""
echo "=== STEADY-STATE SUMMARY ==="
echo "$SUMMARY"

echo "$SUMMARY" > /tmp/eval_steady_state_summary.json
rm -f "$BASE_CSV" "$CAND_CSV"

verdict=$(python3 -c "import json; print(json.load(open('/tmp/eval_steady_state_summary.json')).get('verdict','no_change'))")
case "$verdict" in
  regression) exit 1 ;;
  *) exit 0 ;;
esac
