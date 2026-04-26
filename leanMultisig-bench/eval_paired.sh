#!/usr/bin/env bash
# eval_paired.sh — paired A/B benchmark: glibc vs zk-alloc
#
# Usage: N=3 bash eval_paired.sh
#   N = number of Criterion measurement samples (default 3)
#
# Runs from the leanMultisig directory:
#   cd ~/zk-autoresearch/leanMultisig && N=3 bash ../leanMultisig-bench/eval_paired.sh

set -euo pipefail

N="${N:-3}"
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LEAN_DIR="$(cd "$BENCH_DIR/../leanMultisig" && pwd)"

cd "$LEAN_DIR"

echo "=== eval_paired.sh: N=$N samples ==="
echo "bench crate: $BENCH_DIR"
echo "lean dir:    $LEAN_DIR"
echo ""

# Step 1: glibc baseline
echo ">>> [1/2] Running glibc baseline (xmss_leaf_glibc)..."
cargo bench --manifest-path "$BENCH_DIR/Cargo.toml" \
    --bench xmss_leaf_glibc \
    -- --sample-size "$N" --warm-up-time 1 --save-baseline glibc 2>&1 | tee /tmp/eval_paired_glibc.log

echo ""

# Step 2: zk-alloc candidate
echo ">>> [2/2] Running zk-alloc candidate (xmss_leaf --features zkalloc)..."
cargo bench --manifest-path "$BENCH_DIR/Cargo.toml" \
    --bench xmss_leaf --features zkalloc \
    -- --sample-size "$N" --warm-up-time 1 --save-baseline zkalloc 2>&1 | tee /tmp/eval_paired_zkalloc.log

echo ""
echo "=== Results ==="
echo "glibc:"
grep -E "time:|change:" /tmp/eval_paired_glibc.log || echo "(no prior baseline)"
echo ""
echo "zkalloc:"
grep -E "time:|change:" /tmp/eval_paired_zkalloc.log || echo "(no prior baseline)"
echo ""

# Extract median times for comparison
glibc_time=$(grep -oP 'time:\s+\[\K[0-9.]+' /tmp/eval_paired_glibc.log | head -1 || echo "?")
zkalloc_time=$(grep -oP 'time:\s+\[\K[0-9.]+' /tmp/eval_paired_zkalloc.log | head -1 || echo "?")
echo "glibc median:   ${glibc_time}"
echo "zkalloc median: ${zkalloc_time}"

echo ""
echo "=== Done. Check target/criterion/ for HTML reports ==="
