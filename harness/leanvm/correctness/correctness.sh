#!/bin/bash
# Security-first correctness gate for leanVM experiments.
# Validates soundness invariants, field arithmetic, proof paths, and
# protocol-level security properties. Performance checks (recursion
# regression, proof size scoring) live in eval_paired.sh.
#
# On failure: prints a structured diagnostic block with what failed,
# why it matters, and what the agent should do to fix it.
#
# Exit code: 0 = pass, 1 = fail, 2 = nondeterminism detected,
#            3 = test-file integrity violation.

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ~/zk-autoresearch/leanVM

export RUSTFLAGS="-C target-cpu=native"
export RUST_MIN_STACK=67108864

REPEAT=${CORRECTNESS_REPEAT:-1}

# -----------------------------------------------------------------------
# Failure handler — every layer calls fail() instead of letting set -e
# produce an opaque exit. The message tells the agent exactly what broke,
# why it matters, and what to do.
# -----------------------------------------------------------------------
fail() {
  local layer="$1"
  local what="$2"
  local why="$3"
  local fix="$4"
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
# Inject vendored test files (quintic extension tests, etc.)
# -----------------------------------------------------------------------
bash "$SHARED_DIR/test_sources/inject_tests.sh"

# -----------------------------------------------------------------------
# Layer 0: Test-file integrity check
# -----------------------------------------------------------------------
INTEGRITY_FILE="$SHARED_DIR/test_integrity.sha256"

if [[ -f "$INTEGRITY_FILE" ]]; then
  echo "[correctness] Layer 0: Test-file integrity check..."
  TEST_FILE="crates/backend/koala-bear/src/quintic_extension/tests.rs"
  if [[ ! -f ~/zk-autoresearch/leanVM/$TEST_FILE ]]; then
    fail 0 \
      "$TEST_FILE does not exist." \
      "The vendored test file is missing. You may be on the wrong branch or it was deleted." \
      "Check your branch with 'git branch --show-current'. The file should be injected by inject_tests.sh. If you deleted it, revert that change."
  fi
  if command -v sha256sum &>/dev/null; then
    CURRENT_HASH=$(sha256sum "$TEST_FILE" | awk '{print $1}')
  else
    CURRENT_HASH=$(shasum -a 256 "$TEST_FILE" | awk '{print $1}')
  fi
  EXPECTED_HASH=$(grep "quintic_extension/tests.rs" "$INTEGRITY_FILE" 2>/dev/null | awk '{print $1}' || echo "none")
  if [[ "$CURRENT_HASH" != "$EXPECTED_HASH" && "$EXPECTED_HASH" != "none" ]]; then
    fail 0 \
      "Test file $TEST_FILE was modified (expected=$EXPECTED_HASH got=$CURRENT_HASH)." \
      "Modifying test expectations to make incorrect code pass defeats the correctness gate. The hash is tracked in test_integrity.sha256." \
      "Revert your changes to $TEST_FILE. Fix your code to pass the original tests, not the other way around."
  fi
  echo "[correctness] Layer 0 PASSED — test files unmodified."
fi

# -----------------------------------------------------------------------
# Layer 0.5: Crypto parameter guard
# Verifies security-critical constants haven't been modified from spec.
# Pure grep checks — no compilation, runs in milliseconds.
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.5: Crypto parameter guard..."

# Poseidon round counts (spec: R_F=8 i.e. HALF=4, R_P=20)
HALF_FULL=$(grep "pub const POSEIDON1_HALF_FULL_ROUNDS" crates/backend/koala-bear/src/poseidon1_koalabear_16.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
PARTIAL=$(grep "pub const POSEIDON1_PARTIAL_ROUNDS" crates/backend/koala-bear/src/poseidon1_koalabear_16.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$HALF_FULL" != "4" || "$PARTIAL" != "20" ]]; then
  fail "0.5" \
    "Poseidon round counts modified: HALF_FULL_ROUNDS=${HALF_FULL} (expected 4), PARTIAL_ROUNDS=${PARTIAL} (expected 20)." \
    "Poseidon round counts are security-critical parameters defined in the leanVM spec (Section 4.2: N_full/2=4, N_partial=20). Reducing rounds trades security margin for speed — the interpolation attack bound requires R_F+R_P >= 24 for 124-bit security. The Poseidon Initiative bounty has R_F=6,R_P=8 BROKEN and R_F=6,R_P=10 OPEN at \$15K." \
    "Revert your changes to poseidon1_koalabear_16.rs. Round count changes require explicit human approval and a published security analysis."
fi

# Security bits
SEC_BITS=$(grep "pub const SECURITY_BITS" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$SEC_BITS" != "124" ]]; then
  fail "0.5" \
    "SECURITY_BITS changed from 124 to ${SEC_BITS}." \
    "The security target is a system-wide parameter that affects WHIR query counts, grinding bits, and all soundness proofs. Changing it without updating the entire security analysis invalidates all soundness guarantees." \
    "Revert SECURITY_BITS to 124 in crates/lean_prover/src/lib.rs."
fi

# Soundness assumption (must be JohnsonBound or feature-gated CapacityBound)
if grep -q "SecurityAssumption::CapacityBound" crates/lean_prover/src/lib.rs; then
  # Check it's behind a feature flag, not hardcoded
  if ! grep -B2 "SecurityAssumption::CapacityBound" crates/lean_prover/src/lib.rs | grep -q "cfg.*feature\|prox.gaps"; then
    fail "0.5" \
      "CapacityBound hardcoded without feature flag in lib.rs." \
      "CapacityBound is a conjectured (not proven) proximity gap assumption. The strong form was disproven in 2025. It must remain behind the prox-gaps-conjecture feature flag so the system can revert to the proven JohnsonBound if the conjecture is further weakened." \
      "Restore the feature flag: use cfg!(feature = \"prox-gaps-conjecture\") to gate CapacityBound, with JohnsonBound as the default."
  fi
fi

echo "[correctness] Layer 0.5 PASSED — crypto parameters match spec."

# -----------------------------------------------------------------------
# Layer 1: Compile gate
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 1: Compile gate (cargo clippy -Dwarnings)..."
if ! cargo clippy --all-targets --release -- -Dwarnings 2>&1; then
  fail 1 \
    "cargo clippy found warnings or errors in the workspace." \
    "Clippy warnings often indicate logic bugs, unused code from incomplete refactors, or type mismatches. With -Dwarnings, any warning is a hard failure." \
    "Read the clippy output above. Fix each warning in your last commit. Common fixes: remove unused imports, add #[allow] only if the warning is a false positive, fix type conversion issues. Then re-run this gate."
fi
echo "[correctness] Layer 1 PASSED."

# -----------------------------------------------------------------------
# Layer 2: Field arithmetic + backend primitive tests
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 2: KoalaBear field + backend primitive tests (~15s)..."
if ! cargo test -p mt-koala-bear -p mt-field -p mt-sumcheck -p mt-symetric --release 2>&1; then
  fail 2 \
    "Field arithmetic or backend primitive tests failed." \
    "These tests validate KoalaBear field operations (modular arithmetic, extension field, Montgomery form), sumcheck protocol correctness, and symmetric hash primitives. A failure here means your change broke fundamental cryptographic building blocks." \
    "Read the test failure output above to identify the failing test. Your change likely modified code in crates/backend/. Revert and isolate which edit broke field arithmetic. Do NOT proceed with higher layers — everything above depends on correct field ops."
fi
echo "[correctness] Layer 2 PASSED."

# -----------------------------------------------------------------------
# Layer 3: Unit + structural invariants
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 3: Structural soundness invariants..."
if ! cargo test -p lean_vm --release 2>&1; then
  fail 3 \
    "lean_vm unit tests failed (table structure, bus width, column layout)." \
    "These tests verify that table definitions are internally consistent: column counts match struct sizes, bus interaction widths are correct, table indices are sequential. A failure means your change broke the table/AIR structural invariants." \
    "Read the failing test name above. If test_max_bus_width failed, you changed a bus_interactions() method and the MAX_BUS_WIDTH constant needs updating. If test_table_indices failed, you changed the Table enum ordering. Fix the structural inconsistency in your last commit."
fi
if ! cargo test -p lean_vm --release -- core::constants::tests 2>&1; then
  fail 3 \
    "Core constants tests failed (LOGUP overflow or commitment surface bounds)." \
    "ensure_no_overflow_in_logup checks that total memory lookups across all tables fit in the base field. ensure_not_too_big_commitment_surface checks that the stacked PCS polynomial fits within the WHIR domain. A failure means your change pushed column counts or table sizes past the safe boundary." \
    "Check which test failed: if ensure_not_too_big_commitment_surface, you added too many committed columns and the stacked polynomial exceeds 2^30. Reduce committed column count or increase WHIR capacity. If ensure_no_overflow_in_logup, your bus_interactions() added lookups that overflow the field order."
fi
if ! cargo test -p sub_protocols --release --test soundness_logup 2>&1; then
  fail 3 \
    "LOGUP soundness test failed (ensure_logup_soundness_is_suffisant)." \
    "This test verifies that the extension field degree provides enough security bits for the LOGUP protocol given current table sizes. A failure means your change increased table sizes or reduced the security margin below 124 bits." \
    "Check if you increased MAX_LOG_N_ROWS_PER_TABLE or MAX_LOG_MEMORY_SIZE. Either revert the size increase or verify that the quintic extension still provides sufficient soundness bits for your new sizes."
fi
if ! cargo test -p lean_prover --release --test check_whir_configs 2>&1; then
  fail 3 \
    "WHIR config consistency test failed (Rust vs Python verifier mismatch)." \
    "The WHIR parameters in Rust (default_whir_config) must exactly match the WHIR_CONFIGS constant in the Python verifier (python-verifier/verifier.py). A mismatch means proofs generated by Rust cannot be verified by the Python verifier, breaking cross-implementation compatibility." \
    "Run 'cargo test -p lean_prover --test check_whir_configs -- --nocapture' to see the expected WHIR_CONFIGS line. Copy that line into crates/lean_prover/python-verifier/verifier.py, replacing the existing WHIR_CONFIGS assignment."
fi
echo "[correctness] Layer 3 PASSED."

# -----------------------------------------------------------------------
# Layer 4: Full WHIR proof integration test
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 4: Full WHIR proof integration test (~30s)..."
if ! cargo test -p mt-whir --release 2>&1; then
  fail 4 \
    "WHIR proof integration test failed (prove + verify round-trip)." \
    "This test generates a WHIR polynomial commitment, produces a proof, and verifies it. A failure means your change broke either the commitment scheme, the folding protocol, or the FRI/WHIR verification. This is a critical soundness failure — the prover and verifier no longer agree." \
    "Check the test output for which WHIR test failed. Common causes: changed folding factor without updating round parameters, broke Fiat-Shamir transcript ordering, modified the Merkle tree structure. Revert your last commit and re-test."
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
    "This test runs the complete XMSS signature aggregation pipeline: trace generation, AIR constraint evaluation, LOGUP bus balancing, stacked PCS commitment, AIR sumcheck, WHIR opening, and verification. A failure here means your change broke the end-to-end proving system." \
    "This is a high-level integration failure. Read the panic/error message above. Common causes: column index mismatch after struct reorder, constraint degree change without updating air_degree(), bus interaction data referencing wrong columns. If the error mentions 'verification failed', the proof is invalid — check your AIR constraints. If it panics during trace generation, check your table's execute() or fill_trace() method."
fi
if ! cargo test --release test_xmss_signature -- --nocapture 2>&1; then
  fail 5 \
    "test_xmss_signature failed (XMSS signature generation or verification)." \
    "This test verifies that raw XMSS signatures are correctly generated and verified before aggregation. A failure here is likely in the XMSS or WOTS+ implementation, not in the proving system." \
    "Check if you modified crates/xmss/. If not, this may be a dependency issue. Read the error message above."
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
    "Free variable soundness check failed — virtual columns are not bound." \
    "Your change introduced virtual columns (columns with index >= n_columns() and < n_columns_total()) that are NOT referenced by any bus interaction. These columns are free variables at the AIR sumcheck oracle check: a malicious prover can set them to ANY value and still pass verification, completely defeating soundness. This is the exact vulnerability that sank pw8 (h44 virtual Poseidon columns). The soundness_check binary printed the per-table breakdown above — look for tables with free > 0." \
    "Every virtual column must be either: (1) committed to the stacked PCS (move it below n_columns() by reordering the struct and increasing N_COMMITTED), or (2) bound by a bus interaction (memory lookup, bytecode lookup) so the verifier can derive its evaluation from committed data. If you virtualized columns for performance, you must add a binding protocol (GKR quotient, LOGUP pushforward) that proves their values at the AIR sumcheck evaluation point r_air. Do NOT simply pass this gate by re-committing all columns — understand WHY the column needs binding."
fi
echo "[correctness] Layer 6 PASSED."

# -----------------------------------------------------------------------
# Layer 7: Proof-transcript mutation fuzzer
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 7: Proof-transcript mutation fuzzer (200 mutations, ~3s)..."
(
  cd "$BENCH_CRATE"
  cargo build --release --bin fuzz_proof_rejection 2>&1 | tail -3
)
if ! "$BENCH_CRATE/target/release/fuzz_proof_rejection" --mutations 200 --seed "$RANDOM" 2>&1; then
  fail 7 \
    "Proof-transcript mutation fuzzer found accepted mutations — the verifier accepted a corrupted proof." \
    "A valid proof was generated, then random bytes were mutated in the serialized transcript. The verifier should reject every mutation. An accepted mutation means the verifier has a bug: it either skips a check, has an off-by-one in field element parsing, or has a logical error in constraint evaluation. This is a critical security vulnerability — an attacker could forge proofs." \
    "The fuzzer output above shows which mutation strategy (single-byte flip, multi-byte corruption, zero fill, or boundary mutation) produced accepted proofs. Check your changes to the verifier (verify_execution.rs, verify.rs) and the Fiat-Shamir transcript (prover.rs, verifier.rs in fiat-shamir). A common cause is adding a prover step without the corresponding verifier check."
fi
echo "[correctness] Layer 7 PASSED."

# -----------------------------------------------------------------------
# Layer 8: Nondeterminism detection (repeat runs)
# -----------------------------------------------------------------------
if [[ "$REPEAT" -gt 1 ]]; then
  echo ""
  echo "[correctness] Layer 8: Nondeterminism detection ($REPEAT repeat runs)..."
  FAIL_COUNT=0
  for ((r=2; r<=REPEAT; r++)); do
    echo "[correctness]   repeat $r/$REPEAT..."
    if ! cargo test -p mt-whir --release 2>&1 >/dev/null; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    echo "================================================================"
    echo "[correctness] FAILED at Layer 8"
    echo "================================================================"
    echo ""
    echo "WHAT: Nondeterminism detected — $FAIL_COUNT/$((REPEAT-1)) repeat runs of the WHIR test failed."
    echo ""
    echo "WHY THIS MATTERS: The same test passes sometimes and fails sometimes. This indicates a data race in parallel code (rayon), use of uninitialized memory, or order-dependent hash accumulation. Nondeterministic provers produce different proofs for the same input, which breaks reproducibility and may indicate a soundness issue."
    echo ""
    echo "ACTION REQUIRED: Check your changes for unsafe parallel access patterns. Common causes: shared mutable state across rayon par_iter without synchronization, Vec::set_len() on uninitialized memory, HashMap iteration order leaking into transcript. Run with RAYON_NUM_THREADS=1 to confirm — if it passes single-threaded, the bug is a data race. Use cargo test with --test-threads=1 and MIRI if available."
    echo "================================================================"
    exit 2
  fi
  echo "[correctness] Layer 8 PASSED — $REPEAT runs agree."
fi

echo ""
echo "[correctness] ALL LAYERS PASSED."
