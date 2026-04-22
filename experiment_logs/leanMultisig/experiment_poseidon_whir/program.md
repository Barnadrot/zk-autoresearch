# leanMultisig — Experiment 5: Poseidon + WHIR

## Role
Expert ZK protocol engineer and SIMD performance engineer. Poseidon hash optimization,
Merkle tree commitment structures, AVX-512 instruction scheduling on Zen 4.

**Hardware:** AMD EPYC Genoa (Zen 4), c7a.2xlarge, AVX-512, KVM.
**Baseline:** `myfork/main` HEAD + degree-split. ~4.49s Criterion, ~50s production.

## Why this target

Production profile (fancy-aggregation, post degree-split):

| Category | % e2e |
|---|---|
| **Poseidon permute_mut** | **25.9%** |
| AIR constraint eval | 10.3% |
| FnMut dispatch (attribution) | 12.7% |
| Kernel/OS | 10.2% |
| Everything else | < 3.5% each |

26% in one function. Everything else is under 3.5% individually — even a 20% local
improvement on any other target yields <0.7% production. Below gate threshold.

## Two angles on 26%

### A. Make permute_mut faster (SIMD, instruction scheduling)

`Poseidon1KoalaBear16::permute_mut` — the Poseidon permutation for WHIR Merkle commitments.
Three monomorphizations (23.7% + 1.2% + 1.0%). Study:

- MDS circulant multiply (`mds_circ_16`) — Karatsuba convolution, ~72 PF muls
- S-box (cube: `x * x * x`) — instruction scheduling across cube + MDS
- Round constant addition — memory access pattern for precomputed constants
- Read `~/zk-autoresearch/Plonky3/` Poseidon implementation for comparison patterns

### B. Call permute_mut fewer times (protocol, WHIR structure)

The WHIR commitment path constructs Merkle trees. Study:
- How many permute_mut calls per commitment — is there redundant hashing?
- Merkle tree structure — batching, parallelism, memory layout
- `crates/whir/` commitment code — how trees are built and traversed

## Off Limits
- `leanMultisig-bench/Cargo.toml` and `benches/xmss_leaf.rs` — don't modify existing
- Cargo.toml profiles, allocators, RUSTFLAGS, PGO — already explored
- You MAY add new diagnostic bench files to `leanMultisig-bench/benches/`

## Writable Files

| Target | Files |
|---|---|
| Poseidon | `crates/backend/koala-bear/src/poseidon*/` |
| WHIR | `crates/whir/` |

**Read-only (request scope expansion if needed):**
Everything else — air/, sub_protocols/, sumcheck/, field/, fiat-shamir/

## Three-Tier Gate

**Tier 1: Microbenchmark (seconds)** — iterate on implementation variants.
Write a `bench_poseidon_permute.rs` as your first action.

**Tier 2: Criterion (~5 min)** — `xmss_leaf_1400sigs`. Keep if >= 1.0%, p < 0.01.

**Tier 3: Production (~20 min)** — `fancy-aggregation` via `reproduce_prod.sh`.
Only on Tier 2 keeps. Ship/no-ship decision.

**Microbench to aim, e2e gate to decide.**

## Multi-Iter Implementations

Complex changes may span 2-3 iterations:
- Iter N: implement + microbenchmark
- Iter N+1: refine based on microbench data
- Iter N+2: Criterion gate → if pass → production gate

## Inspiration
- `~/zk-autoresearch/Plonky3/` — Poseidon permutation, MDS optimization, Merkle trees
- `~/zk-autoresearch/jolt/` — commitment patterns
- `~/zk-autoresearch/sp1/` — source readable

## Experiment Loop

1. Read `program.md` and `iters.tsv`.
2. Use Sonnet Explore agents for code reading and profiling analysis.
3. Form hypothesis. Validate with microbenchmark (Tier 1).
3b. Search inspiration repos and papers when stuck (3+ discards).
4. Implement (may span 2-3 iters with microbench refinement).
5. Criterion gate (Tier 2): `eval_gate.sh`.
6. Production gate (Tier 3): `reproduce_prod.sh`. Only on keeps.
7. Log to `iters.tsv`.

Read `shared/report/AGENT_PRACTICES.md` for operational guidelines.

## Logging
```
iter	tier1_micro	tier2_criterion_pct	tier2_p	tier3_prod_pct	status	files_changed	rationale
```

## Known Dead Ends (78 prior iterations — different surfaces, but patterns apply)

**Perf attribution ghosts:** Fn::call, FnMut::call_mut, try_map — 0% effect when eliminated.
**Adding columns:** +46% from Merkle hashing cost increase. Do NOT add columns.
**Precompute-and-share:** cache thrashing beats redundant computation on Zen 4.
**ILP destruction:** serial dependencies in inner loops always hurt OoO engine.
**Allocators:** mimalloc -24% AWS, +3.6% bare metal. Not hardware-agnostic.
**#[inline(always)] carpet bombing:** compiler already inlines small functions.

## Rules
- Protocol-level restructuring and papers in scope
- Structural changes allowed, multi-iter blocks for complex work
- Correctness mandatory (`cargo test --release` + `correctness.sh`)
- 12 consecutive Tier 2 discards → pause and report

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
