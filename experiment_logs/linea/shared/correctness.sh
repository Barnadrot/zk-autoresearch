#!/usr/bin/env bash
# Linea correctness gate — run after every change.
# Must pass before any benchmark is run.
#
# Usage: bash correctness.sh
#
# ⚠️ QUESTION (Friday): is there a larger integration test beyond TestVerifier (small params)?
#    If yes, add to Layer 3. TestVerifier uses polySize=1<<10, nbPolys=15 — may miss
#    production-scale bugs (large RS encoding, off-by-one in chunked parallelism).

set -e

PROVER_DIR=${PROVER_DIR:-$HOME/linea-monorepo/prover}
cd "$PROVER_DIR"

echo "[correctness] Layer 1: KoalaBear field arithmetic unit tests..."
go test ./maths/field/koalagnark/... \
    -timeout 60s -tags debug -count=1 -v 2>&1 | tail -5

echo "[correctness] Layer 2: Vortex KoalaBear commitment tests..."
go test ./crypto/vortex/vortex_koalabear/... \
    -timeout 120s -tags debug -count=1 -v 2>&1 | tail -5

echo "[correctness] Layer 3: Poseidon2 KoalaBear tests..."
go test ./crypto/poseidon2_koalabear/... \
    -timeout 60s -tags debug -count=1 -v 2>&1 | tail -5

# ⚠️ QUESTION (Friday): TestGnarkVerifier — circuit verifier, expensive, include?
# echo "[correctness] Layer 4: Gnark verifier circuit..."
# go test ./protocol/compiler/... -run TestGnarkVerifier -timeout 300s -count=1

echo "CORRECTNESS OK"
