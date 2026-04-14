#!/bin/bash
# Correctness check — runs mt-whir test suite including test_eval_dft oracle.
# test_eval_dft validates DFT output against direct multilinear polynomial evaluation
# at n_vars=1..=20. Mathematically stronger than the Plonky3 checker.
# Run after every change before benchmarking.
# Exit code: 0 = pass, 1 = fail.

set -e
cd ~/leanMultisig

echo "[correctness] Running mt-whir test suite (~30s)..."
cargo test -p mt-whir --release 2>&1

echo ""
if [ $? -eq 0 ]; then
  echo "[correctness] PASSED — safe to benchmark."
else
  echo "[correctness] FAILED — revert before benchmarking."
  exit 1
fi
