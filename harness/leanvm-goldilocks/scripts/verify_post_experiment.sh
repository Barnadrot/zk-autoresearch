#!/bin/bash
# Post-experiment manual verification script for Goldilocks.
# Run this BEFORE surfacing results for upstream review.
# Not run by the agent — human-triggered only.
#
# Checks:
#   1. Goldilocks field arithmetic unit tests
#   2. Full WHIR proof integration test
#   3. Full multisignature tests (aggregation + XMSS)
#
# Usage:
#   bash verify_post_experiment.sh                    — run all checks

set -e
export RUSTFLAGS="-C target-cpu=native"
cd ~/zk-autoresearch/leanVM

echo "================================================================"
echo " leanVM Goldilocks Post-Experiment Verification"
echo "================================================================"
echo ""

# ── Layer 1: Field arithmetic ─────────────────────────────────────────
echo "[1/3] Goldilocks field arithmetic unit tests..."
cargo test -p goldilocks --release --quiet 2>&1
echo "      PASSED"
echo ""

# ── Layer 2: WHIR integration ─────────────────────────────────────────
echo "[2/3] Full WHIR proof integration test..."
cargo test -p whir --release --quiet 2>&1
echo "      PASSED"
echo ""

# ── Layer 3: Full multisignature tests ────────────────────────────────
echo "[3/3] Full multisignature tests (aggregation + XMSS)..."
cargo test --release --test test_multisignatures --quiet 2>&1
echo "      PASSED"
echo ""

echo "================================================================"
echo " All checks passed. Safe to request review."
echo "================================================================"
