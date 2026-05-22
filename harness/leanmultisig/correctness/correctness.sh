#!/bin/bash
# Shared correctness check for all leanMultisig experiments.
# Validates KoalaBear field arithmetic + full WHIR proof path.
# Run after every change before benchmarking.
#
# Inspired by the Plonky3 correctness-checker design:
# - Nondeterminism detection via repeat runs (catches data races from rayon)
# - Test-file integrity check (detects if agent modified test expectations)
# - Structured exit codes
#
# Exit code: 0 = pass, 1 = fail, 2 = nondeterminism detected,
#            3 = test-file integrity violation.

set -e

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
cd ~/zk-autoresearch/leanMultisig

export RUSTFLAGS="-C target-cpu=native"
export RUST_MIN_STACK=67108864

REPEAT=${CORRECTNESS_REPEAT:-1}

# -----------------------------------------------------------------------
# Inject vendored test files (quintic extension tests, etc.)
# These live in zk-autoresearch so they don't need cherry-picking per branch.
# -----------------------------------------------------------------------
bash "$SHARED_DIR/test_sources/inject_tests.sh"

# -----------------------------------------------------------------------
# Layer 0: Test-file integrity check
# Ensure the agent hasn't modified test expectations in writable crates.
# Hash file is stored in experiment_logs (read-only for the agent).
# -----------------------------------------------------------------------
INTEGRITY_FILE="$SHARED_DIR/test_integrity.sha256"

if [[ -f "$INTEGRITY_FILE" ]]; then
  echo "[correctness] Layer 0: Test-file integrity check..."
  # Compute current hashes of tracked test files
  TEST_FILE="crates/backend/koala-bear/src/quintic_extension/tests.rs"
  if [[ ! -f ~/zk-autoresearch/leanMultisig/$TEST_FILE ]]; then
    echo "[correctness] INTEGRITY VIOLATION: $TEST_FILE does not exist!"
    echo "[correctness] You may be on the wrong branch. Expected: feat/quintic-extension-tests (myfork)."
    echo "[correctness] Current branch: $(cd ~/zk-autoresearch/leanMultisig && git branch --show-current 2>/dev/null || echo 'detached')"
    exit 3
  fi
  CURRENT_HASH=$(cd ~/zk-autoresearch/leanMultisig && sha256sum "$TEST_FILE" | awk '{print $1}')
  EXPECTED_HASH=$(grep "quintic_extension/tests.rs" "$INTEGRITY_FILE" 2>/dev/null | awk '{print $1}' || echo "none")
  if [[ "$CURRENT_HASH" != "$EXPECTED_HASH" && "$EXPECTED_HASH" != "none" ]]; then
    echo "[correctness] INTEGRITY VIOLATION: $TEST_FILE was modified!"
    echo "[correctness] expected=$EXPECTED_HASH got=$CURRENT_HASH"
    echo "[correctness] This may indicate the agent changed test assertions to make incorrect code pass."
    exit 3
  fi
  echo "[correctness] Layer 0 PASSED — test files unmodified."
fi

# -----------------------------------------------------------------------
# Layer 1: Field arithmetic + backend primitive tests (~15s)
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 1: KoalaBear field + backend primitive tests (~15s)..."
cargo test -p mt-koala-bear -p mt-field -p mt-sumcheck -p mt-symetric --release 2>&1

# -----------------------------------------------------------------------
# Layer 2: Full WHIR proof integration test (~30s)
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 2: Full WHIR proof integration test (~30s)..."
cargo test -p mt-whir --release 2>&1

# -----------------------------------------------------------------------
# Layer 3: Type-1 + Type-2 aggregation end-to-end (~40s first, ~13s hot)
# Exercises aggregate_type_1, merge_many_type_1, split_type_2, verify.
# -----------------------------------------------------------------------
echo ""
echo "[correctness] Layer 3: Non-recursive + recursive aggregation end-to-end..."
cargo test --release test_aggregation -- --nocapture 2>&1
cargo test --release test_type_1_aggregation -- --nocapture 2>&1
cargo test --release test_type_2_aggregation -- --nocapture 2>&1

# -----------------------------------------------------------------------
# Layer 4: Nondeterminism detection (repeat runs)
# Only on repeat > 1. Re-runs the WHIR test to catch data races.
# -----------------------------------------------------------------------
if [[ "$REPEAT" -gt 1 ]]; then
  echo ""
  echo "[correctness] Layer 4: Nondeterminism detection ($REPEAT repeat runs)..."
  FAIL_COUNT=0
  for ((r=2; r<=REPEAT; r++)); do
    echo "[correctness]   repeat $r/$REPEAT..."
    if ! cargo test -p mt-whir --release 2>&1 >/dev/null; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "[correctness] NONDETERMINISM DETECTED: $FAIL_COUNT/$((REPEAT-1)) repeat runs failed."
    echo "[correctness] This indicates a data race or uninitialized memory in parallel code."
    exit 2
  fi
  echo "[correctness] Layer 4 PASSED — $REPEAT runs agree."
fi

echo ""
echo "[correctness] ALL PASSED."
