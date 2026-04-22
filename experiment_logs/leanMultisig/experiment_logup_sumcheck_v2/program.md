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
- Allocator selection (mimalloc, jemalloc) — already explored, AWS-only win, regresses on bare metal
- RUSTFLAGS or PGO — already explored

**You MAY add new benchmark files** to `leanMultisig-bench/benches/` for diagnostic purposes
(e.g. `bench_air_eval.rs`, `bench_sumcheck_round.rs`). These are tools to validate hypotheses
locally before running the e2e gate — not gates themselves.

This experiment targets the leanMultisig codebase. Both micro-optimizations and protocol-level
restructuring are in scope — read inspiration repos and papers before defaulting to profiling.

## The Call Chain

```
prove_execution.rs
  → prove_generic_logup (logup.rs)                    ← DATA PREP: ~5-8% e2e
      → finger_print_packed (inner kernel, 1000s of calls)
      → prove_gkr_quotient                             ← GKR SUMCHECK: ~5.9% e2e
          → quotient_gkr/sumcheck_utils (REFACTORED)
              → fold_and_compute_round_packed, compute_round_packed
          → sumcheck_prove_many_rounds (prove.rs)
              → SumcheckComputation (sc_computation.rs)
                  → ConstraintFolderPacked (air/)
                  → FnMut::call_mut closures            ← ~6.5% DISPATCH OVERHEAD
      → post-GKR column evaluations
  → prove_batched_air_sumcheck (air_sumcheck.rs)       ← ~5.5% AIR eval (excl. Poseidon permute)
      → AIR constraint evaluation (air/)
```

## Profiling Breakdown (2026-04-21, perf fp, myfork/main HEAD, 279K samples)

| Component | % e2e | Explored? | Notes |
|---|---|---|---|
| Poseidon permute_mut (3 variants) | 25.6% | Barely | Column count is binding — can't add columns |
| Closure dispatch (FnMut::call_mut) | ~6.5% | Never | Consistent across profiles — confirmed real |
| GKR quotient sumcheck | ~5.9% | 8 iters on OLD code | Refactored to quotient_gkr/sumcheck_utils — new structure may have different optimization opportunities |
| AIR constraint eval | ~5.5% | Only inlining (0%) | eval_2_full_rounds 2.55%, Poseidon16::eval 2.04%, eval_last_2 0.95% |
| Product computation | ~2.8% | Lightly (2 iters) | Low ceiling |
| Rayon overhead | 2.7% | Explored | Nested parallelism hurts |
| Eq polynomial | ~2.3% | Heavily (7 iters) | Hardware local optimum |
| from_ext_slice | 1.23% | Lightly (1 iter) | |
| Kernel/OS | ~8.7% | N/A | KVM overhead |
| ConstraintFolderPacked::assert_zero | 0.64% | Explored | |
| memmove_avx512 | 0.65% | N/A | |

## Baseline
Branch: `myfork/main` HEAD (no mimalloc — mimalloc regresses on bare metal, AWS-only win).
Baseline runtime: ~5.17s on Criterion `xmss_leaf_1400sigs`.
Re-profile after every keep.

## The Metric
**Lower is better.** `xmss_leaf_1400sigs` e2e (~5.17s baseline).
Keep if: wall-clock improvement >= 1.0% with p < 0.01.
`[wallclock-only]` required for sub_protocols/ and air/ changes.
iai gate works for backend/sumcheck/ changes.

## Iteration Surface (priority order)

### 1. Jolt extrapolation pattern (never attempted, cuts across multiple categories)

Jolt evaluates the sumcheck polynomial at fewer points and uses polynomial extrapolation.
For degree-9 Poseidon constraints: evaluate at 5 points, extrapolate to 10 → nearly halve
constraint evaluations. This cuts across AIR eval (~5.5%), GKR quotient (~5.9%), and product
sumcheck (~2.8%) simultaneously — the compounding effect is why this is #1 despite complexity.

Complex (200+ lines), requires changes to `SumcheckComputation` trait.
Read `~/zk-autoresearch/jolt/`'s `mles_product_sum.rs` thoroughly before attempting.

**This may span 2-3 iterations** (implement, debug, optimize). That's acceptable for a
protocol-level change of this magnitude — don't try to cram it into one iter.

### 2. Closure dispatch (~6.5% e2e — confirmed real, never attempted)

