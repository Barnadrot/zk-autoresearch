# Linea Vortex/KoalaBear Optimizer — Autoresearch

## Role

You are an expert Go systems programmer specializing in high-performance cryptographic code and
CPU microarchitecture. Your job is to make the Linea prover faster on the `prover/dev-small-fields`
branch — specifically the KoalaBear small-field proving path.

**Hardware target:** AMD EPYC 9R14 (Zen 4), AVX-512 available. Server: Plonky3 server (idle).
**Language:** Pure Go. The prover is Go + gnark framework. No Rust in the prover itself.

---

## Codebase Context

### Repo location
```
~/linea-monorepo/          ← clone of Consensys/linea-monorepo
  prover/                  ← Go prover (cd here for all go commands)
    crypto/vortex/vortex_koalabear/   ← Vortex PCS, KoalaBear-specific
    crypto/poseidon2_koalabear/       ← Poseidon2, already AVX-512 optimized
    maths/field/koalagnark/           ← KoalaBear field arithmetic (circuit API)
```

Branch: `prover/dev-small-fields`

### Architecture
```
zkEVM / RISC-V traces      ← arithmetization (not our target)
        ↓
Wizard constraint system
        ↓
Vortex PCS + KoalaBear     ← what we are optimizing
        ↓
gnark recursion (BN254)
```

RISC-V migration only touches arithmetization. Vortex + KoalaBear is unchanged regardless
of trace source — our optimizations are durable.

---

## Profiling Results (2026-04-15, BenchmarkVortexHashPathsByRows, dev-small-fields)

> ⚠️ DRAFT — lightweight commitment-phase benchmark only. Full-scale profile pending
> (blocked by 16GB RAM on server; BenchmarkCompilerWithSelfRecursion needs 64GB).
> Treat as directional signal, not final truth.

| Rank | Function | Self% | Location | Notes |
|---|---|---|---|---|
| 1 | `poseidon2.permutation16_avx512` | 53% | gnark-crypto | Already AVX-512 — NOT our target |
| 2 | `fft.difFFT` | 6% | gnark-crypto | RS encoding FFT |
| 3 | `koalabear.(*Vector).Mul` | 4.65% | gnark-crypto | Field vector multiply |
| 4 | `montReduce` | 3.52% | gnark-crypto | Montgomery reduction |
| 5 | `fft.innerDIFWithTwiddlesGeneric` | 3.13% | gnark-crypto | **Generic FFT — no AVX-512. Key gap.** |
| 6 | `koalabear.mulVec` | 2.45% | gnark-crypto | Field vector multiply |
| 7 | `ringsis.TransversalHash` | 2.44% | linea-monorepo | SIS hashing |
| 8 | `(*Regular).Get` | 1.92% | linea-monorepo | Scalar access in LinearCombination loop |
| 9 | `fft.innerDIFWithTwiddles` | 1.58% | gnark-crypto | Non-generic FFT inner loop |
| 10 | `sis.(*LimbIterator).NextLimb` | 1.45% | gnark-crypto | SIS limb iteration |

**Key finding:** All hot functions are in `gnark-crypto` (also Consensys — contributing is in scope).
LinearCombination itself is thin orchestration; cost is in the field ops it calls.

---

## Hot Path Targets (priority order)

### Target 1 — `LinearCombination` MulAccByElement fix
**File:** `prover/crypto/vortex/prover_common.go`
**Self%:** ~2% (via `(*Regular).Get` + field ops)

Current code lifts base field element → extension field, then does ext×ext multiply (9 muls).
The `limitless-onthefly` branch has already implemented `MulAccByElement` (ext×base = 4 muls)
but this has NOT been backported to `dev-small-fields`.

**Action:** Port the MulAccByElement optimization from `limitless-onthefly` to `dev-small-fields`.
This is a logical optimization (mul count reduction), no SIMD required.

⚠️ **FRIDAY QUESTION:** Is this fix planned to merge into `dev-small-fields`? If yes, start on
top of it. If no, implement it ourselves.

**Expected gain:** Significant on LinearCombination-heavy workloads. Unknown e2e % until full profile.

---

### Target 2 — KoalaBear field arithmetic AVX-512 (gnark-crypto)
**Files:** `github.com/consensys/gnark-crypto` — koalabear package
**Self%:** ~15% combined (`Vector.Mul`, `montReduce`, `mulVec`, `mulVec`)

KoalaBear is a 31-bit field. Field arithmetic is generic Go with no AVX-512 SIMD.
Opportunity: pack 2 KoalaBear elements per 64-bit word (both fit in 31 bits), vectorize
multiplications using AVX-512 instructions via Go assembly (`TEXT` functions in `.s` files).

⚠️ **FRIDAY QUESTION:** Confirm gnark-crypto contributions are in scope. Confirm field
extension degree — k=4 (quartic) vs k=5 (quintic) affects which operations to optimize.

**Expected gain:** Large. ~15% of proven self-time, no existing SIMD.

---

### Target 3 — FFT generic path AVX-512
**File:** gnark-crypto `fft` package
**Self%:** `innerDIFWithTwiddlesGeneric` 3.13%

Poseidon2 already closed the AVX-512 gap for hashing. FFT hasn't been done.
Generic path has no SIMD — same gap that existed in Plonky3 before NTT optimization.

⚠️ **DEPENDENCY:** Confirm FFT is not already being worked on by gnark-crypto team.

---

### Target 4 — `(*Regular).Get` access pattern in LinearCombination
**File:** `prover/crypto/vortex/prover_common.go`
**Self%:** 1.92%

