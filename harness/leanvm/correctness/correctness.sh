#!/bin/bash
# Security-first correctness gate for leanVM experiments.
# Validates soundness invariants, field arithmetic, proof paths, and
# protocol-level security properties. Performance checks (recursion
# regression, proof size scoring) live in eval_paired.sh.
#
# On failure: prints a structured diagnostic block with what failed,
# why it matters, and what the agent should do to fix it.
#
# Usage:
#   correctness.sh                            # normal mode — fail-fast
#   correctness.sh --expect-protected-changes # run all layers, tripwires → REVIEW
#
# Exit code: 0 = pass, 1 = fail, 2 = nondeterminism detected,
#            3 = all passed but protected-file changes need human review.

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ~/zk-autoresearch/leanVM

export RUSTFLAGS="-C target-cpu=native"
export RUST_MIN_STACK=67108864

REPEAT=${CORRECTNESS_REPEAT:-1}

# -----------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------
EXPECT_PROTECTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-protected-changes) EXPECT_PROTECTED=1; shift ;;
    *) echo "[correctness] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------
# Result tracking (used in --expect-protected-changes mode)
# -----------------------------------------------------------------------
GATE_FAILURES=0
GATE_REVIEWS=0
REVIEW_ITEMS=""

# -----------------------------------------------------------------------
# Failure handler — every layer calls fail() instead of letting set -e
# produce an opaque exit. The message tells the agent exactly what broke,
# why it matters, and what to do.
#
# In --expect-protected-changes mode, fail() records but does not exit,
# so all layers run and the agent gets the full evidence set in one pass.
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
  GATE_FAILURES=$((GATE_FAILURES + 1))
  if [[ "$EXPECT_PROTECTED" != "1" ]]; then
    exit 1
  fi
}

review() {
  local layer="$1" what="$2" why="$3"
  echo ""
  echo "================================================================"
  echo "[correctness] REVIEW at Layer ${layer}"
  echo "================================================================"
  echo ""
  echo "WHAT: ${what}"
  echo ""
  echo "WHY: ${why}"
  echo ""
  echo "STATUS: Needs human review before merge."
  echo "================================================================"
  GATE_REVIEWS=$((GATE_REVIEWS + 1))
  REVIEW_ITEMS="${REVIEW_ITEMS}  - Layer ${layer}: ${what}\n"
}

