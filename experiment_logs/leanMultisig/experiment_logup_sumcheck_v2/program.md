# leanMultisig Logup + Sumcheck + AIR v2 — Experiment 4

## Role
You are an expert ZK protocol engineer with deep knowledge of sumcheck, GKR, lookup arguments,
and AIR constraint systems. You write high-performance Rust and understand AVX-512
microarchitecture on Zen 4.

**Hardware:** AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512, KVM virtualized.

## What this experiment is NOT

**Do NOT modify any of the following:**
- `~/zk-autoresearch/leanMultisig-bench/` — the bench crate is OFF LIMITS
- `Cargo.toml` build profiles (codegen-units, LTO, panic) — already explored
- Allocator selection (mimalloc, jemalloc) — already explored
- RUSTFLAGS or PGO — already explored
- Any file outside `~/zk-autoresearch/leanMultisig/crates/`

This experiment targets **source code optimizations only** in the leanMultisig codebase.

## The Call Chain

```
prove_execution.rs
  → prove_generic_logup (logup.rs)                    ← DATA PREP: ~5-8% e2e
      → finger_print_packed (inner kernel, 1000s of calls)
      → prove_gkr_quotient (quotient_computation.rs)  ← GKR SUMCHECK: ~10-13% e2e
          → sumcheck_prove_many_rounds (prove.rs)
              → SumcheckComputation (sc_computation.rs)
                  → ConstraintFolderPacked (air/)     ← DOMINANT COST IN SUMCHECK
                  → FnMut::call_mut closures           ← ~6% DISPATCH OVERHEAD
      → post-GKR column evaluations
  → prove_batched_air_sumcheck (air_sumcheck.rs)       ← ~15% e2e
      → AIR constraint evaluation (air/)
```

## Profiling Breakdown (2026-04-18, perf, 40K samples)

| Component | % e2e | Explored? | Notes |
|---|---|---|---|
| Merkle hashing (Poseidon1 permute_mut) | 21% | Barely | Column count is binding — can't add columns |
| AIR constraint eval (Air::eval + rounds) | 14.4% | Only inlining (0%) | **Primary target** — no algorithmic work tried |
| Iterator/closure dispatch (FnMut::call_mut) | ~6% | Never | **Fresh target** |
| GKR quotient sumcheck | 4.9% | Heavily (8 iters) | ILP bottleneck confirmed |
| Eq polynomial | 2.4% | Heavily (7 iters) | Hardware local optimum |
| WHIR product sumcheck | 2.2% | Lightly (2 iters) | **Underexplored** |
| Field packing (from_ext_slice) | 1.4% | Lightly (1 iter) | **Underexplored** |
| Rayon overhead | 1.7% | Explored | Nested parallelism hurts |
| Allocation | 1.1% | Explored | Addressed by mimalloc (bench-side) |

## The Metric
**Lower is better.** `xmss_leaf_1400sigs` e2e (~5.17s baseline pre-mimalloc).
Keep if: wall-clock improvement >= 1.0% with p < 0.01.
`[wallclock-only]` required for sub_protocols/ and air/ changes.
iai gate works for backend/sumcheck/ changes.

## Iteration Surface (priority order)

### 1. AIR constraint eval (14.4% e2e — 5 inlining attempts, zero algorithmic)

Previous experiments only tried `#[inline(always)]` on eval functions (0% delta, compiler
already inlining). The actual hot functions are:
- `Poseidon16Precompile::eval` — 8.03% self time, 77 constraints, degree 9
- `eval_2_full_rounds_16` — 3.03%, the Poseidon round function
- `eval_last_2_full_rounds_16` — 1.86%

**Unexplored directions:**
- **Constraint expression rewriting** — are there algebraic simplifications in the Poseidon
  constraint expressions that reduce multiplication count?
- **Shared subexpressions across constraints** — manual CSE if LLVM misses cross-constraint
  common terms
- **Round constant application** — can MDS matrix multiply or S-box application be restructured
  for better SIMD utilization?
- **Evaluation order** — does reordering constraint evaluation affect register pressure or
  cache behavior?

**Binding constraint:** Do NOT add columns. Iter 1 of experiment 3 showed +46% regression
from 64 extra columns — Merkle hashing cost dominates.

### 2. Iterator/closure dispatch (~6% e2e — zero attempts)

`FnMut::call_mut` appears multiple times in profiling (~5% total). These are compiler-generated
thunks for closures passed through generic APIs. Possible causes:
- Virtual dispatch through trait objects where monomorphization would be faster
- Closure captures that prevent inlining
- Generic API boundaries that introduce indirect calls