Scalar element access in the LinearCombination inner loop. May be replaceable with
packed/batch access to improve cache behavior.

---

## Phase 0 — Profile to Validate Hot Paths

**Gate:** Run before any optimization. Confirm hot paths match profiling table above.

```bash
cd ~/linea-monorepo/prover
git checkout prover/dev-small-fields

# Lightweight profile (fits in 16GB):
go test -cpuprofile=cpu.prof \
    -bench=BenchmarkVortexHashPathsByRows \
    -benchtime=30s \
    ./crypto/vortex/vortex_koalabear/...
go tool pprof -top cpu.prof | head -30
```

**Stop if:** Hot paths differ significantly from table above. Investigate before optimizing.

⚠️ **FULL PROFILE BLOCKED:** BenchmarkCompilerWithSelfRecursion needs 64GB RAM.
AWS quota expansion pending (~1 day). Use lightweight benchmark for now.
Alexandre Belling (Linea team) confirmed GOMEMLIMIT can help; runnable benchmarks provided TBD.

---

## Phase 1 — Correctness Gate

Run `bash ~/zk-autoresearch/experiment_logs/linea/shared/correctness.sh` after every change.

### Scope
- `TestVerifier` — cryptographic round-trip (commit→prove→verify). Primary gate.
- `TestNoSisTransversalHashMatchesReference` — optimized vs reference hash comparison.

⚠️ **QUESTION (Friday):** Is there a larger integration test? TestVerifier uses small params
(polySize=1<<10, nbPolys=15) — may not catch production-scale bugs.

---

## Phase 2 — Benchmark Harness

### Noise floor (FIRST)
Run `bash ~/zk-autoresearch/experiment_logs/linea/shared/noise_floor.sh` before any experiment.
Characterize σ. Set KEEP_THRESHOLD_PCT = 2×σ in config.env.

**Expected σ:** ~1-2% (Go GC, OS scheduling). Higher than Rust/leanMultisig.

⚠️ **QUESTION:** Does the team have existing bench tooling or noise characterization?
If yes, adopt their approach.

### Missing benchmarks to write
`BenchmarkLinearCombination` does not exist. Add to `prover/crypto/vortex/prover_common_bench_test.go`:

```go
func BenchmarkLinearCombination(b *testing.B) {
    sizes := []struct{ name string; rows, cols int }{
        {"rows_64_cols_131072", 64, 1 << 17},
        {"rows_256_cols_524288", 256, 1 << 19},
    }
    for _, s := range sizes {
        // setup polys, randomCoin
        b.Run(s.name, func(b *testing.B) {
            b.ReportAllocs()
            b.ResetTimer()
            for i := 0; i < b.N; i++ {
                vortex.LinearCombination(&proof, polys, randomCoin)
            }
        })
    }
}
```

⚠️ **QUESTION (Friday):** Confirm production row/column sizes for V1-V4 layers.

---

## Experiment Loop

1. Read this program.md + `iters.tsv`
2. Pick ONE target, form ONE hypothesis
3. Edit source
4. Run correctness.sh — if fail: revert, log `correctness_fail`
5. Run eval_bench.sh — compare baseline via benchstat
6. Keep (Δ ≤ -KEEP_THRESHOLD_PCT, p < 0.05) or discard
7. If keep: `eval_bench.sh --save-baseline`, commit
8. If discard: `git revert HEAD --no-edit`
9. Log row to iters.tsv

---

## Agent Writable Scope

| Path | Writable |
|---|---|
| `prover/crypto/vortex/prover_common.go` | Yes |
| `prover/crypto/vortex/vortex_koalabear/commtiment.go` | Yes |
| `prover/maths/field/koalagnark/ext.go` | Yes |
| `prover/crypto/poseidon2_koalabear/poseidon2.go` | Yes |
| `prover/crypto/vortex/prover_common_bench_test.go` | Yes (new file, benchmarks only) |
| gnark-crypto koalabear package (if Friday confirms in scope) | Yes |
| All existing `*_test.go` | **Read-only** |
| `prover/protocol/` | **Read-only** |
| `prover/zkevm/` | **Read-only** |

---

## Open Questions — Friday Call (2026-04-18)

| # | Question | Blocks |
|---|---|---|
| 1 | Is FRI migration imminent, or is Vortex optimization still worthwhile? | Gate on entire effort |
| 2 | Is `limitless-onthefly` MulAccByElement fix landing in `dev-small-fields`? | Starting point for Target 1 |
| 3 | Confirm field extension degree: k=4 (quartic) or k=5 (quintic)? | Target 2 scope |
| 4 | Are gnark-crypto contributions in scope? | Target 2 unlocks |
| 5 | Is there a larger integration test beyond TestVerifier (small params)? | Correctness gate |
| 6 | Confirm production benchmark sizes (rows/cols for V1-V4)? | Benchmark realism |
| 7 | Does team have existing bench tooling or noise floor data? | Harness design |
| 8 | Which hot paths is Srinath NOT touching? (memory/streaming only — confirm) | Overlap risk |

---

## Known Dead Ends

*(populated as experiment progresses)*

---

## Srinath Overlap — Confirmed Clear

Srinath's branches (`srinath/prover-vortex-opt`, `level2`) focus on **peak memory reduction**:
streaming commitment, incremental hashing. Original `LinearCombination` and field arithmetic
are untouched. Zero arithmetic overlap confirmed from branch analysis (2026-04-15).
His agent loop stalled Apr 2 at 0% wall-clock gain — memory is not the bottleneck.
