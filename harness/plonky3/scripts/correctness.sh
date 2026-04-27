#!/bin/bash
# Correctness check — runs full test suite (~60s).
# Run after every change before benchmarking.
# Exit code: 0 = pass, 1 = fail.

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/Plonky3

echo "[correctness] Running test suite (~60s)..."
cargo test -p p3-dft -p p3-baby-bear -p p3-monty-31 --release 2>&1

echo ""
if [ $? -eq 0 ]; then
  echo "[correctness] PASSED — safe to benchmark."
else
  echo "[correctness] FAILED — revert before benchmarking."
  exit 1
fi
