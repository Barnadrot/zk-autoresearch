#!/bin/bash
# iai-style callgrind gate for leanMultisig autoresearch.
#
# Builds the iai_driver binary at baseline and candidate refs, runs each under
# `valgrind --tool=callgrind --toggle-collect=iai_hot_kernel`, parses per-symbol
# instruction counts (Ir), filters to sumcheck + adjacent hot-path namespaces,
# and reports per-symbol deltas vs baseline.
#
# Decision:
#   PASS  - any tracked symbol shows >= IAI_MIN_DROP_PCT reduction AND
#           no tracked symbol regresses by more than IAI_MAX_REGR_PCT
#   FAIL  - otherwise
#
# Usage:
#   eval_iai.sh                                        # HEAD~1 vs HEAD
#   eval_iai.sh --baseline <ref> --candidate <ref>
#
# Exit: 0 = PASS, 1 = FAIL, 2 = infrastructure error.

set -eo pipefail

IAI_MIN_DROP_PCT=${IAI_MIN_DROP_PCT:-0.10}
IAI_MAX_REGR_PCT=${IAI_MAX_REGR_PCT:-0.05}
LM_REPO=${LM_REPO:-$HOME/zk-autoresearch/leanMultisig}
BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/leanMultisig-bench}
DRIVER_BIN=iai_driver
TOGGLE_SYMBOL=iai_hot_kernel
# Symbols we care about: sumcheck crate + shared multilinear kernel + product_computation
TRACK_REGEX='mt_sumcheck|product_computation|sc_computation|quotient_computation|eq_mle|handle_gkr|fold_and_compute_product_sumcheck'

BASELINE_REF="HEAD~1"
CANDIDATE_REF="HEAD"

# NOTE: target-cpu=znver3 (not native/znver4). Valgrind 3.18-3.23 cannot emulate
# Zen 4-specific AVX-512 subsets (VNNI/VBMI2) used by mt_koala_bear packed
# kernels when built with target-cpu=native; running crashes with SIGILL.
# znver3 disables those subsets while keeping AVX-512F/DQ/BW/CD, which gives
# us accurate Ir counts for orchestration-level sumcheck changes at the cost
# of fidelity for VNNI/VBMI2-specific optimizations. Those should use the
# [wallclock-only] escape hatch in program.md.
export RUSTFLAGS="-C target-cpu=znver3"

err() { echo "[eval_iai][err] $*" >&2; }
log() { echo "[eval_iai] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)  BASELINE_REF="$2"; shift 2 ;;
    --candidate) CANDIDATE_REF="$2"; shift 2 ;;
    *)           err "unknown arg: $1"; exit 2 ;;
  esac
done

ORIG_HEAD=$(cd "$LM_REPO" && git rev-parse HEAD)
ORIG_BRANCH=$(cd "$LM_REPO" && git rev-parse --abbrev-ref HEAD)
BASELINE_SHA=$(cd "$LM_REPO" && git rev-parse "$BASELINE_REF")
CANDIDATE_SHA=$(cd "$LM_REPO" && git rev-parse "$CANDIDATE_REF")

if [[ "$BASELINE_SHA" == "$CANDIDATE_SHA" ]]; then
  err "baseline == candidate — nothing to compare"
  exit 2
fi

trap 'cd "$LM_REPO" && git checkout --quiet "$ORIG_BRANCH" 2>/dev/null || git checkout --quiet "$ORIG_HEAD" 2>/dev/null || true' EXIT

build_driver() {
  local ref="$1" out="$2"
  (cd "$LM_REPO" && git checkout --quiet "$ref") || { err "git checkout $ref failed"; exit 2; }
  (cd "$BENCH_CRATE" && cargo build --release --bin "$DRIVER_BIN" --quiet 2>&1 | tail -3 >&2) || { err "driver build failed at $ref"; exit 2; }
  cp "$BENCH_CRATE/target/release/$DRIVER_BIN" "$out" || { err "copy failed"; exit 2; }
}

log "baseline  : $BASELINE_REF ($BASELINE_SHA)"
log "candidate : $CANDIDATE_REF ($CANDIDATE_SHA)"

log "building baseline driver..."
build_driver "$BASELINE_SHA" /tmp/iai_driver_base
log "building candidate driver..."
build_driver "$CANDIDATE_SHA" /tmp/iai_driver_cand

# NOTE: do NOT checkout ORIG_HEAD here. The driver binary reads main.py at
# runtime from the git-tracked path; the working tree must match the binary
# being run. Each callgrind invocation below re-syncs the working tree.

if [[ "$(md5sum /tmp/iai_driver_base | awk '{print $1}')" == "$(md5sum /tmp/iai_driver_cand | awk '{print $1}')" ]]; then
  err "baseline and candidate driver binaries are identical — build cache hazard or no-op"
  if [[ "${ALLOW_IDENTICAL_BIN:-0}" != "1" ]]; then exit 2; fi
fi

run_callgrind() {
  local bin="$1" outfile="$2"
  # --cache-sim=no keeps runtime shorter; we only need Ir (instruction count).
  # --toggle-collect starts/stops collection at entry/exit of the named fn.
  # --collect-atstart=no → collection is off until toggle fires.
  valgrind --tool=callgrind \
           --callgrind-out-file="$outfile" \
           --toggle-collect="*$TOGGLE_SYMBOL*" \
           --collect-atstart=no \
           --cache-sim=no \
           --instr-atstart=yes \
           "$bin" >/dev/null 2>&1
}

