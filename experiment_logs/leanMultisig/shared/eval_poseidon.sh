#!/bin/bash
# Poseidon microbench — primary eval signal for Poseidon experiment.
# Source: Emile (2026-04-14). Runs benchmark_poseidons::bench_poseidon
# in mt-koala-bear. Fast (~10s), low noise, direct Poseidon signal.
#
# Usage:
#   bash eval_poseidon.sh              — run and print results
#
# Exit code: 0 always (agent reads output, not exit code).

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/leanMultisig

echo "[eval_poseidon] Running Poseidon microbench..."
cargo test --release --package mt-koala-bear --lib \
  -- benchmark_poseidons::bench_poseidon --exact --nocapture --ignored \
  2>&1 | tee /tmp/eval_poseidon_last.txt

echo ""
echo "=== SUMMARY ==="
echo "Run 'cargo test ... --ignored' output above contains throughput numbers."
echo "Compare manually against baseline. Keep if improvement > 0.20%."
