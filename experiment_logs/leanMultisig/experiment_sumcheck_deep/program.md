# leanMultisig Sumcheck Deep — Experiment 2

## Role
You are an expert ZK protocol engineer with deep knowledge of sumcheck, GKR, and lookup arguments.
You understand how these protocols compose — how logup drives GKR layers, how batched AIR sumcheck
shares structure across constraints, how the prover's round loop interacts with the polynomial
evaluation kernel. You also write high-performance Rust.

Your job is to make the leanMultisig prover faster by finding **algorithmic and structural**
improvements in the sumcheck protocol layer, logup GKR driver, and AIR sumcheck orchestration.
Micro-optimizations (inlining, alloc reuse) have been exhausted by experiment 1. This experiment
needs you to think about the protocol, not just the instructions.

**This is experiment 2.** Experiment 1 ran 36 iterations and found ~3.6% e2e speedup from
`#[inline(always)]` on quintic field arithmetic. The quintic extension surface is exhausted.
This experiment targets the 4,000+ LOC that experiment 1 barely explored.

## Hardware
AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512 available, KVM virtualized.

## The Metric
**Lower is better.** Score = median latency in ms for `xmss_leaf_1400sigs` (1400 XMSS signatures).
Calibrated baseline: ~5.17s median (post experiment 1 keeps).

## Inspiration Repos (source reference)

| Repo | Built | Notes |
|---|---|---|
| `~/zk-autoresearch/Plonky3/` | yes | Sumcheck/NTT patterns, monty-31 AVX-512 |
| `~/zk-autoresearch/jolt/` | yes | Sumcheck/GKR patterns, lookup arguments |
| `~/zk-autoresearch/sp1/` | source only | CUDA-only build, source readable |

Use these for optimization patterns. Do not modify them.

---

## Known Dead Ends (from experiment 1, 36 iterations)

**DO NOT ATTEMPT any of these. They have been tried and conclusively failed:**

### Category A — Hardware local optimum (eval_eq_basic)
Any structural change to `eval_eq_basic` regresses wall-clock +7-9% despite iai improvement.
The CPU's branch predictor and OoO execution are tuned to the existing recursive pattern.
- eval_eq_4 base case unroll (iter 2): iai -7.4%, wall-clock +8.1%
- eval_eq_4 #[inline(never)] (iters 4-5): iai -5.7%, wall-clock +9.2%
- 2-var-per-level recursion (iter 6): iai -1.1%, wall-clock +7.3%
- Direct packed eq computation (iter 25): +9.6% — packed quintic_mul 12x slower than scalar
- Sequential repacking (iter 24): +7.2% — parallel IS needed for transpose

### Category B — Compiler already optimal
- Vec alloc reuse in sumcheck inner loops (iters 3, 34): clear/extend generates MORE instructions than collect. Do not retry.
- CSE of redundant muls in quintic_square (iter 1): compiler already does it
- Pre-broadcast of fold factors (iter 12): compiler already hoists
- Assert_eq to debug_assert_eq (iter 8): compiler constant-propagates away
- parallel_sum fold+reduce (iter 31): +1.9%, loses rayon pipelining

### Category C — I-cache budget exhausted
- Beyond 9 force-inlined quintic functions, I-cache pressure negates gains (iters 11, 16-18)
- Adding Mul<PF>/MulAssign<PF>: +0.30% regression
- Adding Add/Sub/vector ops: -0.29% regression (noise)

### Category D — Rayon conflicts
- Flattening nested rayon par_iter in logup (iter 33): +11.4% — runtime divmod from non-const chunk size
- Column-level par_iter in post-GKR (iter 36): +0.30% — conflicts with internal rayon

### Category E — Sub-threshold (real but too small)
- GKR accumulator combining (iter 27): -0.62%, real but below 1.0% threshold
- quintic_square #[inline(always)] alone (iter 10): -0.83%, below 1.5% threshold at the time

---

## Your Targets (priority order)

The writable surface is ~6,600 LOC across 20 files. Experiment 1 spent almost all its time
on ~1,500 LOC in quintic_extension. Four areas totaling ~4,000 LOC are barely explored:

### Target 1 — logup.rs (539 LOC, ~18% e2e inclusive)
`~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/logup.rs`

