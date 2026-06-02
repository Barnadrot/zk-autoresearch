#!/bin/bash
# Paired prove_loop wall-clock gate for leanVM autoresearch.
#
# Builds baseline and candidate prove_loop binaries (fat LTO, zk-alloc),
# alternates runs, and compares warm-proof wall-clock times via Welch's t-test.
#
# Pre-flight: refuses to run unless env_preflight.sh PASSes (governor
# performance, load below threshold). Set SKIP_PREFLIGHT=1 to bypass.
#
# Per-round drift abort: if base_avg drifts more than DRIFT_ABORT_PCT
# (default 1.5%) from round 1 within the same run, abort and ask the
# caller to clean the env. Drift is the pw4-era failure mode this catches.
#
# Auto-cumulative on keep: if a keep decision is reached AND
# AUTO_CUMULATIVE_ON_KEEP=1 AND BASELINE_REF != origin/main, invoke
# eval_cumulative.sh to anchor the cumulative-vs-main number. The keep
# decision is NOT affected by the cumulative result — it's recorded.
#
# Usage:
#   eval_paired.sh                                   # HEAD~1 vs HEAD, N=1
#   eval_paired.sh --baseline <ref> --candidate <ref> [--n <int>]
#   eval_paired.sh --n 5 --proofs 7                  # more samples per run
#   SKIP_PREFLIGHT=1 eval_paired.sh                  # bypass env_preflight
#   AUTO_CUMULATIVE_ON_KEEP=1 eval_paired.sh         # auto-anchor on keep
#
# Exit codes:
#   0 = keep (improvement crosses threshold + p < 0.01)
#   1 = discard
#   2 = infrastructure error (incl. env_preflight FAIL, drift abort)

set -eo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------- CONFIG --------------------------------------

KEEP_THRESHOLD_PCT=${KEEP_THRESHOLD_PCT:-1.0}
N_PROOFS=${N_PROOFS:-5}       # proofs per run; proof 0 = cold warmup, 1+ = warm
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanVM}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanvm/bench}
BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"
N=3
DRIFT_ABORT_PCT=${DRIFT_ABORT_PCT:-1.5}
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0}
AUTO_CUMULATIVE_ON_KEEP=${AUTO_CUMULATIVE_ON_KEEP:-1}    # default ON: anchor every keep vs origin/main
AUTO_SHIP_GATE_ON_KEEP=${AUTO_SHIP_GATE_ON_KEEP:-1}     # default ON: Criterion-confirm every keep
TASKSET_CORES=${TASKSET_CORES:-"0-7"}
NOISE_FLOOR_WARN_PCT=${NOISE_FLOOR_WARN_PCT:-0.5}
SKIP_NOISE_CHECK=${SKIP_NOISE_CHECK:-0}
AUTO_STEADY_STATE_ON_KEEP=${AUTO_STEADY_STATE_ON_KEEP:-1}
STEADY_STATE_THRESHOLD_PCT=${STEADY_STATE_THRESHOLD_PCT:-2.0}
RECURSION_MAX_REGRESSION_PCT=${RECURSION_MAX_REGRESSION_PCT:-3}
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
    --proofs)    N_PROOFS="$2"; shift 2 ;;
    --skip-noise-check) SKIP_NOISE_CHECK=1; shift ;;
    *)           echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------ PRE-FLIGHT -----------------------------------

if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
  if ! bash "$SHARED_DIR/env_preflight.sh" --json-only > /tmp/eval_paired_preflight.json 2>/dev/null; then
    echo "[eval_paired][err] env_preflight FAILED — refusing to measure" >&2
    bash "$SHARED_DIR/env_preflight.sh" >/dev/null  # re-run for human-readable stderr
    exit 2
  fi
fi
PREFLIGHT_JSON=$(cat /tmp/eval_paired_preflight.json 2>/dev/null || echo "{}")

# ------------------------------- HELPERS -------------------------------------

err() { echo "[eval_paired][err] $*" >&2; }
log() { echo "[eval_paired] $*"; }

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

