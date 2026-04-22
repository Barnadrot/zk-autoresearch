# leanMultisig — Experiment 6: Allocation Reduction

## Role
Expert Rust systems programmer. Heap allocation profiling, arena patterns,
Rayon-parallel memory layout, DHAT-guided optimization.

**Hardware:** AMD EPYC Genoa (Zen 4), c7a.2xlarge, 16GB RAM, AVX-512, KVM.
**Baseline:** `1ad5fe25` (origin/main, 2026-04-22), system malloc (glibc). ~4.49s Criterion.
**Branch:** `exp6_alloc_reduction` on `myfork`.

## Why this experiment

PR #200 adds mimalloc: **-25% Criterion / -4% production on AWS**, but **+3.6% on
Hetzner bare metal** (64GB). Can't merge. The signal says allocation overhead is massive —
mimalloc papers over it with thread-local heaps, but the right fix is fewer allocations.

Source-code allocation reduction is hardware-agnostic: fewer allocs helps on every machine,
every allocator, every RAM size. It either closes the gap (making mimalloc unnecessary) or
compounds with mimalloc (making the PR mergeable because the remaining alloc pressure is
low enough that mimalloc doesn't regress on Hetzner).

## What the -25% tells us

The -25% Criterion result is amplified (tight-loop re-invocation keeps mimalloc's thread-local
heaps warm). Production shows -4%. But even -4% from *just swapping malloc* means the proving
pipeline is doing a lot of allocation work that doesn't need to happen. DHAT profiling will
show exactly where.

## Approach

**Step 1: Profile allocation sites with DHAT.**
```bash
cd ~/zk-autoresearch/leanMultisig-bench
valgrind --tool=dhat --dhat-out-file=/tmp/dhat.out \
    target/release/deps/xmss_leaf-* --bench xmss_leaf_1400sigs --profile-time 5
```
DHAT reports: allocation count, total bytes, max live bytes, per call site.
Sort by total bytes allocated — those are the targets.

**Step 1b: Read inspiration repos for allocation patterns (once, during iter 1).**
Check how Plonky3, SP1, and Jolt handle allocation in their parallel proving pipelines:
- `~/zk-autoresearch/Plonky3/` — Merkle tree buffer management, sumcheck allocation
- `~/zk-autoresearch/sp1/` — prover memory patterns
- `~/zk-autoresearch/jolt/` — commitment allocation strategy
Look for: pre-allocated tree buffers, arena patterns compatible with Rayon, in-place
Merkle construction. Build a pattern library, then apply DHAT-guided.

**Step 2: Eliminate or reduce the top allocation sites.**
For each site, one of:
- Replace `collect()` with in-place iteration (if downstream only iterates)
- Pre-size buffers outside hot loops and reuse across iterations
- Replace `Vec<T>` with stack arrays where size is known at compile time
- Use `SmallVec` or inline storage for small, bounded collections
- Adopt arena/buffer patterns found in inspiration repos

**Step 3: Gate on Criterion (AWS). Validate keeps don't regress on Hetzner before shipping.**

## Prior allocation work (5 failed attempts — understand why)

| Iter | File | What | Result | Why it failed |
|---|---|---|---|---|
| exp3/6 | sc_computation.rs | Vec→slice+pre-alloc buf | +1.27% | Indexed fill worse than collect |
| exp3/9 | sc_computation.rs | Reuse pre-allocated buffers | -0.01% | Allocator caching already optimal |
| exp3/10 | sc_computation.rs | Zip-based slice reuse | -0.01% | No measurable effect |
| exp3/14 | sc_computation.rs, air_sumcheck.rs | Eliminate per-z-point Vec allocs | +13% | air_sumcheck restructuring broke ILP |
| exp4/5 | sc_computation.rs | Reuse point buffer (Vec→&[IF]) | 0% iai | Not visible in single-threaded valgrind |

**Pattern: all 5 targeted sumcheck inner loops blindly.** None used DHAT to find the actual
heaviest allocators. The compiler already optimizes `collect()` in tight loops — the real
allocation pressure is likely elsewhere (Merkle tree building, logup data prep, column
materialization). **Profile first, then target.**

## The Call Chain (allocation-relevant)

```
prove_execution.rs
  → prove_generic_logup (logup.rs)              ← data prep: Vec allocations for fingerprinting
    → finger_print_packed (inner kernel)
  → prove_batched_air_sumcheck (air_sumcheck.rs) ← sumcheck rounds: per-round buffers
    → SumcheckComputation (sc_computation.rs)
  → stacked_pcs (WHIR commitment)
    → MerkleTree::new (merkle.rs)               ← tree construction: node Vec per level
    → polynomial evaluations                    ← extension field Vec allocations
```

DHAT will tell us which of these dominates. Don't guess.

## Writable Files

Broad scope — allocation happens across the pipeline. Writable:

| Layer | Files |
|---|---|
| Proving pipeline | `crates/lean_prover/src/prove_execution.rs` |
| Logup | `crates/sub_protocols/src/logup.rs`, `air_sumcheck.rs` |
| Sumcheck | `crates/backend/sumcheck/src/prove.rs`, `sc_computation.rs` |
| WHIR | `crates/whir/src/merkle.rs`, `commit.rs` |
| Merkle | `crates/backend/symetric/src/merkle.rs` |
| GKR | `crates/sub_protocols/src/quotient_gkr/` |

**Read-only:** field arithmetic, Poseidon internals, koala-bear packed ops, AIR definitions.
**Off limits:** Cargo.toml profiles, allocators, RUSTFLAGS, bench crate config — already explored.

## Gate

Same two-tier system as exp5, minus the microbenchmark pre-filter (allocation changes
affect the whole pipeline, not one function):

**Tier 1: Criterion (~5 min)** — `xmss_leaf_1400sigs` via shared `eval_paired.sh`.
Keep if >= 1.0%, p < 0.01.

**Tier 2: Production (~20 min)** — `fancy-aggregation` via `reproduce_prod.sh`.
Only on keeps. >2% = ship.

No microbenchmark tier — allocation reduction is diffuse, not function-local.
No iai tier — allocation changes are invisible to single-threaded valgrind (exp4/iter 5 confirmed).

## Experiment Loop

1. Read `program.md` and `iters.tsv`.
2. **Iter 1 must be DHAT profiling + inspiration repo survey.** Run DHAT, log top-10
   allocation sites in rationale. Use Explore agents to read Plonky3/SP1/Jolt allocation
   patterns. No code change, `status=profile`.
3. Target the heaviest site. Apply fix patterns from DHAT + inspiration survey.
4. Correctness: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`
5. Gate: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_paired.sh`
6. Log to `iters.tsv`. Re-profile (DHAT) after every keep — allocation landscape shifts.

## Logging
```
iter	tier1_criterion_pct	tier1_p	tier2_prod_pct	status	files_changed	rationale
```
Status: `keep`, `discard_wallclock`, `profile`, `infra_fail`

## Known Dead Ends

**Sumcheck inner-loop alloc reduction:** 5 attempts, 0 keeps. Compiler already optimizes
`collect()` in tight loops. Don't retry without DHAT evidence showing these are top sites.
**jemalloc:** +74.8% regression. Worse than glibc for this workload.
**mimalloc as global allocator:** -25% AWS, +3.6% Hetzner. Not portable. (PR #200 open.)
**Precompute-and-share patterns:** cache thrashing beats redundant computation on Zen 4.

## Rules
- DHAT-guided only. No blind allocation changes.
- Source-code changes only. No allocator swaps, no build config.
- Correctness mandatory before every gate.
- 12 consecutive discards → pause and report.

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
