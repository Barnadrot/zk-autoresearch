#!/bin/bash
# End-to-end Criterion benchmark — sanity check for all leanMultisig experiments.
# Measures full xmss_aggregate (100 sigs). Sumcheck = ~52% of signal,
# combine_statement = ~22%, Poseidon/hashing = ~4%. Primary signal for experiment_sumcheck.
#
# Usage:
#   bash eval_e2e.sh                   — compare vs saved baseline
#   bash eval_e2e.sh --save-baseline   — save current as baseline (once per session)
#
# Exit code: 0 always.

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/leanMultisig-bench

BENCH_FLAGS="--bench xmss_leaf"
BENCH_FILTER="xmss_leaf_1400sigs"
BASELINE_NAME="lm_e2e_baseline"
MEASURE="--measurement-time 60 --sample-size 10 --noplot"

if [[ "$1" == "--save-baseline" ]]; then
  echo "[eval_e2e] Saving baseline '$BASELINE_NAME'..."
  cargo bench $BENCH_FLAGS -- "$BENCH_FILTER" \
    --save-baseline $BASELINE_NAME $MEASURE
  echo "[eval_e2e] Baseline saved."
  exit 0
fi

echo "[eval_e2e] Running e2e bench vs baseline '$BASELINE_NAME'..."
cargo bench $BENCH_FLAGS -- "$BENCH_FILTER" \
  --baseline $BASELINE_NAME $MEASURE \
  2>&1 | tee /tmp/eval_e2e_last.txt

echo ""
echo "=== SUMMARY ==="
CHANGE=$(grep -oP 'change:.*' /tmp/eval_e2e_last.txt | head -1 || echo "N/A")
PVAL=$(grep -oP 'p\s*=\s*\K[\d.]+' /tmp/eval_e2e_last.txt | head -1 || echo "N/A")
VERDICT=$(grep -E 'Performance has (regressed|improved)|No change|within noise' /tmp/eval_e2e_last.txt | head -1 || echo "(no verdict)")
echo "Change : $CHANGE"
echo "p-value: $PVAL"
echo "Verdict: $VERDICT"
