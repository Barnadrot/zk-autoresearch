# leanMultisig — Experiment 5: Poseidon + WHIR

## Role
Expert ZK protocol engineer and SIMD performance engineer. Poseidon hash optimization,
Merkle tree commitment structures, AVX-512 instruction scheduling on Zen 4.

**Hardware:** AMD EPYC Genoa (Zen 4), c7a.2xlarge, AVX-512, KVM.
**Baseline:** `1ad5fe25` (origin/main, 2026-04-22). ~4.49s Criterion, ~50s production.
**Branch:** `exp5_poseidon_whir` on `myfork`.

## Why this target

Production profile (fancy-aggregation, post degree-split, 2026-04-21):

| Component | % e2e | Notes |
|---|---|---|
| **Poseidon permute_mut (PackedKB)** | **23.7%** | WHIR Merkle tree compression — the target |
| Poseidon permute_mut (KoalaBear) | 1.2% | Fiat-Shamir challenger |
| Poseidon permute_mut (QuinticExt) | 1.0% | Extension field hashing |
| AIR constraint eval | 10.3% | Read-only — separate surface |
| Kernel/OS (KVM) | 10.2% | Not actionable |

25.9% total in `permute_mut`. The 23.7% PackedKB monomorphization is the only one
worth targeting — the other two are <1.2% each (even 50% local improvement < 0.6% e2e).

## The Hot Path

```
prove_execution.rs
  → stacked_pcs / WHIR polynomial commitment
    → whir/commit.rs: MerkleData::build()
      → whir/merkle.rs: merkle_commit()
        → symetric/merkle.rs: compress_layer()          ← rayon-parallel, per tree level
          → symetric/permutation.rs: compress_mut()
            → poseidon1_koalabear_16.rs: compress_in_place()
              → permute_mut(&mut [PackedKB; 16])         ← 23.7% e2e
                → permute_simd()
                  → mds_circ_16 (circulant MDS, Karatsuba, ~72 PF muls)
                  → S-box (x³)
                  → round constant addition
```

## Two angles on 25.9%

### A. Make permute_mut faster (SIMD, instruction scheduling)

Three sub-targets inside `permute_simd`:

1. **MDS circulant multiply** — Karatsuba convolution over width-16 circulant matrix.
   ~72 packed-field multiplies per round. Study whether FFT-based MDS or restructured
   Karatsuba can reduce multiply count or improve port utilization.

2. **S-box + MDS scheduling** — cube (`x * x * x`) feeds into MDS. Two dependent muls
   followed by 72 MDS muls. Study whether interleaving S-box and MDS across rounds
   can hide latency (OoO window is 256 µops on Zen 4).

3. **Round constants / precomputed SIMD data** — `SimdPrecomputed` holds packed constants.
   Study memory access patterns, cache line utilization, whether fused operations
   reduce loads.

Read `~/zk-autoresearch/Plonky3/` Poseidon implementation for comparison patterns.

### B. Call permute_mut fewer times (WHIR structure)

The Merkle commitment path in `compress_layer()` is called per tree level:
- How many `permute_mut` calls per commitment? Is there redundant hashing?
- Merkle tree arity — could wider arity reduce tree depth and total hashes?
- Memory layout — are leaves laid out for cache-friendly compression?

Study `crates/whir/src/merkle.rs` and `crates/backend/symetric/src/merkle.rs`.

## Writable Files

| Target | Files |
|---|---|
| Poseidon permutation | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` |
| Poseidon SIMD kernel | `crates/backend/koala-bear/src/monty_31/x86_64_avx512/poseidon_helpers.rs` |
| WHIR Merkle | `crates/whir/src/merkle.rs` |
| WHIR commit | `crates/whir/src/commit.rs` |
| Symmetric/Merkle | `crates/backend/symetric/src/merkle.rs`, `permutation.rs` |

**Read-only:** air/, sub_protocols/, sumcheck/, field/, fiat-shamir/, lean_vm/,
monty_31/x86_64_avx512/packing.rs. Request scope expansion if needed.

**Off limits:** `leanMultisig-bench/benches/xmss_leaf.rs`, Cargo.toml profiles,
allocators, RUSTFLAGS, PGO — already explored in prior experiments.

## Three-Tier Gate

**Tier 1: Poseidon microbenchmark (~30s)** — pre-filter, not a gate.
Bench file: `leanMultisig-bench/benches/poseidon_permute.rs`.
Measures `permute_mut` on `[FPacking; 16]` via Criterion.
If local improvement <3%, abort — 25.9% share means <0.8% e2e, below 1% keep threshold.
Use `--skip-micro` for WHIR structural changes that don't touch `permute_mut`.

**Tier 2: Criterion e2e (~5 min)** — `xmss_leaf_1400sigs`.
Keep if >= 1.0% improvement with p < 0.01. This is the keep/discard decision.
Run: `bash eval_gate.sh` (runs Tier 1 + Tier 2 together).

**Tier 3: Production (~20 min)** — `fancy-aggregation` via `reproduce_prod.sh`.
Only on Tier 2 keeps. >2% = ship, 0-2% = marginal, rerun with RUNS=5.

**Microbench to aim, e2e gate to decide.**

## Multi-Iter Implementations

Complex changes may span 2-3 iterations:
- Iter N: implement + microbenchmark. Log `status=wip`, record `tier1_micro`.
- Iter N+1: refine based on data. Log `status=wip`.
- Iter N+2: run `eval_gate.sh`. Log final `keep`/`discard_wallclock`.

No Criterion gate until the implementation is complete.

## Correctness

Before every gate: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`
(runs `cargo test --release` on `mt-koala-bear` + `mt-whir`).

## Experiment Loop

1. Read `program.md` and `iters.tsv`.
2. Use Explore agents to read target code, inspiration repos, and profile data.
3. Form hypothesis. Validate with microbenchmark (Tier 1).
4. Implement. May span 2-3 iters with microbench refinement.
5. Gate: `bash eval_gate.sh`. Production: `bash reproduce_prod.sh` on keeps only.
6. Log to `iters.tsv`. Re-profile after every keep.

Search inspiration repos (`Plonky3/`, `jolt/`, `sp1/`) when stuck (3+ discards).

## Logging
```
iter	tier1_micro	tier2_criterion_pct	tier2_p	tier3_prod_pct	status	files_changed	rationale
```
Status: `keep`, `discard_micro`, `discard_wallclock`, `wip`, `infra_fail`

## Known Dead Ends (patterns from 78 prior iterations on other surfaces)

**Adding columns:** +46% from Merkle hashing cost increase. Do NOT add columns.
**Precompute-and-share:** cache thrashing beats redundant computation on Zen 4.
**ILP destruction:** serial dependencies in inner loops always hurt OoO engine.
**#[inline(always)] carpet bombing:** compiler already inlines small functions.
**Perf attribution ghosts:** FnMut::call_mut shows 12.7% but has 0% effect when eliminated.

No prior iterations on Poseidon SIMD or WHIR Merkle targets. This is a fresh surface.

## Rules
- Structural changes and protocol-level restructuring in scope
- Multi-iter blocks for complex work
- Correctness mandatory before every gate
- 12 consecutive Tier 2 discards → pause and report

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
