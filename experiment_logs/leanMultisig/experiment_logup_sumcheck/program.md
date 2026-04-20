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

**Profiled 2026-04-18** (perf, 40K samples). Actual e2e breakdown:
- Merkle hashing (Poseidon1 permute_mut): **21%** — 3 monomorphizations, commitment layer
- AIR constraint eval (Air::eval + rounds): **14.4%** — Poseidon16::eval 8%, round fns 5%
- Iterator/closure dispatch: **~6%** — FnMut::call_mut, Drain, Map::fold
- GKR quotient sumcheck: **4.9%**
- Eq polynomial: **2.4%**
- WHIR product sumcheck: **2.2%**
- Rayon overhead: **1.7%**
- Field packing: **1.4%**
- AIR constraint folder (assert_zero): **1.2%** — much smaller than estimated
- Allocation: **1.1%**

Note: the "91% of sumcheck compute" from experiment 2 was instruction mix within the kernel,
not e2e. Merkle hashing at 21% was not even on the radar.

## The Metric
**Lower is better.** `xmss_leaf_1400sigs` e2e (~5.17s baseline).
Keep if: wall-clock improvement >= 1.0% with p < 0.01. Revert-A/B for marginal keeps.
`[wallclock-only]` tag required for sub_protocols/ and air/ changes (not in iai TRACK_REGEX).

## Iteration Surface (priority order — based on profiling)

### 1. AIR constraint eval (14.4% e2e — largest writable target)

`Poseidon16Precompile::eval` alone is 8%. The constraint expressions themselves dominate,
not the folder. Study how Poseidon16 Air::eval computes its 77 constraints — the round
function calls (`eval_2_full_rounds_16` at 3%, `eval_last_2_full_rounds` at 1.9%) are the
actual hot functions.

**Arity-specific extrapolation** (highest impact, complex) — Jolt evaluates at fewer
points and extrapolates. For degree-9 Poseidon, evaluate at 5 points, extrapolate to 10 →
nearly halve constraint evaluations. 200+ line change. Read `~/zk-autoresearch/jolt/`'s
`mles_product_sum.rs` before attempting.

**Delayed modular reduction** (complex) — accumulate in wider integers, reduce once per
element. AIR constraints are degree-9 with interleaved ops — needs overflow analysis.

**Constraint expression CSE** — common subexpressions the compiler misses in Poseidon16::eval.

### 2. Iterator/closure dispatch (~6% e2e — surprising target)

`FnMut::call_mut` appears multiple times totaling ~5%. These are compiler-generated thunks
for closures through generic APIs. May indicate vtable/indirect-call overhead that
`#[inline(always)]` or monomorphization hints could eliminate.

### 3. GKR quotient sumcheck (4.9% e2e)

`handle_gkr_quotient_with_fold` at 2%, `fold_and_compute_gkr_quotient_split_eq` at 1.7%.
Partially explored in experiment 2 but alpha fusion and inner loop restructuring both failed.
Fresh approaches only.

### 4. Logup data prep (~5-8% e2e)

**finger_print_packed** — inner kernel. Horner evaluation, SIMD utilization.

**Column read cache locality** — batch-read rows instead of element-at-a-time.

**Embedding avoidance** — skip base→extension lift when numerator is F::ONE.

### 5. Cross-boundary restructuring

**Padding-aware folding** — fold zeros efficiently in padded polynomials.

**Reduce GKR layers** — fewer rounds = less total work.

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
| Benchmark | `~/zk-autoresearch/leanMultisig-bench/` | Writable — add isolated benchmarks if needed |

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
2. **Profile first.** Iter 1 MUST start with `perf record` or `cargo flamegraph` to verify
   where time actually goes. Profile again after every keep.
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
**split_eq BasePacked routing:** monomorphization instability, +11% wall-clock. Note: Rust
anonymous closure types are position-dependent. Moving a closure into an else branch or
separate function changes its monomorphization hash, causing iai FAIL even with identical
logic. Do not route different code paths through separate closures in sc_computation.rs.
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
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until manually stopped or stop criterion hit.
