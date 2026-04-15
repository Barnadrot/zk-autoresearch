#!/bin/bash
# Paired back-to-back wall-clock gate for leanMultisig autoresearch.
#
# Builds a baseline and candidate bench binary, runs one discarded burn-in
# invocation, then alternates save-baseline / compare within a single shell
# session. Output is a JSON summary: N paired Δ%, median, mean, σ, decision.
#
# Usage:
#   eval_paired.sh                                   # HEAD~1 (baseline) vs HEAD (candidate), N=1
#   eval_paired.sh --baseline <ref> --candidate <ref> [--n <int>]
#   eval_paired.sh --n 10                            # calibration / backtest mode
#
# Exit codes:
#   0 = candidate kept (improvement crosses threshold + p<0.01 on single-pass)
#   1 = discarded (no improvement or under threshold)
#   2 = infrastructure error (build failure, identical binaries, git state)
#
# Decision rule (single-pass):
#   keep if median_Δ <= -KEEP_THRESHOLD_PCT AND paired_p < 0.01
# For calibration / backtest mode (N>=3), only stats are reported — no decision.

set -eo pipefail

# ------------------------------- CONFIG --------------------------------------

KEEP_THRESHOLD_PCT=${KEEP_THRESHOLD_PCT:-1.0}    # provisional; set from backtest
SAMPLE_SIZE=${SAMPLE_SIZE:-10}
MEASUREMENT_TIME=${MEASUREMENT_TIME:-60}
BURN_IN_PROFILE_TIME=${BURN_IN_PROFILE_TIME:-30}
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/leanMultisig-bench}
BENCH_NAME=${BENCH_NAME:-xmss_leaf}
BENCH_FILTER=${BENCH_FILTER:-xmss_leaf_1400sigs}
BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"
N=1

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

err() { echo "[eval_paired][err] $*" >&2; }
log() { echo "[eval_paired] $*"; }

build_binary() {
  # $1 = git ref, $2 = output path
  local ref="$1" out="$2"
  (
    cd "$LM_REPO"
    git checkout --quiet "$ref" || { err "git checkout $ref failed"; exit 2; }
  )
  (
    cd "$BENCH_CRATE"
    # Force a clean rebuild of the bench crate's artifacts. Path-dep rlibs are
    # rebuilt by cargo when git checkout updates their source mtimes. Clearing
    # the bench's own cached outputs guarantees `ls -t` below picks the fresh
    # binary rather than a stale one from a prior checkout.
    # Full release clean — path-dep rlibs can become inconsistent after git
    # checkout if cargo's fingerprint cache misses a cross-crate mismatch
    # (seen in practice: bench would panic on hint_witness parsing because
    # rec_aggregation was stale while lean_compiler was fresh). The cost is
    # ~5-7 minutes per rebuild; the correctness is worth it.
    cargo clean --release >/dev/null 2>&1 || true
    cargo build --release --bench "$BENCH_NAME" 2>&1 | tail -5 >&2 || { err "cargo build failed at $ref"; exit 2; }
    local bin
    bin=$(ls -t "$BENCH_CRATE"/target/release/deps/${BENCH_NAME}-* 2>/dev/null | grep -v '\.d$' | head -1)
    if [[ -z "$bin" ]]; then err "no bench binary after build at $ref"; exit 2; fi
    cp "$bin" "$out"
  )
}

# Extract the "change: [low med high] (p = P ...)" block from criterion output.
extract_change() {
  # $1 = log file; prints "median_pct p_value" or "NA NA"
  local med p
  # Median change comes from "change: [low MED high]"
  med=$(grep -oP 'change:\s*\[\s*[-+]?[0-9.]+%\s+\K[-+]?[0-9.]+' "$1" | head -1)
  p=$(grep -oP 'change:\s*\[[^\]]+\]\s*\(p\s*=\s*\K[0-9.]+' "$1" | head -1)
  echo "${med:-NA} ${p:-NA}"
}

# ------------------------------ SETUP ----------------------------------------

# Resolve refs to SHAs (pinning in case HEAD moves during the run)
ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD)
BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")

log "baseline  : $BASELINE_REF ($BASELINE_SHA)"
log "candidate : $CANDIDATE_REF ($CANDIDATE_SHA)"
log "N paired  : $N"

if [[ "$BASELINE_SHA" == "$CANDIDATE_SHA" ]]; then
  err "baseline == candidate SHA — nothing to compare"
  exit 2
fi

# Restore git state on any exit
trap 'cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

# ------------------------------ BUILD ----------------------------------------

log "building baseline binary..."
build_binary "$BASELINE_SHA" /tmp/bench_base

log "building candidate binary..."
build_binary "$CANDIDATE_SHA" /tmp/bench_cand

# NOTE: DO NOT restore ORIG_HEAD before running benches. The bench binary
# loads `rec_aggregation/main.py` at runtime from the git-tracked path,
# so the working tree must match the binary being executed. We re-checkout
# inside the per-round loop below.

