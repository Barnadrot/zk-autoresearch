#!/bin/bash
# Security-first correctness gate for leanVM Goldilocks experiments.
# Forked from harness/leanvm/correctness/correctness.sh, adapted for
# Goldilocks field (p = 2^64 - 2^32 + 1), Poseidon8 (width=8, α=7),
# cubic extension (degree 3).
#
# Usage:
#   correctness.sh                            # normal mode — fail-fast
#   correctness.sh --expect-protected-changes # run all layers, tripwires → REVIEW
#
# Exit codes:
#   0 = all layers passed
#   1 = hard failure (crypto params, tests, soundness)
#   3 = all layers passed but protected-file changes need human review

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ~/zk-autoresearch/leanVM

export RUSTFLAGS="-C target-cpu=native"
export RUST_MIN_STACK=67108864

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

# Dispatches to review() in --expect-protected-changes mode, fail() otherwise
tripwire() {
  local layer="$1" what="$2" why="$3" fix="$4"
  if [[ "$EXPECT_PROTECTED" == "1" ]]; then
    review "$layer" "$what" "$why"
  else
    fail "$layer" "$what" "$why" "$fix"
  fi
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
# Layer 0.7: Diff hygiene checks
# Scans the experiment branch diff for patterns that indicate unsound
# shortcuts. Runs in ~100ms (grep only, no compilation).
#
# In --expect-protected-changes mode, checks 3-6 (structural/protected
# file changes) emit REVIEW instead of FAIL. Checks 1-2 (todo!/
# unimplemented!) always hard-fail — they're never sanctioned.
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.7: Diff hygiene checks..."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  DIFF_RS=$(git diff main...HEAD -- '*.rs' 2>/dev/null || echo "")

  # Check 1: No todo!() additions — always hard-fail
  TODO_HITS=$(echo "$DIFF_RS" | grep -c '^\+.*todo!\(\)' || true)
  if [[ "$TODO_HITS" -gt 0 ]]; then
    fail "0.7" \
      "Branch diff contains $TODO_HITS new todo!() macro(s) in Rust code." \
      "todo!() compiles but panics at runtime. In a ZK proving system, the honest prover may never hit the code path, so tests pass — but the verifier path is incomplete." \
      "Replace every todo!() with a real implementation. If the function is genuinely not needed, remove it entirely rather than leaving a stub."
  fi

  # Check 2: No unimplemented!() additions — always hard-fail
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
      "These methods define the commitment surface, constraint degree, and shift column count — all security-critical boundaries." \
      "Revert changes to these methods. If a structural change is genuinely needed for your optimization, document WHY in the commit message and request human review."
  fi

  # Check 4: Commitment boundary — tripwire
  PCS_HITS=$(echo "$DIFF_RS" | grep -c '^\+.*stack_polynomials_and_commit' || true)
  if [[ "$PCS_HITS" -gt 0 ]]; then
    tripwire "0.7" \
      "Branch diff modifies stack_polynomials_and_commit ($PCS_HITS change(s))." \
      "This function defines which columns the stacked PCS commits to. Modifying it can reduce the commitment surface without changing n_columns(), defeating the baseline check." \
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

BENCH_CRATE="${SHARED_DIR}/../bench"

# -----------------------------------------------------------------------
# Layer 0.8: Differential verification
# Generates a proof with the agent's (possibly modified) prover, then
# verifies it with a FROZEN reference verifier binary compiled from main.
#
# Logic:
#   frozen accepts → PASS (proof is sound under original security guarantees)
#   frozen rejects + verifier files unchanged → PASS (legitimate AIR/prover change)
#   frozen rejects + verifier files changed → FAIL (verifier changed AND proof incompatible)
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 0.8: Differential verification..."

FROZEN_VERIFIER="$SHARED_DIR/reference_verify_frozen"
if [[ -x "$FROZEN_VERIFIER" && "$CURRENT_BRANCH" != "main" ]]; then
  PROOF_FILE="/tmp/correctness_proof_$$.bin"

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

  if "$FROZEN_VERIFIER" "$PROOF_FILE" 2>&1; then
    echo "[correctness] Layer 0.8 PASSED — frozen reference verifier accepted the proof."
  else
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
      echo "[correctness]   Consider rebuilding the frozen binary from the current main branch."
    else
      fail "0.8" \
        "Frozen reference verifier rejected the proof AND verifier files were modified." \
        "The agent changed the verifier AND the generated proof is incompatible with the original verifier. This means the new proof format relies on modified verification logic — the original security guarantees may not hold." \
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

# -----------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------
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
