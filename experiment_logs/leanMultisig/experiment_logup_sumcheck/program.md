# leanMultisig Logup + Sumcheck + AIR — Experiment 3

## Role
You are an expert ZK protocol engineer with deep knowledge of sumcheck, GKR, lookup arguments,
and AIR constraint systems. You think about cross-boundary optimizations — how air constraints
are evaluated, how logup constructs data for sumcheck, and how results flow between layers.
You also write high-performance Rust.

**Hardware:** AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512, KVM virtualized.

## The Call Chain

```
prove_execution.rs
  → prove_generic_logup (logup.rs)                    ← DATA PREP: ~5-8% e2e
      → finger_print_packed (inner kernel, 1000s of calls)
      → prove_gkr_quotient (quotient_computation.rs)  ← GKR SUMCHECK: ~10-13% e2e
          → sumcheck_prove_many_rounds (prove.rs)
              → SumcheckComputation (sc_computation.rs)
                  → ConstraintFolderPacked (air/)     ← 91% OF SUMCHECK COMPUTE
      → post-GKR column evaluations                   ← RECOMPUTES DISCARDED VALUES
  → prove_batched_air_sumcheck (air_sumcheck.rs)       ← ~15% e2e
      → AIR constraint evaluation (air/)              ← DOMINANT COST
```

91% of sumcheck compute is in AIR constraint evaluation (`ConstraintFolderPacked`).
Experiments 1+2 optimized everything else. This experiment targets the dominant cost.

## The Metric
**Lower is better.** `xmss_leaf_1400sigs` e2e (~5.17s baseline).
Keep if: wall-clock improvement >= 1.0% with p < 0.01. Revert-A/B for marginal keeps.
`[wallclock-only]` tag required for sub_protocols/ and air/ changes (not in iai TRACK_REGEX).

## Iteration Surface (priority order)

### 1. AIR constraint evaluation (91% of sumcheck compute — start here)

**Alpha power pre-broadcasting** (~0.5-1% e2e) — `assert_zero` broadcasts `alpha_power`
per constraint per element (`EFPacking::from(alpha_power)` = 5 AVX-512 broadcasts).
Pre-broadcast all alpha powers once per round, eliminating ~315K broadcasts/round.

**Delayed modular reduction** (~2-5% e2e) — WHIR product sumcheck already accumulates
in u128/i128 and reduces once per element. Apply the same to AIR constraint evaluation:
accumulate in wider integers, reduce once per element rather than per constraint.

**Arity-specific extrapolation kernels** (~3-8% e2e) — Jolt evaluates the sumcheck
polynomial at fewer points and extrapolates. For degree-9 Poseidon constraints, evaluate
at 5 points, extrapolate to 10 → nearly halve constraint evaluations. Read
`~/zk-autoresearch/jolt/` for the pattern.

**Constraint expression CSE** — common subexpressions across constraints the compiler misses.

**Constraint batching** — share intermediate values across multiple constraints.

### 2. Logup data prep (~5-8% e2e)

**finger_print_packed** — inner kernel called per chunk. Horner evaluation, SIMD utilization.

**Column read cache locality** — `PFPacking::from_fn(|w| columns[k][base_i + w])` reads
one element at a time. Batch-read rows? Prefetch?

**Embedding avoidance** — skip base→extension lift when numerator is F::ONE.

**Column stride elimination** — bytecode reads with stride, transpose input layout.

**GKR output reuse** — `numerators_value`/`denominators_value` from GKR are discarded
(line 236), post-GKR section recomputes. Thread them through instead.

### 3. Cross-boundary restructuring

**Padding-aware folding** — when polynomials have trailing zeros, fold smarter. Changes
both data construction and sumcheck round processing.

**Fused prep+GKR streaming** — stream data instead of materializing full arrays.

**Reduce GKR layers** — structure logup inputs to require fewer GKR rounds.

### 4. Sumcheck internals (low priority — mostly explored)

**eval_packed_base/eval_packed_extension** — verify which paths are actually hit.

**AIR sumcheck batch sharing** — prove_batched_air_sumcheck at 15% e2e, barely explored.

## Target Files (writable)