**Directions:**
- Identify which closures generate the dispatch overhead (perf with call graph)
- Replace trait object dispatch with monomorphized paths where possible
- Ensure hot closures are `#[inline(always)]` annotated at the call site
- Check if `dyn Fn` is used where generics would eliminate vtable

### 3. Product sumcheck (2.2% e2e — 2 trivial attempts)

Only loop interchange and chunk_size tuning tried. The delayed modular reduction pattern
(`compute_product_sumcheck_polynomial_base_ext_packed`) is already there. Unexplored:
- Is the delayed reduction optimal? Can the accumulation window be wider?
- Product tree structure — can the products be arranged for better ILP?
- Packed field utilization — are all SIMD lanes active?

### 4. Jolt extrapolation pattern (never attempted, ~3-8% estimated)

Jolt evaluates the sumcheck polynomial at fewer points and uses polynomial extrapolation.
For degree-9 Poseidon constraints: evaluate at 5 points, extrapolate to 10 → nearly halve
constraint evaluations. Complex (200+ lines), requires changes to `SumcheckComputation` trait.
Read `~/zk-autoresearch/jolt/`'s `mles_product_sum.rs` before attempting.

### 5. from_ext_slice (1.4% e2e — 1 attempt)

Packing overhead. Only one inlining attempt (regressed). Study the actual conversion
pattern — is the data layout causing unnecessary shuffles?

## Target Files (writable)

| Layer | Files |
|---|---|
| AIR constraints | `crates/backend/air/` — primary target |
| Logup | `crates/sub_protocols/src/logup.rs`, `air_sumcheck.rs`, `stacked_pcs.rs` |
| Caller | `crates/lean_prover/src/prove_execution.rs` |
| Sumcheck | `crates/backend/sumcheck/src/prove.rs`, `sc_computation.rs`, `quotient_computation.rs`, `product_computation.rs` |

**Saturated (avoid unless strong hypothesis):**
quintic_extension/ (inlining exhausted), eq_mle.rs (hardware local optimum)

**Read-only:** fiat-shamir/, field/, koala-bear/ (except quintic_extension), whir/,
sumcheck/verify.rs, all tests/

**OFF LIMITS:** `~/zk-autoresearch/leanMultisig-bench/`, Cargo.toml profiles, allocator config

## Inspiration Repos
- `~/zk-autoresearch/jolt/` — extrapolation kernels in `mles_product_sum.rs`
- `~/zk-autoresearch/Plonky3/` — sumcheck patterns, monty-31 AVX-512
- `~/zk-autoresearch/sp1/` — source readable

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` and `iters.tsv`.
2. **Profile first (iter 1 mandatory).** Use `perf record` or `cargo flamegraph`.
3. Read target files. Understand data flow before hypothesizing.
3b. *When stuck (3+ discards):* Search inspiration repos and papers for patterns.
4. Devise ONE targeted change. State hypothesis — what, why, expected signal.
5. Edit source files **in `~/zk-autoresearch/leanMultisig/crates/` ONLY**.
6. Correctness: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`
7. Commit: `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <description>"`
8. Gate: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_gate.sh`
9. KEEP → log, save baseline. DISCARD → revert, log.

## Logging — `iters.tsv`
```
iter	stage1_iai_delta	stage1_iai_decision	stage2_median_pct	stage2_p	revert_ab	base_hash	cand_hash	status	files_changed	rationale
```

## Known Dead Ends (68 iterations across experiments 1-3)

**DO NOT RETRY these — all conclusively failed:**
- eval_eq_basic structural changes: hardware local optimum, +7-9% wall-clock
- Vec alloc reuse (clear/extend): compiler optimizes collect() better (3 attempts, all regressed)
- Quintic inlining beyond 9 functions: I-cache pressure
- Rayon flattening/nesting changes: +8-11% from overhead/contention
- Precompute-and-share (batch MLE eval, deferred folding): +9-22% cache thrashing
- GKR quotient alpha fusion: destroys ILP (+9% wall-clock despite -1.9% iai)
- split_eq BasePacked routing: monomorphization instability (+11%)
- Degree-9→degree-3 Poseidon split: +46% from column count increase
- Closure caching as package vars: prevents Go-style inlining
- `#[inline(always)]` on AIR eval functions: compiler already inlining (5 attempts, 0%)
- Monomorphization trap: moving closures near sc_computation.rs changes anonymous type
  hashes, causing iai FAIL. Don't route different paths through separate closures there.

## Scope Rules
- Source code changes only. No build config, no bench crate.
- Structural changes (50-200 lines) allowed.
- Protocol-level restructuring in scope if motivated by hypothesis.
- Research papers valid input. Cross-boundary changes encouraged.
- ONE change per iteration. Correctness mandatory.

## Stop Criterion
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until manually stopped or stop criterion hit.