`FnMut::call_mut` consistent at ~6.5% across both pre- and post-mimalloc profiles — this is
real overhead, not attribution noise. Spread across sumcheck/GKR call sites. Investigate
which closures are the worst offenders and whether monomorphization or inlining can eliminate
the dispatch. May overlap with AIR eval — establish this with call-graph profiling first.

### 3. AIR constraint eval (~5.5% e2e — only inlining tried, zero algorithmic)

Hot fns:
- `eval_2_full_rounds_16` — 2.55%
- `Poseidon16Precompile::eval` — 2.04%
- `eval_last_2_full_rounds_16` — 0.95%
- `ConstraintFolderPacked::assert_zero` — 0.64%

**Unexplored directions:**
- Constraint expression rewriting (algebraic simplifications)
- Shared subexpressions across constraints (manual CSE)
- Round constant / MDS restructuring for SIMD

**Binding constraint:** Do NOT add columns (+46% regression from 64 extra columns).

### 4. GKR quotient (~5.9% e2e — refactored, re-investigate)

Emile refactored quotient code into `quotient_gkr/sumcheck_utils` with new function names
(`fold_and_compute_round_packed`, `compute_round_packed`). Prior experiments explored the
old structure (8 iters, 0 keeps). The refactored code may have different optimization
opportunities — re-read before assuming prior dead ends apply.

### 5. from_ext_slice (1.23% e2e)

Packing overhead. One inlining attempt regressed. Study the actual conversion pattern.

### 6. Rayon overhead (2.7% e2e — low priority)

Previous experiments tried adding parallelism (all regressed). Reducing overhead (task
granularity, chunk sizing) is the unexplored angle but ceiling is low at 2.7%.

### 7. Product sumcheck (~2.8% e2e — low ceiling)

Even 30% local improvement = 0.8% e2e. Only attempt if higher targets exhaust.

### Not targeting
- **Poseidon permute_mut (25.6%)** — in read-only mt_koala_bear. Could open if willing.

## Target Files (writable)

| Layer | Files |
|---|---|
| AIR constraints | `crates/backend/air/` — primary target |
| Logup | `crates/sub_protocols/src/logup.rs`, `air_sumcheck.rs`, `stacked_pcs.rs` |
| Logup (new) | `crates/sub_protocols/src/quotient_gkr/` — refactored GKR quotient |
| Caller | `crates/lean_prover/src/prove_execution.rs` |
| Sumcheck | `crates/backend/sumcheck/src/prove.rs`, `sc_computation.rs`, `product_computation.rs` |

**Saturated (avoid unless strong hypothesis):**
quintic_extension/ (inlining exhausted), eq_mle.rs (hardware local optimum)

**Read-only:** fiat-shamir/, field/, koala-bear/ (except quintic_extension), whir/,
sumcheck/verify.rs, all tests/

**OFF LIMITS:** see "What this experiment is NOT" section above

## Inspiration Repos & Papers
- `~/zk-autoresearch/jolt/` — extrapolation kernels in `mles_product_sum.rs`
- `~/zk-autoresearch/Plonky3/` — sumcheck patterns, monty-31 AVX-512
- `~/zk-autoresearch/sp1/` — source readable
- Packed sumcheck (ePrint 2025/719) — 2.78x reported, major protocol restructuring
- Search for recent papers on sumcheck, GKR, constraint evaluation optimization

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
3. Read target files. Understand data flow before hypothesizing.
3b. *Optional but encouraged:* Search inspiration repos (`jolt/`, `Plonky3/`, `sp1/`) and
    recent papers for patterns that apply. Don't skip this when stuck (3+ consecutive discards).
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
- Closure caching as package vars: prevents compiler inlining
- `#[inline(always)]` on AIR eval functions: compiler already inlining (5 attempts, 0%)
- Monomorphization trap: moving closures near sc_computation.rs changes anonymous type
  hashes, causing iai FAIL. Don't route different paths through separate closures there.
- Allocator changes (mimalloc, jemalloc): mimalloc -24% on AWS but +3.6% on bare metal
  Hetzner. Not hardware-agnostic. Separate experiment needed.

## Scope Rules
- Source code changes only. No build config, no bench crate modifications (except adding new diagnostic benchmarks).
- Structural changes (50-200 lines) allowed.
- Protocol-level restructuring in scope if motivated by hypothesis.
- Research papers valid input. Cross-boundary changes encouraged.
- ONE change per iteration. Correctness mandatory.

## Stop Criterion
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until manually stopped or stop criterion hit.
