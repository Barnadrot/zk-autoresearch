#!/bin/bash
# Shared correctness check for all leanMultisig experiments.
# Validates KoalaBear field arithmetic + full WHIR proof path.
# Run after every change before benchmarking.
# Exit code: 0 = pass, 1 = fail.

set -e
cd ~/zk-autoresearch/leanMultisig

export RUSTFLAGS="-C target-cpu=native"

echo "[correctness] Layer 1: KoalaBear field arithmetic unit tests (~10s)..."
cargo test -p mt-koala-bear --release 2>&1

echo ""
echo "[correctness] Layer 2: Full WHIR proof integration test (~30s)..."
cargo test -p mt-whir --release 2>&1

echo ""
echo "[correctness] PASSED — safe to benchmark."
