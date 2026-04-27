#!/usr/bin/env bash
# Per-commit benchstat for PR descriptions.
# Runs eval_bench.sh at each commit boundary and captures benchstat output.
set -e

LINEA_DIR="$HOME/zk-autoresearch/linea-monorepo"
GNARK_DIR="$HOME/zk-autoresearch/gnark-crypto"
SHARED="$HOME/zk-autoresearch/experiment_logs/linea/shared"
OUT_DIR="$HOME/zk-autoresearch/experiment_logs/linea/experiment_vortex_koalabear/report/benchstat"
mkdir -p "$OUT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Phase 1: Linea-monorepo commits (no gnark-crypto replace yet)
# Commits: iter1 (f04b8b6a9), iter2 (a84d417b0), iter3 (a60d9a66f), iter6 (07ac55cb2)
# Commit 5 (go.mod replace) is not benchmarked standalone — it enables phase 2.

LINEA_COMMITS=(
  "f04b8b6a9:iter01_MulAccByElement"
  "a84d417b0:iter02_eliminate_copy"
  "a60d9a66f:iter03_MDHasher_buffer"
  "07ac55cb2:iter06_Compressx16_SIMD"
)

# Baseline: the commit before our first change
LINEA_BASE="f233ef6cd"

cd "$LINEA_DIR"
# Make sure gnark-crypto is on upstream (no replace directive)
git checkout vortex-koalabear-optimizations-clean -- prover/go.mod prover/go.sum 2>/dev/null || true

log "=== Phase 1: Linea-monorepo per-commit benchmarks ==="

# Save baseline from pre-optimization state
log "Saving baseline at $LINEA_BASE..."
git checkout "$LINEA_BASE" -- prover/crypto/vortex/prover_common.go prover/crypto/poseidon2_koalabear/poseidon2.go prover/crypto/vortex/vortex_koalabear/commtiment.go 2>/dev/null
# Restore original go.mod (no replace)
git checkout "$LINEA_BASE" -- prover/go.mod prover/go.sum 2>/dev/null || true
cd prover && go mod tidy 2>/dev/null; cd ..
bash "$SHARED/eval_bench.sh" --save-baseline

prev="$LINEA_BASE"
for entry in "${LINEA_COMMITS[@]}"; do
  commit="${entry%%:*}"
  name="${entry##*:}"
  log "Benchmarking $name ($commit)..."

  # Checkout the file state at this commit
  git checkout "$commit" -- prover/crypto/vortex/prover_common.go prover/crypto/poseidon2_koalabear/poseidon2.go prover/crypto/vortex/vortex_koalabear/commtiment.go 2>/dev/null

  bash "$SHARED/eval_bench.sh" > "$OUT_DIR/${name}.txt" 2>&1

  log "Saving baseline for next commit..."
  bash "$SHARED/eval_bench.sh" --save-baseline

  log "Done: $name"
done

# Phase 2: gnark-crypto commits (need replace directive active)
log "=== Phase 2: gnark-crypto per-commit benchmarks ==="

# Activate replace directive
git checkout vortex-koalabear-optimizations-clean -- prover/go.mod prover/go.sum
cd prover && go mod tidy 2>/dev/null; cd ..

GNARK_COMMITS=(
  "fae1bfd04:iter11_unrolled_kernels"
  "fa93b4245:iter12_inline_stages"
  "978c75d4f:iter16_nbTasks1_fastpath"
  "808f3e8ed:iter17_2x_unroll_ILP"
  "2474a6e9b:iter22_funcptr_elimination"
  "d4e1e17e8:iter25_embed_vector"
)

# Baseline: gnark-crypto at upstream (999356aaf) with linea changes applied
GNARK_BASE="999356aaf"

cd "$GNARK_DIR"
log "Setting gnark-crypto to upstream base $GNARK_BASE..."
git checkout "$GNARK_BASE" -- field/koalabear/fft/fft.go field/koalabear/sis/sis.go 2>/dev/null

cd "$LINEA_DIR"
log "Saving baseline with replace directive + upstream gnark-crypto..."
bash "$SHARED/eval_bench.sh" --save-baseline

for entry in "${GNARK_COMMITS[@]}"; do
  commit="${entry%%:*}"
  name="${entry##*:}"
  log "Benchmarking $name ($commit)..."

  cd "$GNARK_DIR"
  git checkout "$commit" -- field/koalabear/fft/fft.go field/koalabear/sis/sis.go 2>/dev/null

  cd "$LINEA_DIR"
  bash "$SHARED/eval_bench.sh" > "$OUT_DIR/${name}.txt" 2>&1

  log "Saving baseline for next commit..."
  bash "$SHARED/eval_bench.sh" --save-baseline

  log "Done: $name"
done

# Restore both repos to clean branch HEAD
cd "$LINEA_DIR" && git checkout vortex-koalabear-optimizations-clean -- . 2>/dev/null
cd "$GNARK_DIR" && git checkout vortex-koalabear-fft-optimizations-clean -- . 2>/dev/null

log "=== All benchmarks complete ==="
log "Results in: $OUT_DIR/"
ls -la "$OUT_DIR/"