`prove_generic_logup` drives ~18% of e2e time. Experiment 1 tried 2 shallow ideas (rayon
flattening, eq_mle precompute) and both failed. What has NOT been studied:
- GKR layer structure — how layers are constructed, data flow between them
- Numerator/denominator Vec construction — built every call, can they be reused or pre-sized?
- Multilinear prep before `sumcheck_prove_many_rounds` — is work being repeated?
- The interaction between logup's data prep and the sumcheck compute kernel

**Do NOT flatten rayon (iter 33) or add column-level par_iter (iter 36). Both failed.**

### Target 2 — air_sumcheck.rs (229 LOC, ~15% e2e inclusive)
`~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/air_sumcheck.rs`

`prove_batched_air_sumcheck` drives ~15% of e2e time. **Completely unexplored** in experiment 1
(iter 35 was the only attempt, immediately failed because air_sumcheck is not in iai TRACK_REGEX).
- Batch dimension sharing — can work be shared across the batch?
- AIR constraint evaluation structure
- How the batched sumcheck interacts with the fiat-shamir transcript

**Any change here needs `[wallclock-only]` tag — air_sumcheck is NOT in iai TRACK_REGEX.**

### Target 3 — sc_computation.rs (884 LOC)
`~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/sc_computation.rs`

The `SumcheckComputation` trait dispatch. Experiment 1 tried 4 shallow ideas (alloc reuse,
CSE, parallel_sum), none targeting the actual compute paths:
- `eval_packed_base` / `eval_packed_extension` inner kernels — are these actually hit?
- `fold_and_sumcheck_compute` — complex generics, check monomorphization quality
- `SumcheckComputeParams` — constructed per round, redundant recomputation?
- The three eval paths (base / extension / packed) — which dominates and why?

**Do NOT retry Vec alloc reuse (iters 3, 34) or parallel_sum fold (iter 31). Both failed.**

### Target 4 — prove.rs (284 LOC)
`~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/prove.rs`

`sumcheck_prove_many_rounds` — the shared round loop that all three callers go through.
Experiment 1 looked briefly (iter 23) but dismissed it because it wasn't in iai tracking.
- `compute_round_polynomial` called n_vars times — work that could be hoisted?
- Loop iterations that could be fused?
- SplitEq's `truncate_half()` per round — allocation behavior?

### Secondary targets (if primary targets exhaust)
- `quotient_computation.rs` — GKR quotient kernel, partially explored. Iter 27's -0.62% combining idea was real but sub-threshold. Revisit with relaxed threshold or build on it.
- `product_computation.rs` — WHIR product sumcheck. Loop order and chunk sizes explored (iters 7, 22). `compute_product_sumcheck_polynomial_base_ext_packed` inner kernel not deeply studied.

---

## Scope Rules

### What changed from experiment 1
- **Structural changes of 50-200 lines are explicitly allowed.** The surgical constraint is
  relaxed. Correctness gate is the only hard constraint on diff size.
- **Protocol-level restructuring is in scope** if motivated by a specific hypothesis. If you
  find a paper or pattern that suggests a different approach to batched sumcheck or GKR layer
  construction, you may implement it.
- **Research papers are a valid input.** If you identify a relevant paper (packed sumcheck,
  improved GKR, etc.), read it and implement the core idea. Don't dismiss changes as "too large."

### What stays the same
- ONE change per iteration. Don't bundle.
- Correctness gate must pass after every change.
- Gate infrastructure (eval_gate.sh etc.) is unchanged.
- `[wallclock-only]` tag required for changes invisible to iai (air_sumcheck.rs, logup.rs, rayon tuning).

## Target Files (writable)

### Primary targets (this experiment)
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/logup.rs`
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/air_sumcheck.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/sc_computation.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/prove.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/product_computation.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/quotient_computation.rs`

### Saturated — DO NOT MODIFY (experiment 1 exhausted these)
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/extension.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/packed_extension.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/packing.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/eq_mle.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/next_mle.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/mle/` (all files)

### Read-only — DO NOT MODIFY
| Path | Reason |
|---|---|
| `crates/backend/fiat-shamir/` | Transcript + challenger — security-critical |
| `crates/backend/air/` | AIR constraint definitions |
| `crates/backend/field/` | Field arithmetic primitives |
| `crates/backend/koala-bear/src/monty_31/` | Montgomery arithmetic — foundational |
| `crates/backend/koala-bear/src/poseidon*` | Hash primitive — security-critical |
| `crates/backend/koala-bear/src/koala_bear.rs` | Base field definition |
| `crates/backend/koala-bear/src/x86_64_avx*/` | AVX packing |
| `crates/backend/koala-bear/src/quintic_extension/tests.rs` | Property tests — integrity-checked |
| `crates/whir/` | WHIR protocol |
| `crates/backend/sumcheck/src/verify.rs` | Verifier — never touch |
| Any `tests/` directory | Do not modify test values |
| `~/zk-autoresearch/experiment_logs/` | Infrastructure — read-only |
| `~/zk-autoresearch/leanMultisig-bench/` | Bench crate — read-only |

---

## Gate & Keep Rule

Unchanged from experiment 1. Wall-clock threshold relaxed to 1.0% for `[wallclock-only]` changes.

### Stage 1 — iai-callgrind instruction-count gate (primary signal)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_iai.sh`

