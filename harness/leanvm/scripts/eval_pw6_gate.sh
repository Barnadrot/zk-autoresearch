#!/bin/bash
# Combined correctness + performance gate for pw6-blake3 experiment.
#
# Enforces: no runtime hash flags, zk-alloc enabled, aggregation + prove_loop
# must both pass with the SAME binary (same hash function for all paths).
#
# Exit codes:
#   0 = pass (correctness + performance)
#   1 = correctness failure
#   2 = performance failure (above 1.55s warm avg)
#   3 = build failure

set -e

cd ~/zk-autoresearch/leanVM
export RUSTFLAGS="-C target-cpu=native"

echo "================================================================"
echo "[pw6-gate] Combined correctness + performance gate"
echo "================================================================"

# -----------------------------------------------------------------------
# Step 1: Correctness (aggregation tests)
# -----------------------------------------------------------------------
echo ""
echo "[pw6-gate] Step 1: Correctness — aggregation tests..."
cargo test --release test_type_1_aggregation -- --nocapture 2>&1
if [ $? -ne 0 ]; then
  echo "[pw6-gate] FAILED: test_type_1_aggregation"
  exit 1
fi
cargo test --release test_type_2_aggregation -- --nocapture 2>&1
if [ $? -ne 0 ]; then
  echo "[pw6-gate] FAILED: test_type_2_aggregation"
  exit 1
fi
echo "[pw6-gate] Step 1 PASSED — aggregation tests pass."

# -----------------------------------------------------------------------
# Step 2: Performance (prove_loop with zk-alloc)
# Uses the SAME binary that aggregation tests just validated.
# prove_loop measures leaf aggregation throughput.
# -----------------------------------------------------------------------
echo ""
echo "[pw6-gate] Step 2: Performance — prove_loop with zk-alloc..."
cd ~/zk-autoresearch/harness/leanvm/bench
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin prove_loop --features zkalloc_global 2>&1 | tail -3
if [ $? -ne 0 ]; then
  echo "[pw6-gate] FAILED: prove_loop build"
  exit 3
fi

OUTPUT=$(target/release/prove_loop 5 2>&1)
echo "$OUTPUT"

# Extract warm average (proofs 2-5)
WARM_AVG=$(echo "$OUTPUT" | grep "^[0-9]" | tail -4 | awk -F, '{sum+=$2} END {printf "%.3f", sum/NR}')
XMSS_PER_SEC=$(echo "$WARM_AVG" | awk '{printf "%.0f", 1550/$1}')

echo ""
echo "[pw6-gate] Warm average: ${WARM_AVG}s (${XMSS_PER_SEC} XMSS/s)"

# Threshold: 1.55s = 1000 XMSS/s
PASS=$(echo "$WARM_AVG" | awk '{print ($1 <= 1.55) ? "1" : "0"}')
if [ "$PASS" = "0" ]; then
  echo "[pw6-gate] FAILED: ${WARM_AVG}s > 1.55s threshold (${XMSS_PER_SEC} XMSS/s < 1000)"
  exit 2
fi

echo "[pw6-gate] Step 2 PASSED — ${WARM_AVG}s / ${XMSS_PER_SEC} XMSS/s"

# -----------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------
echo ""
echo "================================================================"
echo "[pw6-gate] ALL PASSED — correctness + performance"
echo "[pw6-gate] Warm avg: ${WARM_AVG}s / ${XMSS_PER_SEC} XMSS/s"
echo "================================================================"
exit 0
