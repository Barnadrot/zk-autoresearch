#!/bin/bash
# Proof-transcript mutation fuzzer for leanVM correctness gate.
#
# Strategy: generate one valid proof, then mutate random bytes in the
# serialized transcript and verify the verifier REJECTS every mutation.
# A mutation that passes verification indicates a verifier bug (missing
# check, weak assertion, or unsound protocol change).
#
# Runtime: ~15-30s (build + 1 proof generation + N fast verifications)
# Run: on keeps only, or periodically during autoresearch
#
# Exit codes:
#   0 = all mutations rejected (verifier is robust)
#   1 = at least one mutation accepted (SOUNDNESS CONCERN)
#   2 = infrastructure error

set -eo pipefail

BENCH_CRATE=${BENCH_CRATE:-$HOME/zk-autoresearch/harness/leanvm/bench}
N_MUTATIONS=${N_MUTATIONS:-200}
SEED=${FUZZ_SEED:-$RANDOM}

echo "[fuzz] Proof-transcript mutation fuzzer"
echo "[fuzz] N_MUTATIONS=$N_MUTATIONS SEED=$SEED"

cd "$BENCH_CRATE"
export RUSTFLAGS="-C target-cpu=native"

cargo build --release --bin fuzz_proof_rejection 2>&1 | tail -3

./target/release/fuzz_proof_rejection --mutations "$N_MUTATIONS" --seed "$SEED"
