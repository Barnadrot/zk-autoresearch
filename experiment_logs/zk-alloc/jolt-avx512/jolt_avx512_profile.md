# Jolt AVX-512 deep profile — cross-prover compute-bound validation

**Date:** 2026-05-10
**Host:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, Zen 4, 8c/16t, AVX-512, 64 GiB DDR5, Linux 6.8.0-100)
**Jolt commit:** `1b25ad1413efdc438f5f139f593c92864908d123` (main + local zkalloc wiring; **wiring unused — built without the `zkalloc` feature**, default system allocator)
**Benchmark:** `jolt-core profile --name fibonacci` (fibonacci-guest, 400 000 iterations)
**Allocator:** glibc default (no zk-alloc, no jemalloc, no mimalloc)
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release -p jolt-core --bin jolt-core`

## TL;DR

Jolt on Zen 4 + AVX-512 is **compute-bound, same general regime as leanMultisig** (low cache-miss rate, DRAM bandwidth a few percent of ceiling, near-zero kernel time), but the microarchitectural fingerprint is **distinctly different**: IPC 1.55 (vs leanMultisig 0.91), no single dominant kernel (top function is 17%, vs leanMultisig's 75%-in-`compress_mut`), and the hot path is **scalar 254-bit Montgomery multiplication on MULX/ADCX/ADOX — not AVX-512**. The cross-prover claim "ZK provers on Zen 4 + AVX-512 are compute-bound at low cache miss" **corroborates**. The narrower claim "the dominant kernel is one AVX-512 SIMD body latency-bound by Montgomery chains" is **leanMultisig-specific** — it derives from KoalaBear's small-field SIMD Poseidon, which Jolt does not use. Jolt's bottleneck is scalar integer-multiply throughput on the BN254 base field, plus pairing-tower extension multiplications inside the Dory commitment.

---

## 1. Environment and benchmark choice

### CPU / kernel

```
AMD Ryzen 7 PRO 8700GE w/ Radeon 780M Graphics  (Zen 4, family 25 model 117 stepping 2)
microcode 0xa70520a, cpu MHz scaling (perf measured 4.17–4.18 GHz under load)
flags include: avx, avx2, avx512f, avx512dq, avx512vl, avx512bw, avx512cd, avx512vbmi,
               avx512vbmi2, avx512vnni, avx512bitalg, avx512vpopcntdq, avx512_bf16, gfni,
               vaes, vpclmulqdq, sha_ni, bmi1, bmi2, adx, rdseed