# Binary hash guard — if both binaries are byte-identical the build cache
# almost certainly didn't pick up the candidate change, or the change is a no-op.
HASH_BASE=$(md5sum /tmp/bench_base | awk '{print $1}')
HASH_CAND=$(md5sum /tmp/bench_cand | awk '{print $1}')
log "hash_base : $HASH_BASE"
log "hash_cand : $HASH_CAND"
if [[ "$HASH_BASE" == "$HASH_CAND" ]]; then
  err "baseline and candidate binaries have identical hashes — build cache hazard or no-op change"
  # Continue only if explicitly asked (idle-noise calibration), otherwise abort
  if [[ "${ALLOW_IDENTICAL_BIN:-0}" != "1" ]]; then exit 2; fi
fi

# ------------------------------ BURN-IN --------------------------------------

# Burn-in runs the CANDIDATE to warm thermals. Needs candidate's working tree.
(cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
log "burn-in invocation (discarded)..."
( cd "$BENCH_CRATE" && \
  /tmp/bench_cand --bench "$BENCH_FILTER" --profile-time "$BURN_IN_PROFILE_TIME" \
    --sample-size "$SAMPLE_SIZE" --noplot >/dev/null 2>&1 ) || true

# ------------------------------ MEASURE --------------------------------------

RUN_LOG=$(mktemp /tmp/eval_paired_run.XXXXXX.txt)
DELTA_FILE=$(mktemp /tmp/eval_paired_deltas.XXXXXX.txt)
: > "$DELTA_FILE"

for ((round=1; round<=N; round++)); do
  baseline_tag="eval_paired_${round}"
  echo "=== paired round $round / $N ===" >> "$RUN_LOG"

  # IMPORTANT: bench binaries load runtime files (main.py etc.) from the
  # git-tracked path. Sync the working tree to the SHA of the binary being
  # run, or it will try to parse the wrong-era source and panic.
  (cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
  ( cd "$BENCH_CRATE" && \
    /tmp/bench_base --bench "$BENCH_FILTER" \
      --save-baseline "$baseline_tag" \
      --sample-size "$SAMPLE_SIZE" --measurement-time "$MEASUREMENT_TIME" --noplot \
      >> "$RUN_LOG" 2>&1 )

  (cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
  CMP_LOG=$(mktemp /tmp/eval_paired_cmp.XXXXXX.txt)
  ( cd "$BENCH_CRATE" && \
    /tmp/bench_cand --bench "$BENCH_FILTER" \
      --baseline "$baseline_tag" \
      --sample-size "$SAMPLE_SIZE" --measurement-time "$MEASUREMENT_TIME" --noplot \
      > "$CMP_LOG" 2>&1 )
  cat "$CMP_LOG" >> "$RUN_LOG"

  read -r med p <<< "$(extract_change "$CMP_LOG")"
  echo "$round $med $p" >> "$DELTA_FILE"
  log "round $round: Δ=${med}%  p=${p}"
  rm -f "$CMP_LOG"
done

# ------------------------------ ANALYZE --------------------------------------

SUMMARY=$(python3 - "$DELTA_FILE" "$KEEP_THRESHOLD_PCT" "$N" "$HASH_BASE" "$HASH_CAND" "$BASELINE_SHA" "$CANDIDATE_SHA" <<'PY'
import sys, statistics as s, json
path, thr, n, hash_base, hash_cand, base_sha, cand_sha = sys.argv[1:]
thr, n = float(thr), int(n)
rounds = []
for line in open(path):
    parts = line.strip().split()
    if len(parts) != 3: continue
    try:
        rounds.append((int(parts[0]), float(parts[1]), float(parts[2])))
    except ValueError:
        continue
if not rounds:
    print(json.dumps({"error": "no paired rounds parsed"}))
    sys.exit(0)
deltas = [r[1] for r in rounds]
pvals  = [r[2] for r in rounds]
med    = s.median(deltas)
mean   = s.mean(deltas)
sigma  = s.stdev(deltas) if len(deltas) >= 2 else 0.0
# Single-pass decision only meaningful for N==1
decision = None
if n == 1:
    d = deltas[0]
    p = pvals[0]
    decision = "keep" if (d <= -thr and p < 0.01) else "discard"
summary = {
    "n": len(rounds),
    "deltas_pct": deltas,
    "p_values":  pvals,
    "median_pct": med,
    "mean_pct":   mean,
    "sigma_pct":  sigma,
    "threshold_pct": thr,
    "decision":   decision,
    "hash_base":  hash_base,
    "hash_cand":  hash_cand,
    "baseline_sha":  base_sha,
    "candidate_sha": cand_sha,
}
print(json.dumps(summary, indent=2))
PY
)

echo ""
echo "=== SUMMARY ==="
echo "$SUMMARY"
echo "$SUMMARY" > /tmp/eval_paired_summary.json

# Exit code
if [[ "$N" == "1" ]]; then
  dec=$(echo "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')
  [[ "$dec" == "keep" ]] && exit 0 || exit 1
fi
exit 0