log "running callgrind on baseline..."
(cd "$LM_REPO" && git checkout --quiet "$BASELINE_SHA")
T0=$(date +%s)
run_callgrind /tmp/iai_driver_base /tmp/callgrind.base.out
T1=$(date +%s)
log "baseline callgrind: $((T1-T0)) s"

log "running callgrind on candidate..."
(cd "$LM_REPO" && git checkout --quiet "$CANDIDATE_SHA")
T0=$(date +%s)
run_callgrind /tmp/iai_driver_cand /tmp/callgrind.cand.out
T1=$(date +%s)
log "candidate callgrind: $((T1-T0)) s"

# Extract per-symbol Ir counts (inclusive off by default → self time per fn)
extract_symbols() {
  local outfile="$1" sink="$2"
  callgrind_annotate --threshold=99.9 --show=Ir --sort=Ir --show-percs=no "$outfile" \
    2>/dev/null \
    | awk '/^[[:space:]]*[0-9][0-9,]*[[:space:]]+/ {
        count=$1; gsub(",", "", count);
        $1=""; sub(/^[ \t]+/, "");
        print count "\t" $0
      }' > "$sink"
}

extract_symbols /tmp/callgrind.base.out /tmp/iai.base.symbols.tsv
extract_symbols /tmp/callgrind.cand.out /tmp/iai.cand.symbols.tsv

# Compare tracked symbols
python3 - /tmp/iai.base.symbols.tsv /tmp/iai.cand.symbols.tsv "$TRACK_REGEX" "$IAI_MIN_DROP_PCT" "$IAI_MAX_REGR_PCT" <<'PY' > /tmp/eval_iai_summary.json
import sys, re, json

base_path, cand_path, regex, min_drop, max_regr = sys.argv[1:]
min_drop = float(min_drop); max_regr = float(max_regr)
pat = re.compile(regex)

# Normalize symbol names so that differences between the two binaries
# (binary path suffix, llvm hash suffix, generic hash suffix) don't prevent
# matching otherwise-identical Rust symbols across builds.
_bin_suffix = re.compile(r"\s*\[[^\]]+\]\s*$")
_llvm_suffix = re.compile(r"\.llvm\.[0-9]+")
_hash_suffix = re.compile(r"::h[0-9a-f]{16}(?=\b|::|$)")
_quote_suffix = re.compile(r"'\d+$")
_src_prefix  = re.compile(r"^[^:]*:")   # drop "???:" / "<path>:"
def canon(sym):
    s = _bin_suffix.sub("", sym)
    s = _quote_suffix.sub("", s)
    s = _llvm_suffix.sub("", s)
    s = _hash_suffix.sub("", s)
    s = _src_prefix.sub("", s, count=1)
    return s.strip()

def load(path):
    m = {}
    for line in open(path):
        parts = line.rstrip("\n").split("\t", 1)
        if len(parts) != 2: continue
        try: ir = int(parts[0])
        except ValueError: continue
        # Aggregate if multiple raw symbols normalize to the same canon form
        k = canon(parts[1])
        m[k] = m.get(k, 0) + ir
    return m

b = load(base_path); c = load(cand_path)

tracked = []
for sym in set(b) | set(c):
    if not pat.search(sym): continue
    ir_b = b.get(sym, 0); ir_c = c.get(sym, 0)
    if ir_b == 0 and ir_c == 0: continue
    # Use the signed denominator to keep sign semantics sane when ir_b is zero
    if ir_b == 0:
        delta_pct = float("inf") if ir_c > 0 else 0.0
    else:
        delta_pct = (ir_c - ir_b) / ir_b * 100.0
    tracked.append({"symbol": sym, "ir_base": ir_b, "ir_cand": ir_c, "delta_pct": delta_pct})

tracked.sort(key=lambda r: r["delta_pct"])

total_base_tracked = sum(r["ir_base"] for r in tracked)
total_cand_tracked = sum(r["ir_cand"] for r in tracked)
total_delta_pct = (total_cand_tracked - total_base_tracked) / max(total_base_tracked, 1) * 100.0

any_drop = any(r["delta_pct"] <= -min_drop for r in tracked)
bad_regr = [r for r in tracked if r["delta_pct"] >= max_regr]
decision = "PASS" if (any_drop and not bad_regr) else "FAIL"

# Also report total hot-path drop as a secondary signal
print(json.dumps({
    "decision": decision,
    "min_drop_pct_threshold": min_drop,
    "max_regr_pct_threshold": max_regr,
    "tracked_symbol_count": len(tracked),
    "total_tracked_ir_base": total_base_tracked,
    "total_tracked_ir_cand": total_cand_tracked,
    "total_tracked_delta_pct": total_delta_pct,
    "top_10_movers": tracked[:10],
    "bottom_5": tracked[-5:],
}, indent=2))
PY

cat /tmp/eval_iai_summary.json
DEC=$(python3 -c 'import json; print(json.load(open("/tmp/eval_iai_summary.json"))["decision"])')
[[ "$DEC" == "PASS" ]] && exit 0 || exit 1