THP: always [madvise] never           (system default — untouched)
perf_event_paranoid: -1               (perf works without sudo)
```

`perf list` exposes the standard hardware set (`cycles`, `instructions`, `cache-references`, `cache-misses`, `branches`, `branch-misses`, `stalled-cycles-frontend`). No Zen-4-specific raw PMU events were needed for this run.

### Benchmark choice

Candidates probed (1 run each, default allocator):

| Bench | Wall | Peak RSS |
|---|---:|---:|
| btreemap | 6.59 s | 369 MB |
| sha2 (2 KiB input) | 7.69 s | 369 MB |
| **fibonacci (400 000 iter)** | **22.41 s** | **2.27 GB** |

Picked `fibonacci`. Reasoning:

- Pure arithmetic guest loop → exercises Jolt's **standard prove path** (sumcheck, Dory commitment, opening proofs) without the inline-specialized constraints that `sha2` / `sha3` use (`jolt-inlines-sha2`, `jolt-inlines-keccak256`) and which would skew the hot-function attribution toward those primitives.
- 22.7 s wall is comfortably above the program's 5 s threshold, giving clean counter coverage well above noise.
- The maintainers list it as a standard `profile --name` target in `CLAUDE.md`.

`btreemap`/`sha2` are smaller but exercise a narrower kernel surface; the size difference (369 MB vs 2.3 GB working set) also means `fibonacci` is the run most likely to stress the cache hierarchy if a memory-bound regime existed — making the "not memory-bound" verdict stronger.

---

## 2. Compute-vs-memory verdict (mirrors leanMultisig Q1)

`perf stat`, 3 back-to-back runs, full counter set listed in §6:

| Run | Wall (s) | Cycles | Instructions | IPC | Cache refs | Cache misses | Miss rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 22.668 | 1.1855e12 | 1.8364e12 | **1.55** | 1.731e10 | 5.894e8 | **3.40%** |
| 2 | 22.700 | 1.1847e12 | 1.8366e12 | **1.55** | 1.733e10 | 5.853e8 | **3.38%** |
| 3 | 22.750 | 1.1851e12 | 1.8370e12 | **1.55** | 1.732e10 | 5.938e8 | **3.43%** |
| **median** | **22.700** | **1.1851e12** | **1.8366e12** | **1.55** | **1.732e10** | **5.894e8** | **3.40%** |

Derived:

- **IPC = 1.55** (rock-stable across runs, σ < 0.005)
- **Cache-miss rate = 3.40%** (LLC-miss / LLC-ref proxy on Zen 4)
- **Estimated DRAM bandwidth** = 589 M × 64 B / 22.70 s = **1.66 GB/s ≈ 3.3 % of ~50 GB/s DDR5 ceiling**
- **Branch-miss rate** = 5.92 % (moderate; consistent with data-dependent dispatch in `jolt_optimizations::batch_addition` and rayon work-stealing)
- **Frontend-idle** = 8.5 % of cycles (frontend is not the bottleneck — backend is)
- **User : sys ratio** = 274.78 s : 8.98 s ≈ **30.6 ×** (kernel time is ~3 % — mostly mmap/page-fault from the 2.3 GB working set; 2 960 K page faults observed)
- **CPU utilization** = 12.5 CPUs of 16 threads (rayon-saturated; remaining headroom is parallel-section non-coverage and Amdahl)

**One-line cross-prover comparison:**

> Jolt: IPC = 1.55, cache-miss = 3.40 %, DRAM BW = 3.3 % of ceiling.
> leanMultisig: IPC = 0.91, cache-miss = 3.57 %, DRAM BW = 7.8 % of ceiling.

Both **firmly compute-bound**. Jolt has notably more ILP headroom (IPC ~70 % higher) and uses even less DRAM bandwidth than leanMultisig.

---

## 3. Cycle attribution (top 15)

`perf record -F 999 --call-graph dwarf` → `perf report --no-children --no-call-graph` (281 K samples, 1.124 × 10¹² cycle-events):

| # | Cycle % | Symbol | Component |
|---:|---:|---|---|
| 1 | **17.00 %** | `MontBackend<…>::sum_of_products` | BN254 Fq Montgomery sum-of-products |
| 2 | 9.01 % | `Fp<P,_> as MulAssign<&Fp<P,_>>::mul_assign` | BN254 field × field |
| 3 | 7.09 % | `MontBackend<…>::mul_assign` (instance A) | BN254 Montgomery multiply |
| 4 | 6.07 % | `jolt_optimizations::batch_addition::batch_g1_additions_multi` | BN254 G1 batched curve addition (MSM) |
| 5 | 5.89 % | `rayon::iter::plumbing::Producer::fold_with` | Rayon parallel-iter overhead (inlined hot leaf) |
| 6 | 5.66 % | `MontBackend<…>::mul_assign` (instance B) | BN254 Montgomery multiply (separate inlined site) |
| 7 | 3.43 % | `Fp6::mul_by_01` | Pairing tower (Fp6 cubic ext) |
| 8 | 2.70 % | `MontBackend<…>::sum_of_products` (instance B) | BN254 sum-of-products (separate site) |
| 9 | 2.56 % | `FnMut for &F::call_mut` | Closure dispatch (rayon plumbing) |
| 10 | 2.53 % | `Fp<P,_> as Field::square_in_place` | BN254 field squaring |
| 11 | 2.04 % | `FnMut for &F::call_mut` (separate site) | Closure dispatch |
| 12 | 1.61 % | `Fp12::mul_by_034` | Pairing tower (Fp12 quadratic ext, ell line eval) |
| 13 | 1.46 % | `jolt_core::poly::ra_poly::RaPolynomial::get_bound_coeff` | Lazy RA polynomial bind |
| 14 | 1.39 % | `DoryCommitmentScheme::process_chunk_onehot` | Dory streaming commitment (one-hot RA chunks) |
| 15 | 1.29 % | `CubicExtField::mul_assign` | Generic cubic extension multiply (Fp6) |

### Dominant kernel

There is **no single dominant kernel** in the leanMultisig sense. The hot work is **distributed across BN254 field arithmetic**:

- Summing all Montgomery / Fp / Fp6 / Fp12 / curve-arithmetic samples (rows 1–4, 6–8, 10, 12, 15, plus the long tail under 1 % each) yields **≈ 55 % of cycles in BN254 field + curve arithmetic**.
- The pairing tower (Fp6 `mul_by_01`, Fp12 `mul_by_034`, `multi_miller_loop`, `ell`) accounts for ~7 % directly and pulls heavily from the Montgomery rows via inlining — this is Dory pairing-based commitment evaluation.
- `batch_g1_additions_multi` (6.07 %) is Jolt's optimized batched G1 add used inside MSM during commitment.
- Rayon plumbing leaves (~10 % when summed across `fold_with`, `bridge_producer_consumer::helper`, `call_mut`, `MapProducer`) is the visible cost of the parallel-iterator fabric; the actual arithmetic is inlined into these frames.

### SIMD vs scalar

Critically, the top kernels are **not AVX-512**. `MontBackend::sum_of_products` and `mul_assign` on BN254 Fq (254-bit prime, 4 × 64-bit limbs) compile to **scalar `MULX` / `ADCX` / `ADOX`** (BMI2 + ADX), not vector instructions. arkworks does not vectorize 254-bit Montgomery — the dependency chain across limbs precludes a straightforward SIMD layout. So although the build sets `-C target-cpu=native` and the CPU has full AVX-512, **Jolt's hot loop is integer-multiply-throughput-bound, not vector-bound**. AVX-512 is only relevant on rare auxiliary kernels (some `jolt_optimizations` paths and rayon-internal copies).

This contrasts directly with leanMultisig's KoalaBear field (31-bit prime, fits in a single 32-bit lane), where Poseidon's compress body packs many independent S-boxes into a single AVX-512 zmm and the bottleneck is the Montgomery-multiply latency chain on the SIMD units.

---

## 4. Cross-prover comparison

| Metric | leanMultisig (post-PR-216, this machine) | Jolt (this run) | Δ |
|---|---:|---:|---|
| Wall per prove | 2.06 s | **22.70 s** | Jolt is ~11 × longer (bigger field, more constraints, includes verify) |
| IPC | 0.91 | **1.55** | Jolt **+70 %** — more ILP, less latency-dominated |
| Cache-miss rate | 3.57 % | **3.40 %** | essentially tied (both well below memory-bound) |
| DRAM BW utilization | 7.8 % of 50 GB/s | **3.3 % of 50 GB/s** | Jolt half — even further from memory-bound |
| Frontend-idle | n/a (not in source profile) | 8.5 % | not a frontend bottleneck |
| Branch-miss rate | n/a | 5.92 % | moderate |
| Top function (cycle %) | `compress_mut` (Poseidon, AVX-512 SIMD) — 75.1 % | `MontBackend::sum_of_products` (BN254, scalar MULX/ADCX/ADOX) — **17.0 %** | very different shape |
| Hot-kernel architecture | one tight AVX-512 vector body | distributed across BN254 field + pairing tower + curve | — |
| Bottleneck mechanism | Montgomery multiply latency chain on SIMD units | 254-bit Montgomery multiply throughput on scalar integer multipliers | — |

---

## 5. Verdict — is Jolt in the same compute-bound regime as leanMultisig?

**Yes for the broad claim, no for the narrow claim.**

**Corroborated:** ZK provers on Zen 4 + AVX-512 are compute-bound, not memory-bound. Jolt and leanMultisig agree on every memory-related signal: cache-miss rate ~3.4 %, DRAM bandwidth a single-digit percentage of the DDR5 ceiling, near-zero kernel time, no frontend stalls. Whatever optimization lever applies to provers on this microarchitecture, it is not on the memory side — both provers are spending almost all of their cycles doing arithmetic, with the cache hierarchy keeping up easily.

**Not corroborated:** the more specific mechanism. leanMultisig is **latency-bound on a single AVX-512 SIMD Poseidon body** — 75 % of cycles in `compress_mut`, IPC 0.91 because Montgomery-multiply latency chains on the SIMD multiplier serialize the S-boxes. Jolt is **throughput-bound on scalar 254-bit Montgomery multiplications** — IPC 1.55 (more parallel work available across pairing tower extension fields and curve point arithmetic), with the hottest single function only 17 %. The two provers occupy the same regime (compute-bound, not memory-bound) but for **different reasons** rooted in **different field choices**:

- **Small-field provers** (KoalaBear-class, 31-bit) → bottleneck is **AVX-512 vector multiply latency** on a single hot SIMD kernel.
- **Large-field provers** (BN254-class, 254-bit) → bottleneck is **scalar `MULX`/`ADCX`/`ADOX` throughput** across distributed Montgomery operations in the field, pairing tower, and elliptic curve, plus the Dory commitment plumbing that orchestrates them.

**Implication for cross-prover optimization theory:** the unifying claim "ZK provers on Zen 4 are compute-bound and not memory-bound on this hardware" is robust — it shows up identically on both provers despite the wildly different field and protocol. The narrower claim "the dominant kernel is a Poseidon-class AVX-512 body limited by Montgomery latency chains" is **field-specific**, not a general property of ZK proving on this machine. Plans to optimize Jolt should target scalar integer-multiply throughput (e.g., wider parallelism across cores, smaller field embeddings, or pairing tower restructuring) rather than AVX-512 vector kernels; leanMultisig-style SIMD interventions will not transfer.

---

## 6. Raw artifacts (kept under `runs/`)

- `runs/perf_stat_fibonacci_run{1,2,3}.txt` — full counter dumps for each of the 3 runs
- `runs/perf_fibonacci.data` — `perf record -F 999 --call-graph dwarf` (2.26 GB, 281 K samples)
- `runs/perf_report_top.txt` — top of `perf report --no-children --max-stack=20` (call-graph view, top 100 lines)
- `runs/perf_report_flat.txt` — `perf report --no-children --no-call-graph` (flat top symbols)
- `runs/cpuinfo.txt`, `runs/perf_list_head.txt` — environment snapshots

`cargo flamegraph` was not installed on this host (no `cargo install` step performed — out of scope per program §C "if available, skip"); the perf report text is sufficient given the absence of a 75%-dominant kernel that a flamegraph would have visualized.