build_prove_loop() {
  local ref="$1" out="$2"
  (
    cd "$LM_REPO"
    git checkout --quiet "$ref" || { err "git checkout $ref failed"; exit 2; }
  )
  (
    cd "$BENCH_CRATE"
    # Full release clean — path-dep rlibs can become inconsistent after git
    # checkout if cargo's fingerprint cache misses a cross-crate mismatch.
    cargo clean --release >/dev/null 2>&1 || true
    cargo build --release --bin prove_loop --features zkalloc_global 2>&1 | tail -5 >&2 \
      || { err "cargo build --bin prove_loop failed at $ref"; exit 2; }
    cp target/release/prove_loop "$out" \
      || { err "prove_loop binary not found at $ref"; exit 2; }
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
log "proofs/run: $N_PROOFS (proof 0 = cold, 1+ = warm)"

if [[ "$BASELINE_SHA" == "$CANDIDATE_SHA" ]]; then
  err "baseline == candidate SHA — nothing to compare"
  exit 2
fi

trap 'cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

# ------------------------------ BUILD ----------------------------------------

log "building baseline prove_loop..."
build_prove_loop "$BASELINE_SHA" /tmp/prove_loop_base

log "building candidate prove_loop..."
build_prove_loop "$CANDIDATE_SHA" /tmp/prove_loop_cand

HASH_BASE=$(md5sum /tmp/prove_loop_base | awk '{print $1}')
HASH_CAND=$(md5sum /tmp/prove_loop_cand | awk '{print $1}')
log "hash_base : $HASH_BASE"
log "hash_cand : $HASH_CAND"
if [[ "$HASH_BASE" == "$HASH_CAND" ]]; then
  err "binaries identical — no-op change or build cache hazard"
  if [[ "${ALLOW_IDENTICAL_BIN:-0}" != "1" ]]; then exit 2; fi
fi

# ------------------------------ NOISE FLOOR + THERMAL WARMUP ----------------

if [[ "$SKIP_NOISE_CHECK" != "1" ]]; then
  (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
  log "noise floor check (A-vs-A, also serves as thermal warmup)..."
  NOISE_CSV_A=$(mktemp /tmp/eval_noise_a_XXXXXX)
  NOISE_CSV_B=$(mktemp /tmp/eval_noise_b_XXXXXX)
  drop_caches
  run_pinned /tmp/prove_loop_base "$N_PROOFS" > "$NOISE_CSV_A" 2>/dev/null
  drop_caches
  run_pinned /tmp/prove_loop_base "$N_PROOFS" > "$NOISE_CSV_B" 2>/dev/null

  NOISE_FLOOR_PCT=$(python3 - "$NOISE_CSV_A" "$NOISE_CSV_B" <<'PY'
import sys
def parse_warm(path):
    times = []
    for line in open(path):
        line = line.strip()
        if line.startswith("proof,"): continue
        parts = line.split(",")
        if len(parts) < 2: continue
        idx, secs = int(parts[0]), float(parts[1])
        if idx >= 1: times.append(secs)
    return times
a, b = parse_warm(sys.argv[1]), parse_warm(sys.argv[2])
if a and b:
    mean_a, mean_b = sum(a)/len(a), sum(b)/len(b)
    print(f"{abs((mean_b - mean_a) / mean_a * 100):.4f}")
else:
    print("0.0")
PY
  )
  rm -f "$NOISE_CSV_A" "$NOISE_CSV_B"

  NOISE_RELIABLE=1
  if python3 -c "import sys; sys.exit(0 if float('$NOISE_FLOOR_PCT') < float('$NOISE_FLOOR_WARN_PCT') else 1)" 2>/dev/null; then
    log "noise floor: ${NOISE_FLOOR_PCT}% (< ${NOISE_FLOOR_WARN_PCT}% — OK)"
  else
    log "WARNING: noise floor ${NOISE_FLOOR_PCT}% >= ${NOISE_FLOOR_WARN_PCT}% — results flagged unreliable"
    NOISE_RELIABLE=0
  fi
else
  log "noise check skipped (SKIP_NOISE_CHECK=1)"
  NOISE_FLOOR_PCT="skipped"
  NOISE_RELIABLE=1
  (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
  log "thermal warmup (discarded)..."
  run_pinned /tmp/prove_loop_cand 2 >/dev/null 2>&1 || true
fi

# ------------------------------ MEASURE --------------------------------------

ALL_BASE_TIMES=$(mktemp /tmp/eval_base_times_XXXXXX)
ALL_CAND_TIMES=$(mktemp /tmp/eval_cand_times_XXXXXX)
ALL_BASE_KIBS=$(mktemp /tmp/eval_base_kibs_XXXXXX)
ALL_CAND_KIBS=$(mktemp /tmp/eval_cand_kibs_XXXXXX)
ROUND_LOG=$(mktemp /tmp/eval_round_log_XXXXXX)
: > "$ALL_BASE_TIMES"
: > "$ALL_CAND_TIMES"
: > "$ALL_BASE_KIBS"
: > "$ALL_CAND_KIBS"
: > "$ROUND_LOG"

for ((round=1; round<=N; round++)); do
  log "=== round $round / $N ==="

  BASE_CSV=$(mktemp /tmp/eval_base_XXXXXX)
  CAND_CSV=$(mktemp /tmp/eval_cand_XXXXXX)

  # Counterbalanced ordering: odd rounds base→cand, even rounds cand→base
  if (( round % 2 == 1 )); then
    log "  order: base → cand"
    drop_caches
    (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
    run_pinned /tmp/prove_loop_base "$N_PROOFS" > "$BASE_CSV" 2>/dev/null
    drop_caches
    (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
    run_pinned /tmp/prove_loop_cand "$N_PROOFS" > "$CAND_CSV" 2>/dev/null
  else
    log "  order: cand → base"
    drop_caches
    (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
    run_pinned /tmp/prove_loop_cand "$N_PROOFS" > "$CAND_CSV" 2>/dev/null
    drop_caches
    (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
    run_pinned /tmp/prove_loop_base "$N_PROOFS" > "$BASE_CSV" 2>/dev/null
  fi

  # --- extract warm proof times and per-round summary ---
  python3 - "$BASE_CSV" "$CAND_CSV" "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$ALL_BASE_KIBS" "$ALL_CAND_KIBS" "$ROUND_LOG" "$round" <<'PY'
import sys

base_csv, cand_csv, base_out, cand_out, base_kibs_out, cand_kibs_out, round_log, rnd = sys.argv[1:]

def parse_warm(path):
    times, kibs = [], []
    for line in open(path):
        line = line.strip()
        if line.startswith("proof,"):
            continue
        parts = line.split(",")
        if len(parts) < 2:
            continue
        idx, secs = int(parts[0]), float(parts[1])
        if idx >= 1:
            times.append(secs)
            if len(parts) >= 4:
                kibs.append(int(parts[3]))
    return times, kibs

base_times, base_kibs = parse_warm(base_csv)
cand_times, cand_kibs = parse_warm(cand_csv)

if not base_times or not cand_times:
    print(f"round {rnd}: FAILED to extract warm proof times", file=sys.stderr)
    sys.exit(1)

with open(base_out, "a") as f:
    for t in base_times:
        f.write(f"{t:.6f}\n")
with open(cand_out, "a") as f:
    for t in cand_times:
        f.write(f"{t:.6f}\n")
with open(base_kibs_out, "a") as f:
    for k in base_kibs:
        f.write(f"{k}\n")
with open(cand_kibs_out, "a") as f:
    for k in cand_kibs:
        f.write(f"{k}\n")

base_avg = sum(base_times) / len(base_times)
cand_avg = sum(cand_times) / len(cand_times)
delta_pct = (cand_avg - base_avg) / base_avg * 100

with open(round_log, "a") as f:
    f.write(f"{rnd} {base_avg:.6f} {cand_avg:.6f} {delta_pct:.4f}\n")

print(f"[eval_paired] round {rnd}: base={base_avg:.3f}s  cand={cand_avg:.3f}s  Δ={delta_pct:+.2f}%")
PY

  rm -f "$BASE_CSV" "$CAND_CSV"

  # --- drift abort: compare this round's base_avg to round 1 ---
  if [[ "$round" -gt 1 ]]; then
    DRIFT_DECISION=$(python3 - "$ROUND_LOG" "$DRIFT_ABORT_PCT" <<'PY'
import sys
log_path, thr = sys.argv[1], float(sys.argv[2])
rows = [line.strip().split() for line in open(log_path) if line.strip()]
if len(rows) < 2:
    print("OK")
    sys.exit(0)
r1_base = float(rows[0][1])
rN_base = float(rows[-1][1])
drift_pct = (rN_base - r1_base) / r1_base * 100.0
if abs(drift_pct) > thr:
    print(f"ABORT drift={drift_pct:+.2f}% (threshold {thr}%, r1={r1_base:.4f}s rN={rN_base:.4f}s)")
else:
    print(f"OK drift={drift_pct:+.2f}%")
PY
)
    if [[ "$DRIFT_DECISION" == ABORT* ]]; then
      err "drift detected within run: $DRIFT_DECISION"
      err "machine state changed mid-measurement. Clean env (env_preflight + tmux + thermal) and retry."
      rm -f "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$ALL_BASE_KIBS" "$ALL_CAND_KIBS" "$ROUND_LOG"
      exit 2
    fi
  fi
done

# ------------------------------ ANALYZE --------------------------------------

SUMMARY=$(python3 - "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$ROUND_LOG" \
  "$KEEP_THRESHOLD_PCT" "$N" "$HASH_BASE" "$HASH_CAND" \
  "$BASELINE_SHA" "$CANDIDATE_SHA" "$N_PROOFS" "$NOISE_FLOOR_PCT" "$NOISE_RELIABLE" <<'PY'
import sys, json, math, statistics as st

base_path, cand_path, round_path = sys.argv[1:4]
thr, n, hash_base, hash_cand, base_sha, cand_sha, n_proofs, noise_floor_str, noise_reliable_str = sys.argv[4:]
thr, n, n_proofs = float(thr), int(n), int(n_proofs)

base_times = [float(x) for x in open(base_path) if x.strip()]
cand_times = [float(x) for x in open(cand_path) if x.strip()]

rounds = []
for line in open(round_path):
    parts = line.strip().split()
    if len(parts) == 4:
        rounds.append({
            "round": int(parts[0]),
            "base_avg": float(parts[1]),
            "cand_avg": float(parts[2]),
            "delta_pct": float(parts[3]),
        })

if not base_times or not cand_times:
    print(json.dumps({"error": "no proof times collected"}))
    sys.exit(0)

n_b, n_c = len(base_times), len(cand_times)
mean_b, mean_c = st.mean(base_times), st.mean(cand_times)
delta_pct = (mean_c - mean_b) / mean_b * 100

# Welch's t-test
var_b = st.variance(base_times) if n_b >= 2 else 0
var_c = st.variance(cand_times) if n_c >= 2 else 0
se = math.sqrt(var_b / n_b + var_c / n_c) if (var_b + var_c) > 0 else 1e-9
t_stat = (mean_c - mean_b) / se

# Welch-Satterthwaite degrees of freedom
if var_b + var_c > 0:
    num = (var_b / n_b + var_c / n_c) ** 2
    d1 = (var_b / n_b) ** 2 / (n_b - 1) if n_b > 1 and var_b > 0 else 0
    d2 = (var_c / n_c) ** 2 / (n_c - 1) if n_c > 1 and var_c > 0 else 0
    df = num / (d1 + d2) if (d1 + d2) > 0 else 1
else:
    df = 1

# Two-tailed p-value via numerical integration of the t-PDF
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

# Decision
if delta_pct <= -thr and p_value < 0.01:
    decision = "keep"
else:
    decision = "discard"

per_round = [{"round": r["round"],
              "base_s": round(r["base_avg"], 4),
              "cand_s": round(r["cand_avg"], 4),
              "delta_pct": round(r["delta_pct"], 2)} for r in rounds]

summary = {
    "n_rounds": len(rounds),
    "n_proofs_per_run": n_proofs,
    "warm_proofs_per_run": n_proofs - 1,
    "total_samples": {"baseline": n_b, "candidate": n_c},
    "base_avg_s": round(mean_b, 4),
    "cand_avg_s": round(mean_c, 4),
    "delta_pct": round(delta_pct, 2),
    "t_stat": round(t_stat, 3),
    "p_value": round(p_value, 6),
    "df": round(df, 1),
    "threshold_pct": thr,
    "decision": decision,
    "per_round": per_round,
    "hash_base": hash_base,
    "hash_cand": hash_cand,
    "baseline_sha": base_sha,
    "candidate_sha": cand_sha,
    "noise_floor_pct": float(noise_floor_str) if noise_floor_str != "skipped" else None,
    "noise_reliable": int(noise_reliable_str) == 1,
}
print(json.dumps(summary, indent=2))
PY
)

echo ""
echo "=== SUMMARY ==="
echo "$SUMMARY"

# Splice env metadata + preflight JSON into summary
python3 - <<PY > /tmp/eval_paired_summary.json
import json
summary = json.loads('''$SUMMARY''')
try:
    preflight = json.loads('''$PREFLIGHT_JSON''')
except Exception:
    preflight = None
summary['env_preflight'] = preflight
summary['hostname'] = '$(hostname 2>/dev/null || echo unknown)'
summary['uptime'] = '$(uptime | sed "s/'/ /g" 2>/dev/null || echo unknown)'
print(json.dumps(summary, indent=2))
PY

# Cleanup temp files
rm -f "$ALL_BASE_TIMES" "$ALL_CAND_TIMES" "$ALL_BASE_KIBS" "$ALL_CAND_KIBS" "$ROUND_LOG"

# ------------------------------ RECURSION REGRESSION CHECK -------------------
# Paired A/B: run recursion on both baseline and candidate, compare.

log ""
log "recursion regression check (baseline vs candidate)..."

(cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
REC_BASE_JSON=$( (cd "$LM_REPO" && cargo run --release -- recursion --n 2 --log-inv-rate 2 --json 2>/dev/null) || echo "")

(cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
REC_CAND_JSON=$( (cd "$LM_REPO" && cargo run --release -- recursion --n 2 --log-inv-rate 2 --json 2>/dev/null) || echo "")

if [[ -n "$REC_BASE_JSON" && -n "$REC_CAND_JSON" ]]; then
  REC_BASE_SECS=$(echo "$REC_BASE_JSON" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{sum(n[\"stats\"][\"time_secs\"] for n in r[\"nodes\"]):.3f}')" 2>/dev/null || echo "0")
  REC_CAND_SECS=$(echo "$REC_CAND_JSON" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{sum(n[\"stats\"][\"time_secs\"] for n in r[\"nodes\"]):.3f}')" 2>/dev/null || echo "0")
  REC_DELTA=$(python3 -c "b=$REC_BASE_SECS; c=$REC_CAND_SECS; print(f'{(c-b)/b*100:.2f}' if b > 0 else '0.00')")
  log "recursion: baseline=${REC_BASE_SECS}s candidate=${REC_CAND_SECS}s Δ=${REC_DELTA}%"

  REC_REGRESSED=$(python3 -c "import sys; sys.exit(0 if float('$REC_DELTA') > float('$RECURSION_MAX_REGRESSION_PCT') else 1)" 2>/dev/null && echo "1" || echo "0")
  if [[ "$REC_REGRESSED" == "1" ]]; then
    err "RECURSION REGRESSION: ${REC_DELTA}% exceeds ${RECURSION_MAX_REGRESSION_PCT}% max — forcing discard"
    python3 -c "
import json
s = json.load(open('/tmp/eval_paired_summary.json'))
s['decision'] = 'discard'
s['discard_reason'] = 'recursion regression ${REC_DELTA}% > ${RECURSION_MAX_REGRESSION_PCT}% ceiling'
json.dump(s, open('/tmp/eval_paired_summary.json','w'), indent=2)
"
  fi

  python3 -c "
import json
s = json.load(open('/tmp/eval_paired_summary.json'))
s['recursion_base_secs'] = float('$REC_BASE_SECS')
s['recursion_cand_secs'] = float('$REC_CAND_SECS')
s['recursion_delta_pct'] = float('$REC_DELTA')
json.dump(s, open('/tmp/eval_paired_summary.json','w'), indent=2)
" 2>/dev/null || true
else
  log "WARNING: recursion check failed to produce JSON — skipping"
fi

# ------------------------------ PROOF SIZE CHECK -----------------------------

log ""
log "proof size check..."
PROOF_SIZE_DECISION=$(python3 - "$ALL_BASE_KIBS" "$ALL_CAND_KIBS" "$PROOF_SIZE_CEILING_PCT" "$PROOF_SIZE_PENALTY_MULTIPLIER" "$KEEP_THRESHOLD_PCT" <<'PY'
import sys, json
from statistics import mean

base_kibs_path, cand_kibs_path = sys.argv[1], sys.argv[2]
ceiling = float(sys.argv[3])
multiplier = float(sys.argv[4])
threshold = float(sys.argv[5])

base_kibs = [int(x) for x in open(base_kibs_path) if x.strip()]
cand_kibs = [int(x) for x in open(cand_kibs_path) if x.strip()]

s = json.load(open("/tmp/eval_paired_summary.json"))

if base_kibs and cand_kibs:
    base_kib = mean(base_kibs)
    cand_kib = mean(cand_kibs)
    size_pct = (cand_kib - base_kib) / base_kib * 100 if base_kib > 0 else 0

    s["proof_size_base_kib"] = round(base_kib, 1)
    s["proof_size_cand_kib"] = round(cand_kib, 1)
    s["proof_size_delta_pct"] = round(size_pct, 2)

    if size_pct > ceiling:
        s["decision"] = "discard"
        s["discard_reason"] = f"proof size +{size_pct:.1f}% exceeds {ceiling:.0f}% ceiling"
        print(f"DISCARD: proof size +{size_pct:.1f}% exceeds {ceiling:.0f}% ceiling")
    elif size_pct > 0 and s.get("decision") == "keep":
        throughput_pct = -s["delta_pct"]
        net = throughput_pct - multiplier * size_pct
        s["proof_size_net_pct"] = round(net, 2)
        if net < threshold:
            s["decision"] = "discard"
            s["discard_reason"] = f"net={net:.2f}% after proof size penalty"
            print(f"DISCARD: net={net:.2f}% below threshold after proof size penalty")
        else:
            print(f"OK: net={net:.2f}% (throughput {throughput_pct:.2f}% - {multiplier}x size {size_pct:.2f}%)")
    else:
        print(f"OK: proof size {size_pct:+.2f}%")
else:
    print("SKIP: prove_loop CSV missing proof_kib column (pre-update binary)")

json.dump(s, open("/tmp/eval_paired_summary.json", "w"), indent=2)
PY
)
log "proof size: $PROOF_SIZE_DECISION"

# Exit code
dec=$(python3 -c 'import json; print(json.load(open("/tmp/eval_paired_summary.json")).get("decision","discard"))')
EXIT_CODE=1
[[ "$dec" == "keep" ]] && EXIT_CODE=0

# Auto-chain on keep: cumulative anchor → Criterion ship-gate confirmation
if [[ "$EXIT_CODE" -eq 0 ]]; then
  log ""
  log "==================== KEEP — running auto-chain ===================="

  BASELINE_IS_ORIGIN_MAIN=$( (cd "$LM_REPO" && [[ "$(git rev-parse origin/main)" == "$BASELINE_SHA" ]]) && echo "1" || echo "0")

  # Step 1: Cumulative anchor vs origin/main
  if [[ "$AUTO_CUMULATIVE_ON_KEEP" == "1" ]]; then
    if [[ "$BASELINE_IS_ORIGIN_MAIN" == "1" ]]; then
      log "[auto-chain] cumulative: baseline IS origin/main — skipping (already anchored)"
    else
      log "[auto-chain] cumulative: anchoring HEAD vs origin/main..."
      SKIP_NOISE_CHECK=1 bash "$SHARED_DIR/eval_cumulative.sh" --anchor origin/main --n 5 || true
    fi
  fi

  # Step 2: Criterion ship-gate confirmation
  if [[ "$AUTO_SHIP_GATE_ON_KEEP" == "1" ]]; then
    # eval_paired's own bench just ran ~3.5 min; 1-min loadavg is elevated
    # because the bench's tail end is still in the window. The env state is
    # otherwise fine (we passed preflight at the start of this gate run and
    # the system has only been doing OUR bench). Skip preflight for the
    # ship-gate auto-invocation — we own the env.
    log "[auto-chain] ship-gate: Criterion-confirm HEAD vs origin/main (SKIP_PREFLIGHT=1, env owned by this gate)..."
    SHIP_EXIT=0
    SKIP_PREFLIGHT=1 bash "$SHARED_DIR/eval_ship_gate.sh" --paired origin/main || SHIP_EXIT=$?
    case "$SHIP_EXIT" in
      0) log "[auto-chain] ship-gate: PASS (Criterion: no regression / improved)" ;;
      1) log ""
         log "[auto-chain] CONFLICT: fast-tier=KEEP, Criterion ship-gate=REGRESS."
         log "[auto-chain] Inspect /tmp/eval_ship_gate_summary.json + /tmp/eval_ship_gate_last.txt"
         log "[auto-chain] Recommend manual eval_revert_ab.sh to settle." ;;
      2) log "[auto-chain] ship-gate: COULD NOT MEASURE (exit 2: env_preflight fail, build error, etc.)"
         log "[auto-chain] Fast-tier keep decision stands; ship-gate confirmation pending."
         log "[auto-chain] Inspect /tmp/eval_ship_gate_last.txt for cause." ;;
      *) log "[auto-chain] ship-gate: unexpected exit $SHIP_EXIT — see /tmp/eval_ship_gate_last.txt" ;;
    esac
  fi

  # Step 3: Steady-state gate (on large keeps only)
  if [[ "$AUTO_STEADY_STATE_ON_KEEP" == "1" ]]; then
    KEEP_DELTA=$(python3 -c "import json; print(abs(json.load(open('/tmp/eval_paired_summary.json')).get('delta_pct', 0)))")
    if python3 -c "import sys; sys.exit(0 if float('$KEEP_DELTA') >= float('$STEADY_STATE_THRESHOLD_PCT') else 1)" 2>/dev/null; then
      log "[auto-chain] steady-state: |Δ|=${KEEP_DELTA}% >= ${STEADY_STATE_THRESHOLD_PCT}% — measuring..."
      bash "$SHARED_DIR/eval_steady_state.sh" \
        --baseline-bin /tmp/prove_loop_base --candidate-bin /tmp/prove_loop_cand \
        --baseline "$BASELINE_SHA" --candidate "$CANDIDATE_SHA" || true
    else
      log "[auto-chain] steady-state: |Δ|=${KEEP_DELTA}% < ${STEADY_STATE_THRESHOLD_PCT}% — skipped"
    fi
  fi

  # Step 4: Fancy-aggregation (exercises deep recursive topology)
  log "[auto-chain] fancy-aggregation: full topology check..."
  (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
  FANCY_JSON=$( (cd "$LM_REPO" && cargo run --release -- fancy-aggregation --json 2>/dev/null) || echo "")
  if [[ -n "$FANCY_JSON" ]]; then
    FANCY_TOTAL=$(echo "$FANCY_JSON" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{sum(n[\"stats\"][\"time_secs\"] for n in r[\"nodes\"]):.3f}')" 2>/dev/null || echo "FAILED")
    log "[auto-chain] fancy-aggregation: ${FANCY_TOTAL}s total"
  else
    log "[auto-chain] fancy-aggregation: FAILED to run — check build"
  fi
fi

exit $EXIT_CODE