tripwire() {
  local layer="$1" what="$2" why="$3" fix="$4"
  if [[ "$EXPECT_PROTECTED" == "1" ]]; then
    review "$layer" "$what" "$why"
  else
    fail "$layer" "$what" "$why" "$fix"
  fi
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

# WHIR folding factors
WHIR_INIT=$(grep "pub const WHIR_INITIAL_FOLDING_FACTOR" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
WHIR_SUBS=$(grep "pub const WHIR_SUBSEQUENT_FOLDING_FACTOR" crates/lean_prover/src/lib.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$WHIR_INIT" != "7" || "$WHIR_SUBS" != "5" ]]; then
  fail "0.5" \
    "WHIR folding factors modified: INITIAL=${WHIR_INIT} (expected 7), SUBSEQUENT=${WHIR_SUBS} (expected 5)." \
    "WHIR folding factors affect the trade-off between proof size and security. Increasing them reduces query count and weakens soundness. These parameters are tuned for 124-bit security with JohnsonBound." \
    "Revert WHIR_INITIAL_FOLDING_FACTOR to 7 and WHIR_SUBSEQUENT_FOLDING_FACTOR to 5 in crates/lean_prover/src/lib.rs."
fi

# Poseidon S-box degree (spec: x^3 for KoalaBear)
SBOX_DEG=$(grep "pub const POSEIDON1_SBOX_DEGREE" crates/backend/koala-bear/src/poseidon1_koalabear_16.rs | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [[ "$SBOX_DEG" != "3" ]]; then
  fail "0.5" \
    "Poseidon S-box degree modified from 3 to ${SBOX_DEG}." \
    "The S-box degree determines the algebraic degree growth per round and the security margin against algebraic attacks. Reducing it from x^3 weakens the CICO and interpolation attack bounds." \
    "Revert POSEIDON1_SBOX_DEGREE to 3 in poseidon1_koalabear_16.rs."
fi

# MDS matrix first column (circulant)
MDS_COL=$(grep "const MDS_CIRC_COL" crates/backend/koala-bear/src/poseidon1_koalabear_16.rs | grep -oE '\[.*\]' | head -1)
EXPECTED_MDS="[1, 3, 13, 22, 67, 2, 15, 63, 101, 1, 2, 17, 11, 1, 51, 1]"
if [[ "$MDS_COL" != *"$EXPECTED_MDS"* ]]; then
  fail "0.5" \
    "MDS circulant column modified." \
    "The MDS matrix defines the linear diffusion layer. Changing it alters the branch number and the differential/linear attack resistance. The MDS matrix is part of the Poseidon specification." \
    "Revert MDS_CIRC_COL to the specification values in poseidon1_koalabear_16.rs."
fi

echo "[correctness] Layer 0.5 PASSED — crypto parameters match spec."

# -----------------------------------------------------------------------
# Layer 0.7: Diff hygiene checks
# Scans the experiment branch diff for patterns that indicate unsound
# shortcuts. Runs in ~100ms (grep only, no compilation).
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.7: Diff hygiene checks..."

# Only run if we're on an experiment branch (not main)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  DIFF_RS=$(git diff main...HEAD -- '*.rs' 2>/dev/null || echo "")

  # Check 1: No todo!() additions
  TODO_HITS=$(echo "$DIFF_RS" | grep -c '^\+.*todo!\(\)' || true)
  if [[ "$TODO_HITS" -gt 0 ]]; then
    fail "0.7" \
      "Branch diff contains $TODO_HITS new todo!() macro(s) in Rust code." \
      "todo!() compiles but panics at runtime. In a ZK proving system, the honest prover may never hit the code path, so tests pass — but the verifier path is incomplete. This is the exact pattern that bypassed the gate in pw12 and pw13." \
      "Replace every todo!() with a real implementation. If the function is genuinely not needed, remove it entirely rather than leaving a stub."
  fi

  # Check 2: No unimplemented!() additions
  UNIMPL_HITS=$(echo "$DIFF_RS" | grep -c '^\+.*unimplemented!\(\)' || true)
  if [[ "$UNIMPL_HITS" -gt 0 ]]; then
    fail "0.7" \
      "Branch diff contains $UNIMPL_HITS new unimplemented!() macro(s) in Rust code." \
      "unimplemented!() is functionally identical to todo!() — it compiles but panics. Same risk as todo!(): verifier paths may be left incomplete." \
      "Replace every unimplemented!() with a real implementation or remove the function."
  fi

  # Check 3: Structural invariant methods — tripwire (REVIEW in protected mode)
  STRUCT_HITS=$(echo "$DIFF_RS" | grep -cE '^\+.*(fn n_columns|fn n_columns_total|fn degree_air|fn n_shift_columns|fn low_degree_air)' || true)
  if [[ "$STRUCT_HITS" -gt 0 ]]; then
    tripwire "0.7" \
      "Branch diff modifies structural AIR methods ($STRUCT_HITS change(s): fn n_columns, fn n_columns_total, fn degree_air, or fn n_shift_columns)." \
      "These methods define the commitment surface, constraint degree, and shift column count — all security-critical boundaries. Changing them alters what the stacked PCS commits, how many sumcheck rounds run, or which transition constraints are active. The soundness_check baseline will also catch this, but this early grep blocks the change before compilation." \
      "Revert changes to these methods. If a structural change is genuinely needed for your optimization, document WHY in the commit message and request human review."
  fi

  # Check 4: Commitment boundary — tripwire
  PCS_HITS=$(echo "$DIFF_RS" | grep -c '^\+.*stack_polynomials_and_commit' || true)
  if [[ "$PCS_HITS" -gt 0 ]]; then
    tripwire "0.7" \
      "Branch diff modifies stack_polynomials_and_commit ($PCS_HITS change(s))." \
      "This function defines which columns the stacked PCS commits to. Modifying it can reduce the commitment surface without changing n_columns(), defeating the baseline check. This is the exact attack surface exploited in pw8 h44." \
      "Revert changes to stack_polynomials_and_commit. Commitment boundary changes require human review."
  fi

  # Check 5: Verifier — tripwire
  VERIFIER_DIFF=$(git diff main...HEAD -- 'crates/lean_prover/src/verify_execution.rs' 2>/dev/null || echo "")
  VERIFIER_ADDITIONS=$(echo "$VERIFIER_DIFF" | grep -c '^\+' || true)
  if [[ "$VERIFIER_ADDITIONS" -gt 0 ]]; then
    tripwire "0.7" \
      "Branch diff modifies verify_execution.rs ($VERIFIER_ADDITIONS addition(s))." \
      "The verifier is the trust root of the proving system. A weakened verifier accepts invalid proofs even when the AIR is sound. Verifier modifications require human cryptographer review." \
      "Revert changes to verify_execution.rs. If the optimization requires verifier changes (e.g., new WHIR parameters), document the security argument and request human review."
  fi

  # Check 6: Fiat-Shamir / WHIR core — tripwire
  for CRITICAL_FILE in \
    "crates/backend/fiat-shamir/src/prover.rs" \
    "crates/backend/fiat-shamir/src/verifier.rs" \
    "crates/whir/src/verify.rs" \
    "crates/whir/src/open.rs" \
    "crates/sub_protocols/src/air_sumcheck.rs"; do
    FS_DIFF=$(git diff main...HEAD -- "$CRITICAL_FILE" 2>/dev/null || echo "")
    FS_ADDS=$(echo "$FS_DIFF" | grep -c '^\+' || true)
    if [[ "$FS_ADDS" -gt 0 ]]; then
      tripwire "0.7" \
        "Branch diff modifies $CRITICAL_FILE ($FS_ADDS addition(s))." \
        "This file is part of the cryptographic protocol core (Fiat-Shamir, WHIR, or sumcheck). Modifications can reduce soundness without affecting honest-prover tests." \
        "Revert changes to $CRITICAL_FILE. Protocol-core modifications require human review."
    fi
  done

  if [[ "$GATE_REVIEWS" -eq 0 ]] && [[ "$GATE_FAILURES" -eq 0 || "$EXPECT_PROTECTED" == "1" ]]; then
    echo "[correctness] Layer 0.7 PASSED — diff hygiene clean."
  elif [[ "$GATE_REVIEWS" -gt 0 ]]; then
    echo "[correctness] Layer 0.7: $GATE_REVIEWS item(s) flagged for REVIEW."
  fi
else
  echo "[correctness] Layer 0.7 SKIPPED — on main branch."
fi

# -----------------------------------------------------------------------
# Layer 0.8: Differential verification
# Generates a proof with the agent's (possibly modified) prover, then
# verifies it with a FROZEN reference verifier binary compiled from main.
# This is the trust root: the agent can change anything they want, but
# the proof must still be accepted by the original verifier.
#
# Logic:
#   frozen accepts → PASS (proof is sound under original security guarantees)
#   frozen rejects + verifier files unchanged → PASS (legitimate AIR/prover change)
#   frozen rejects + verifier files changed → FAIL (verifier changed AND proof incompatible)
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.8: Differential verification..."

FROZEN_VERIFIER="$SHARED_DIR/reference_verify_frozen"
BENCH_CRATE="${SHARED_DIR}/../bench"
if [[ -x "$FROZEN_VERIFIER" && "$CURRENT_BRANCH" != "main" ]]; then
  PROOF_FILE="/tmp/correctness_proof_$$.bin"

  # Step 1: Build and run the prover (uses agent's code)
  (
    cd "$BENCH_CRATE"
    cargo build --release --bin proof_generate 2>&1 | tail -3
  )
  if ! "$BENCH_CRATE/target/release/proof_generate" "$PROOF_FILE" 2>&1; then
    fail "0.8" \
      "proof_generate failed — could not generate a proof with the agent's prover." \
      "The agent's modified prover cannot produce a valid proof. This is a critical failure." \
      "Check your prover changes. The proof generation uses the same path as test_aggregation."
  fi

  # Step 2: Verify with frozen reference binary
  if "$FROZEN_VERIFIER" "$PROOF_FILE" 2>&1; then
    echo "[correctness] Layer 0.8 PASSED — frozen reference verifier accepted the proof."
  else
    # Frozen verifier rejected. Check if verifier files were modified.
    VERIFIER_CHANGED=0
    for VFILE in \
      "crates/lean_prover/src/verify_execution.rs" \
      "crates/backend/fiat-shamir/src/verifier.rs" \
      "crates/whir/src/verify.rs" \
      "crates/sub_protocols/src/air_sumcheck.rs"; do
      if git diff main...HEAD --name-only 2>/dev/null | grep -q "$VFILE"; then
        VERIFIER_CHANGED=1
        break
      fi
    done

    if [[ "$VERIFIER_CHANGED" -eq 0 ]]; then
      echo "[correctness] Layer 0.8 PASS (fallback) — frozen verifier rejected but verifier files are unmodified (legitimate AIR/prover format change)."
      echo "[correctness] WARNING: The frozen reference verifier is incompatible with the current proof format."
      echo "[correctness]   This means differential verification provides NO security value for this experiment."
      echo "[correctness]   Consider rebuilding the frozen binary from the current main branch."
    else
      fail "0.8" \
        "Frozen reference verifier rejected the proof AND verifier files were modified." \
        "The agent changed the verifier AND the generated proof is incompatible with the original verifier. This means the new proof format relies on modified verification logic — the original security guarantees may not hold. A malicious prover could exploit the verification changes to forge proofs." \
        "Either (a) revert verifier file changes and optimize only the prover, or (b) ensure the proof is accepted by the frozen verifier. Verifier changes that alter the proof format require human cryptographer review."
    fi
  fi
  rm -f "$PROOF_FILE"
else
  if [[ "$CURRENT_BRANCH" == "main" ]]; then
    echo "[correctness] Layer 0.8 SKIPPED — on main branch."
  else
    echo "[correctness] Layer 0.8 SKIPPED — frozen verifier not found at $FROZEN_VERIFIER."
  fi
fi

# -----------------------------------------------------------------------
# Layer 0.9: Format gate (cargo fmt --check)
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.9: Format gate (cargo fmt --check)..."
if ! cargo fmt --check 2>&1; then
  fail "0.9" \
    "cargo fmt --check found formatting differences." \
    "Inconsistent formatting makes diffs noisy and code review harder. The upstream CI enforces rustfmt." \
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
if ! cargo test -p koala-bear -p field -p sumcheck -p symetric --release 2>&1; then
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
if ! cargo test -p whir --release 2>&1; then
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
    if ! cargo test -p whir --release 2>&1 >/dev/null; then
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
if [[ "$GATE_FAILURES" -gt 0 ]]; then
  echo "[correctness] $GATE_FAILURES FAILURE(S), $GATE_REVIEWS REVIEW item(s)."
  exit 1
elif [[ "$GATE_REVIEWS" -gt 0 ]]; then
  echo "[correctness] ALL LAYERS PASSED. $GATE_REVIEWS item(s) flagged for REVIEW:"
  echo -e "$REVIEW_ITEMS"
  echo "[correctness] These changes require human review before merge."
  exit 3
else
  echo "[correctness] ALL LAYERS PASSED."
fi
