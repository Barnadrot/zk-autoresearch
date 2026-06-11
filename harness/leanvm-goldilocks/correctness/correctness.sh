#!/bin/bash
# Security-first correctness gate for leanVM Goldilocks experiments.
# Forked from harness/leanvm/correctness/correctness.sh, adapted for
# Goldilocks field (p = 2^64 - 2^32 + 1), Poseidon8 (width=8, α=7),
# cubic extension (degree 3).

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ~/zk-autoresearch/leanVM

export RUSTFLAGS="-C target-cpu=native"
export RUST_MIN_STACK=67108864

fail() {
  local layer="$1" what="$2" why="$3" fix="$4"
  echo ""
  echo "================================================================"
  echo "[correctness] FAILED at Layer ${layer}"
  echo "================================================================"
  echo ""
  echo "WHAT: ${what}"
  echo ""
  echo "WHY THIS MATTERS: ${why}"
  echo ""
  echo "ACTION REQUIRED: ${fix}"
  echo "================================================================"
  exit 1
}

# -----------------------------------------------------------------------
# Layer 0.5: Crypto parameter guard (Goldilocks-specific)
# -----------------------------------------------------------------------
echo "[correctness] Layer 0.5: Crypto parameter guard (Goldilocks)..."

# Poseidon round counts (Goldilocks spec: R_F=8 i.e. HALF=4, R_P=22, α=7)
HALF_FULL=$(grep "pub const POSEIDON1_HALF_FULL_ROUNDS" crates/backend/goldilocks/src/poseidon1.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
PARTIAL=$(grep "pub const POSEIDON1_PARTIAL_ROUNDS" crates/backend/goldilocks/src/poseidon1.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$HALF_FULL" != "4" || "$PARTIAL" != "22" ]]; then
  fail "0.5" \
    "Poseidon round counts modified: HALF_FULL=${HALF_FULL} (expected 4), PARTIAL=${PARTIAL} (expected 22)." \
    "Poseidon round counts are security-critical. Goldilocks Poseidon8 uses R_F=8, R_P=22, α=7." \
    "Revert changes to poseidon1.rs. Round count changes require explicit human approval."
fi

# S-box degree (Goldilocks: x^7)
SBOX_DEG=$(grep "pub const POSEIDON1_SBOX_DEGREE" crates/backend/goldilocks/src/poseidon1.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$SBOX_DEG" != "7" ]]; then
  fail "0.5" \
    "Poseidon S-box degree modified from 7 to ${SBOX_DEG}." \
    "The S-box degree α=7 is chosen for Goldilocks security. Changing it alters all cryptanalytic bounds." \
    "Revert POSEIDON1_SBOX_DEGREE to 7."
fi

# Security bits
SEC_BITS=$(grep "pub const SECURITY_BITS" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$SEC_BITS" != "128" ]]; then
  fail "0.5" \
    "SECURITY_BITS changed from 128 to ${SEC_BITS}." \
    "The Goldilocks branch targets 128-bit security." \
    "Revert SECURITY_BITS to 128 in crates/lean_prover/src/lib.rs."
fi

# WHIR folding factors (Goldilocks: initial=6, subsequent=4)
WHIR_INIT=$(grep "pub const WHIR_INITIAL_FOLDING_FACTOR" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
WHIR_SUBS=$(grep "pub const WHIR_SUBSEQUENT_FOLDING_FACTOR" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$WHIR_INIT" != "6" || "$WHIR_SUBS" != "4" ]]; then
  fail "0.5" \
    "WHIR folding factors modified: INITIAL=${WHIR_INIT} (expected 6), SUBSEQUENT=${WHIR_SUBS} (expected 4)." \
    "WHIR folding factors affect security vs proof size trade-off." \
    "Revert to WHIR_INITIAL_FOLDING_FACTOR=6, WHIR_SUBSEQUENT_FOLDING_FACTOR=4."
fi

echo "[correctness] Layer 0.5 PASSED — crypto parameters match Goldilocks spec."

# -----------------------------------------------------------------------
# Layer 0.9: Format gate
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.9: Format gate (cargo fmt --check)..."
if ! cargo fmt --check 2>&1; then
  fail "0.9" \
    "cargo fmt --check found formatting differences." \
    "Inconsistent formatting makes diffs noisy and code review harder." \
    "Run 'cargo fmt' and commit the result."
fi
echo "[correctness] Layer 0.9 PASSED."

# -----------------------------------------------------------------------
# Layer 1: Compile gate
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 1: Compile gate (cargo clippy -Dwarnings)..."
if ! cargo clippy --all-targets --release -- -Dwarnings 2>&1; then
  fail 1 \
    "cargo clippy found warnings or errors." \
    "Clippy warnings often indicate logic bugs or incomplete refactors." \
    "Fix each warning. Then re-run."
fi
echo "[correctness] Layer 1 PASSED."

# -----------------------------------------------------------------------
# Layer 2: Field arithmetic + backend tests
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 2: Goldilocks field + backend primitive tests..."
if ! cargo test -p goldilocks -p field -p sumcheck -p symetric --release 2>&1; then
  fail 2 \
    "Field arithmetic or backend primitive tests failed." \
    "These validate Goldilocks field operations, cubic extension, sumcheck protocol, and symmetric hash." \
    "Read the test failure output. Your change broke fundamental crypto building blocks."
fi
echo "[correctness] Layer 2 PASSED."

# -----------------------------------------------------------------------
# Layer 3: Structural invariants
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 3: Structural soundness invariants..."
if ! cargo test -p lean_vm --release 2>&1; then
  fail 3 \
    "lean_vm unit tests failed (table structure, bus width, column layout)." \
    "Table definitions are internally inconsistent." \
    "Read the failing test name. Fix the structural inconsistency."
fi
if ! cargo test -p lean_vm --release -- core::constants::tests 2>&1; then
  fail 3 \
    "Core constants tests failed (LOGUP overflow or commitment surface bounds)." \
    "Column counts or table sizes exceeded safe boundaries." \
    "Check ensure_not_too_big_commitment_surface and ensure_no_overflow_in_logup."
fi
if ! cargo test -p sub_protocols --release --test soundness_logup 2>&1; then
  fail 3 \
    "LOGUP soundness test failed." \
    "Extension field degree may not provide sufficient security bits for current table sizes." \
    "Check if you increased table sizes beyond the cubic extension's soundness budget."
fi
echo "[correctness] Layer 3 PASSED."

# -----------------------------------------------------------------------
# Layer 4: WHIR proof integration
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 4: Full WHIR proof integration test..."
if ! cargo test -p whir --release 2>&1; then
  fail 4 \
    "WHIR proof integration test failed." \
    "The commitment scheme, folding protocol, or verification broke." \
    "Revert your last commit and re-test."
fi
echo "[correctness] Layer 4 PASSED."

# -----------------------------------------------------------------------
# Layer 5: Aggregation end-to-end
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 5: Aggregation end-to-end..."
if ! cargo test --release test_aggregation -- --nocapture 2>&1; then
  fail 5 \
    "test_aggregation failed (full prove + verify pipeline)." \
    "End-to-end proving system is broken." \
    "Read the panic/error. Common: column index mismatch, constraint degree change, bus interaction error."
fi
if ! cargo test --release test_xmss_signature -- --nocapture 2>&1; then
  fail 5 \
    "test_xmss_signature failed." \
    "XMSS signature generation or verification broke." \
    "Check crates/xmss/."
fi
echo "[correctness] Layer 5 PASSED."

# -----------------------------------------------------------------------
# Layer 6: Free variable soundness gate
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 6: Free variable soundness check..."
BENCH_CRATE="${SHARED_DIR}/../bench"
(
  cd "$BENCH_CRATE"
  cargo build --release --bin soundness_check 2>&1 | tail -3
)
if ! "$BENCH_CRATE/target/release/soundness_check" 2>&1; then
  fail 6 \
    "Free variable soundness check failed." \
    "Virtual columns are not bound by bus interactions — soundness hole." \
    "Every virtual column must be committed or bound by a bus interaction."
fi
echo "[correctness] Layer 6 PASSED."

# -----------------------------------------------------------------------
# Layer 7: Proof-transcript mutation fuzzer
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 7: Proof-transcript mutation fuzzer (200 mutations)..."
(
  cd "$BENCH_CRATE"
  cargo build --release --bin fuzz_proof_rejection 2>&1 | tail -3
)
if ! "$BENCH_CRATE/target/release/fuzz_proof_rejection" --mutations 200 --seed "$RANDOM" 2>&1; then
  fail 7 \
    "Proof-transcript mutation fuzzer accepted a corrupted proof." \
    "The verifier has a bug — it accepted a mutated transcript." \
    "Check verifier changes. A common cause is adding a prover step without the corresponding verifier check."
fi
echo "[correctness] Layer 7 PASSED."

echo ""
echo "[correctness] ALL LAYERS PASSED."