- **PASS** = any tracked symbol dropped >= 0.10% AND no tracked symbol regressed > 0.05%.
- Exit 0 on PASS, 1 on FAIL, 2 on infra error.
- **Note:** `sub_protocols/` (logup.rs, air_sumcheck.rs) is NOT in TRACK_REGEX. Changes there MUST use `[wallclock-only]`.

### Stage 2 — paired wall-clock (sanity check / primary for wallclock-only)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_paired.sh`

### Stage 3 — revert-A/B (marginal keeps only)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_revert_ab.sh <claim_delta_pct>`

### Combined decision table

| Stage 1 (iai) | `[wallclock-only]` | Stage 2 (paired median) | Stage 2 p | Keep? | Revert-A/B? |
|---|---|---|---|---|---|
| PASS | no | >= +0.5% (regression) | | NO | |
| PASS | no | < +0.5% (no regression) | | YES | if |delta| < 3.0% |
| FAIL | no | | | NO — discard_iai | |
| (skipped) | yes | <= -1.0% | < 0.01 | YES | if |delta| < 3.0% |
| (skipped) | yes | otherwise | | NO — discard_wallclock | |

**Note:** wallclock-only threshold is 1.0% (relaxed from experiment 1's 1.5%).

---

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` (this file) and `iters.tsv`.
2. **Profile first** if this is your first iteration or after any keep:
   ```bash
   cd ~/zk-autoresearch/leanMultisig
   RUSTFLAGS="-C target-cpu=native" cargo build --release -p leanMultisig-bench
   perf record -g --call-graph=dwarf ./target/release/leanMultisig-bench --bench xmss_leaf -- xmss_leaf_1400sigs --measurement-time 10 --sample-size 3
   perf report --no-children --sort=dso,symbol | head -40
   ```
   Or use `cargo flamegraph` if available. Understand where time is spent NOW, not where experiment 1 said it was.
3. Read the target files. Understand the code before hypothesizing.
4. Devise ONE targeted change. State the hypothesis — what, why, expected signal.
   If targeting logup.rs or air_sumcheck.rs: note `[wallclock-only]` required.
5. Edit the source file(s).
6. Run correctness check (~12s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh
   ```
   If tests fail: `git -C ~/zk-autoresearch/leanMultisig checkout -- .`, log `correctness_fail`.
7. Commit: `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <short description>"`
   Include `[wallclock-only]` in commit body if needed.
8. Run the gate (~7-11 min):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_gate.sh
   ```
9. If KEEP: log keep row, run periodic audit every 5 keeps.
10. If DISCARD: `git -C ~/zk-autoresearch/leanMultisig revert HEAD --no-edit`, log discard row.

## Logging — `iters.tsv`

Same format as experiment 1:
```
iter	stage1_iai_delta	stage1_iai_decision	stage2_median_pct	stage2_p	revert_ab	base_hash	cand_hash	status	files_changed	rationale
```

## Stop Criterion
If 20 consecutive iterations produce no keep, pause and report "surface exhausted" with a
summary of what was tried. Better to surface exhaustion than loop indefinitely.

## Hard Constraints
1. No security parameter changes.
2. No interface changes — do not alter public function signatures.
3. No test value changes.
4. Correctness is mandatory — all tests in correctness.sh must pass.
5. **NEVER modify** `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/leanMultisig-bench/`.
6. **NEVER skip Stage 2.** Wall-clock confirmation always required.
7. **NEVER log a keep with `base_hash == cand_hash`.**
8. **NEVER modify** quintic_extension or eq_mle files — they are saturated.

## Profile-first invariant
If measured median baseline runtime drifts > 10% from ~5.17s for 2+ consecutive iterations,
pause and investigate. The hot path may have shifted.

## NEVER STOP
Run experiments autonomously until manually stopped or stop criterion (20 consecutive discards) hit.
