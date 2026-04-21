# leanMultisig Logup + Sumcheck + AIR v2 — Experiment 4

## Role
You are an expert ZK protocol engineer with deep knowledge of sumcheck, GKR, lookup arguments,
and AIR constraint systems. You write high-performance Rust and understand AVX-512
microarchitecture on Zen 4.

**Hardware:** AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512, KVM virtualized.

## What this experiment is NOT

**Do NOT modify any of the following:**
- `~/zk-autoresearch/leanMultisig-bench/Cargo.toml` — no build profile or dependency changes
- `~/zk-autoresearch/leanMultisig-bench/benches/xmss_leaf.rs` — do not modify existing benchmarks
- `Cargo.toml` build profiles (codegen-units, LTO, panic) — already explored
- Allocator selection (mimalloc, jemalloc) — already explored
- RUSTFLAGS or PGO — already explored

**You MAY add new benchmark files** to `leanMultisig-bench/benches/` for diagnostic purposes
(e.g. `bench_air_eval.rs`, `bench_sumcheck_round.rs`). These are tools to validate hypotheses
locally before running the e2e gate — not gates themselves.

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

## Profiling Breakdown (2026-04-21, perf, post-mimalloc baseline)

| Component | % e2e | Explored? | Notes |
|---|---|---|---|
| Merkle hashing (Poseidon1 permute_mut) | 24.8% | Barely | Column count is binding — can't add columns |
| Rayon overhead (bridge_producer_consumer) | 6.8% | Explored | Nested parallelism hurts |
| AIR constraint eval (eval_2_full + eval_last_2 + assert_zero) | 6.7% | Only inlining (0%) | **Dropped from 14.4% pre-mimalloc** |
| Closure dispatch (Fn::call + FnMut::call_mut) | 4.0% | Never | Verify if real or attribution noise |
| GKR quotient sumcheck | 4.1% | Heavily (8 iters) | ILP bottleneck confirmed |
| Eq polynomial | 2.8% | Heavily (7 iters) | Hardware local optimum |
| Product sumcheck | 2.3% | Lightly (2 iters) | Low ceiling (0.7% e2e max) |
| Kernel/OS | ~9% | N/A | KVM overhead |
| memmove | 0.9% | N/A | |

## Baseline
Branch: `feat/mimalloc-allocator-clean` HEAD (includes mimalloc + codegen-units=1).
Baseline runtime: ~3.9s on Criterion `xmss_leaf_1400sigs`.
Profiling breakdown above is current (post-mimalloc). Re-profile after every keep.

## The Metric
**Lower is better.** `xmss_leaf_1400sigs` e2e (~3.9s baseline post-mimalloc).
Keep if: wall-clock improvement >= 1.0% with p < 0.01.
`[wallclock-only]` required for sub_protocols/ and air/ changes.
iai gate works for backend/sumcheck/ changes.

## Iteration Surface (priority order)

### 1. Jolt extrapolation pattern (never attempted, cuts across multiple categories)

Jolt evaluates the sumcheck polynomial at fewer points and uses polynomial extrapolation.
For degree-9 Poseidon constraints: evaluate at 5 points, extrapolate to 10 → nearly halve
constraint evaluations. This cuts across AIR eval (6.7%), GKR quotient (4.1%), and product
sumcheck (2.3%) simultaneously — the compounding effect is why this is #1 despite complexity.

Complex (200+ lines), requires changes to `SumcheckComputation` trait.
Read `~/zk-autoresearch/jolt/`'s `mles_product_sum.rs` thoroughly before attempting.

**This may span 2-3 iterations** (implement, debug, optimize). That's acceptable for a
protocol-level change of this magnitude — don't try to cram it into one iter.

### 2. Rayon overhead (6.8% e2e — investigate, not add parallelism)

Grew from 1.7% to 6.8% post-mimalloc (now visible without allocation noise).
`bridge_producer_consumer` appears 5+ times. Previous experiments tried ADDING parallelism
(nested par_iter, parallel sessions) and all regressed. The unexplored angle is REDUCING
overhead — task granularity, work distribution, chunk sizing to minimize spawning cost.
**Spend 1 iter profiling which bridge_producer_consumer instances dominate before optimizing.**

### 3. AIR constraint eval (6.7% e2e — ceiling now ~1-2% e2e)

Dropped from 14.4% pre-mimalloc. Still writable, still unexplored algorithmically. Hot fns:
- `eval_2_full_rounds_16` — 4.0%
- `eval_last_2_full_rounds_16` — 1.6%
- `ConstraintFolderPacked::assert_zero` — 1.1%

**Unexplored directions:**
- Constraint expression rewriting (algebraic simplifications)
- Shared subexpressions across constraints (manual CSE)
- Round constant / MDS restructuring for SIMD

**Binding constraint:** Do NOT add columns (+46% regression from 64 extra columns).

### 4. Closure dispatch (4.0% e2e — verify first)

`Fn::call` (3.0%) + `FnMut::call_mut` (1.0%). May be attribution noise or may overlap with
AIR eval. **1 iter to verify with call graph before treating as separate target.**

### 5. Product sumcheck (2.3% e2e — low ceiling)

Even 30% local improvement = 0.7% e2e. Only attempt if higher targets exhaust.

### Not targeting
- **Poseidon permute_mut (24.8%)** — in read-only mt_koala_bear. Largest surface but requires
  AVX-512 assembly optimization, different class of work. Could open if willing.
- **from_ext_slice** — dropped below 0.3% threshold post-mimalloc. Not worth an iteration.

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
2. **Profile after every keep.** Profiling breakdown in this file is current. Use:
   ```bash
   cd ~/zk-autoresearch/leanMultisig-bench
   perf record -F 997 -g --call-graph=fp -o /tmp/perf_exp4.data -- \
       target/release/deps/xmss_leaf-* --bench xmss_leaf_1400sigs --profile-time 20
   perf report -i /tmp/perf_exp4.data --no-children --sort=symbol --stdio | head -40
   ```
   Profile again after every keep.
3. Read target files. Understand data flow before hypothesizing.
3b. *When stuck (3+ discards):* Search inspiration repos and papers for patterns.
4. Devise ONE targeted change. State hypothesis — what, why, expected signal.
4b. *Optional diagnostic:* Before burning a full e2e gate cycle, validate your hypothesis
    locally with a targeted microbenchmark (Criterion in leanMultisig-bench or a quick
    `cargo test --release` timing). If the local improvement is <5% within the target
    function, it won't clear the 1.0% e2e threshold — skip the gate and try a different idea.
    **Microbench to aim, e2e gate to decide.**
5. Edit source files **in `~/zk-autoresearch/leanMultisig/crates/` ONLY**.
6. Correctness: `cargo test --release` in leanMultisig, THEN `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`. Both must pass before committing.
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