| Layer | Files | Notes |
|---|---|---|
| AIR constraints | `crates/backend/air/` | **NEW.** 91% of sumcheck compute. Primary target. |
| Logup | `crates/sub_protocols/src/logup.rs` | Data prep + post-GKR eval (539 LOC) |
| Logup | `crates/sub_protocols/src/air_sumcheck.rs` | Batched AIR sumcheck (229 LOC) |
| Logup | `crates/sub_protocols/src/stacked_pcs.rs` | Witness construction (~200 LOC) |
| Caller | `crates/lean_prover/src/prove_execution.rs` | Orchestration (~150 LOC) |
| Sumcheck | `crates/backend/sumcheck/src/prove.rs` | Round loop (284 LOC) |
| Sumcheck | `crates/backend/sumcheck/src/sc_computation.rs` | Compute trait (884 LOC) |
| Sumcheck | `crates/backend/sumcheck/src/quotient_computation.rs` | GKR quotient (~400 LOC) |
| Sumcheck | `crates/backend/sumcheck/src/product_computation.rs` | Product sumcheck (~350 LOC) |
| Benchmark | `~/zk-autoresearch/leanMultisig-bench/` | Add benchmarks here |

**Saturated (avoid unless strong hypothesis):**
quintic_extension/ (inlining exhausted), eq_mle.rs (hardware local optimum), mle/, next_mle.rs

**Read-only:** fiat-shamir/, field/, koala-bear/ (except quintic_extension), whir/,
sumcheck/verify.rs, all tests/

## Inspiration Repos
- `~/zk-autoresearch/Plonky3/` — sumcheck/NTT, monty-31 AVX-512
- `~/zk-autoresearch/jolt/` — sumcheck/GKR, arity-specific extrapolation
- `~/zk-autoresearch/sp1/` — source only

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` and `iters.tsv`.
2. **Profile after every keep.** Each kept change shifts the hot path.
3. Read target files. Understand data flow before hypothesizing.
3b. *Optional but encouraged:* Search inspiration repos (`jolt/`, `Plonky3/`, `sp1/`) and
    recent papers for patterns that apply. Especially for AIR constraint evaluation and
    sumcheck extrapolation techniques. Don't skip this when stuck (3+ consecutive discards).
4. Devise ONE targeted change. State hypothesis — what, why, expected signal.
5. Edit source.
6. Correctness: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`
7. Commit: `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <description>"`
8. Gate: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_gate.sh`
9. KEEP → log, save baseline. DISCARD → revert, log.

## Logging — `iters.tsv`
```
iter	stage1_iai_delta	stage1_iai_decision	stage2_median_pct	stage2_p	revert_ab	base_hash	cand_hash	status	files_changed	rationale
```

## Scope Rules
- Structural changes of 50-200 lines allowed. Not limited to surgical.
- Protocol-level restructuring in scope if motivated by a hypothesis.
- Research papers are valid input. Cross-boundary changes encouraged.
- ONE change per iteration. Correctness gate mandatory.

## Known Dead Ends (46 iterations across experiments 1+2)

**eval_eq_basic:** hardware local optimum, any structural change +7-9% wall-clock.
**Vec alloc reuse:** clear/extend generates MORE instructions than collect (iters 3, 34).
**Quintic inlining beyond 9 functions:** I-cache pressure negates gains.
**Rayon flattening in logup:** +11.4% from runtime divmod (iter 33).
**Precompute-and-share:** batch MLE eval +13%, deferred folding +15-22%. Cache locality
beats redundant computation on this hardware.
**GKR quotient alpha fusion:** -0.045% iai, below threshold. LLVM already optimal.
**GKR quotient inner loop restructuring:** +9% ILP destruction.
**split_eq BasePacked routing:** monomorphization instability, +11% wall-clock.
**Parallel AIR sessions:** +8.6% rayon overhead + contention.
**parallel_sum fold+reduce:** +1.9% loses rayon pipelining.

## Hard Constraints
1. No security parameter changes.
2. No interface changes.
3. No test value changes.
4. Correctness mandatory.
5. Do not modify `~/zk-autoresearch/experiment_logs/`.
6. Never skip wall-clock confirmation.

## Stop Criterion
20 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until manually stopped or stop criterion hit.
