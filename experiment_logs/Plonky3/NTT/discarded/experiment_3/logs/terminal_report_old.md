# Experiment 3 — Terminal Log Analysis

> **Note:** `terminal_test.log` contains data from two separate runs. The first ~200 lines are from an earlier experiment (runaway agent with 5 recovery prompts and a 55k-character rewrite of `radix_2_dit_parallel.rs`). The 5 iterations below start at `[loop] Iteration 1/1`.

---

## Iter 1 — REVERTED +1.36% | tokens=179272in/34111out | cost=$1.0495

**Idea submitted**
- Added pre-broadcast `apply_to_rows` overrides to `DifButterfly`, `ScaledTwiddleFreeButterfly`, `DifButterflyZeros` — eliminating redundant scalar-to-vector broadcasts per packed iteration

**Agent reasoning**
- Read butterflies.rs and radix_2_dit_parallel.rs in full
- Correctly verified DitButterfly and ScaledDitButterfly already have pre-broadcast
- Traced hot path through coset_lde_batch → first_half/second_half → dit_layer_rev
- Recovery prompt fired 1/2 — agent was mid-analysis of overhead ratios, pivoted to non-hot-path butterflies
- Agent explicitly stated "if these aren't in the hot path they won't help" then submitted anyway after recovery reframed as "could help other paths"

**Promising ideas abandoned**
- `dit_layer_uniform_twiddle` flat loop with single packed broadcast per submat
- BabyBear-specific scaling via `mul_neg_2exp_neg_n_avx512`

**Assessment**
- NOT on the hot path — DifButterfly/DifButterflyZeros not used in coset_lde_batch
- Agent self-contradicted: correct reasoning abandoned after recovery prompt
- Recovery prompt caused the pivot — classic forced bad submit pattern

---

## Iter 2 — REVERTED +0.22% | tokens=501178in/41620out | cost=$2.1278

**Idea submitted**
- Explicit `apply_to_rows` override for `TwiddleFreeButterfly` — loads x1/x2 into locals before sum/difference, ensuring register reuse across add and subtract

**Agent reasoning**
- Read experiment diff from iter 1 to understand failure
- Correctly identified TwiddleFreeButterfly IS in hot path (IDFT first half, layer 0, 2^19 row-pairs)
- Hypothesis: explicit locals enable better register lifetime vs indirect apply_in_place → apply chain
- 501k input tokens — significant circular exploration, re-verified same conclusions multiple times
- Recovery prompt fired 1/2

**Promising ideas abandoned**
- `ScaledDitButterfly::apply_to_rows_oop` (agent noted it's not called in coset path)
- Fusing first two layers of `first_half_general_oop`

**Assessment**
- Hot path target — correct direction
- Compiler already handling register reuse; explicit locals provided no new information to LLVM
- Best reasoning quality of the 5 iters in terms of hot-path verification before submitting

---

## Iter 3 — REVERTED +0.17% | tokens=391868in/53870out | cost=$1.9837

**Idea submitted**
- Explicit local `a = *x_1` in `DitButterfly::apply_to_rows` hot loop, plus updated `ScaledDitButterfly` and `DitButterfly::apply_to_rows_oop` to use explicit a/b locals for store-forwarding and pipeline utilization

**Agent reasoning**
- Read iter 1 and iter 2 diffs to understand regression pattern
- Analyzed ALU dependency chain in `dit_layer_rev_last2_flat` — correctly traced 12-step chain, identified 15-cycle critical path
- Identified serial mul dependency between the two butterfly stages — unavoidable
- Store ordering: noted `*x_2` written before `*x_1`, hypothesized reordering could improve store-forwarding
- Recovery prompt fired 2/2 — mid-analysis of broader restructuring ideas

**Promising ideas abandoned**
- Flattening `dit_layer_rev_last2_flat` twiddle indexing via direct indexing instead of chunks(2)
- Pointer arithmetic to reduce iterator overhead in outer loop

**Assessment**
- Hot path target (DitButterfly::apply_to_rows is hot)
- Compiler already emitting optimal store ordering; explicit locals added register pressure
- The dependency chain analysis was the most sophisticated reasoning of the 5 iters — cut off by token cap before it could be acted on

---

## Iter 4 — REVERTED +0.02% | tokens=223871in/34704out | cost=$1.1922

**Idea submitted**
- `apply_to_rows_oop` override for `ScaledDitButterfly` — pre-broadcast of `scale` and `twiddle_times_scale`, eliminating redundant broadcasts if ScaledDitButterfly is used in any OOP butterfly path

**Agent reasoning**
- Agent noticed confusion about what's in current codebase vs baseline — couldn't tell if round 1+2 improvements were applied (they are)
- Verified ScaledDitButterfly::apply_to_rows already has pre-broadcast
- Investigated whether apply_to_rows_oop is called anywhere — concluded "if used in OOP contexts"
- Correctly used cross-experiment history via RECENT ATTEMPTS window
- Recovery prompt fired 1/2

**Promising ideas abandoned**
- Specializing layer_rev==2 in second_half_general separately from general dit_layer_rev
- Memory bandwidth optimizations (architecture-level, out of scope)

**Assessment**
- Dead code path — ScaledDitButterfly is only used in dit_layer_rev_scaled (in-place), not OOP paths
- +0.02% is at noise floor — code size/instruction cache effect
- Codebase state confusion is a clear infra gap: agent didn't know round 1+2 changes were already applied

---

## Iter 5 — REVERTED +3.23% | tokens=206426in/28289out | cost=$1.0436

**Idea submitted**
- Explicit `apply_to_rows_oop` override for `TwiddleFreeButterfly` writing a+b and a-b to MaybeUninit destinations using local variable loads, combined with existing apply_to_rows override from iter 2

**Agent reasoning**
- Began with promising analysis: full ALU dependency chain for `dit_layer_rev_last2_flat` (15-cycle critical path confirmed)
- Identified `dit_layer_rev_last2_flat` uses `twiddles0.chunks(2)` — noted direct indexing could reduce iterator overhead (256 broadcasts per thread, 256 mega-blocks)
- Was mid-analysis of this idea when recovery prompt fired
- Recovery pivot: abandoned the chunks(2) → direct indexing idea entirely, switched to TwiddleFreeButterfly OOP override
- Also considered `#[inline(never)]` hints for code size reduction — not pursued

**Promising ideas abandoned**
- **`dit_layer_rev_last2_flat` direct indexing** — replace `twiddles0.chunks(2)` with direct pointer arithmetic to reduce iterator overhead. This was the most promising unexplored idea of the 5 iters, cut off by token cap.
- `#[inline(never)]` hints to reduce code size pressure on inlining heuristics

**Assessment**
- Worst regression of the round (+3.23%) — directly caused by recovery pivot abandoning the promising idea
- Combined OOP override + apply_to_rows override likely exceeded inlining thresholds
- TwiddleFreeButterfly OOP path not verified as hot path before submitting
- Recovery prompt is most clearly the culprit here

---

## Summary

### Regression staircase
| Iter | Delta | Cause |
|------|-------|-------|
| 1 | +1.36% | Non-hot-path, recovery pivot |
| 2 | +0.22% | Compiler already optimizing |
| 3 | +0.17% | Compiler already optimizing |
| 4 | +0.02% | Dead code path, noise floor |
| 5 | +3.23% | Recovery pivot abandoned best idea |

Iters 2-4 show convergence toward zero — agent narrowing in correctly. Iter 5 breaks the pattern due to recovery prompt pivot.

### Recovery prompt impact
- Fired 9 times across 5 iters (avg 1.8/iter)
- Caused bad pivots in iters 1 and 5 — the two worst regressions
- Pattern: agent abandons in-progress idea, defaults to safe non-hot-path change

### Best unexplored idea
**`dit_layer_rev_last2_flat` direct indexing** — replace `twiddles0.chunks(2)` iterator with direct pointer arithmetic. Agent was mid-analysis on this in iter 5 when token cap hit. The dependency chain analysis that preceded it was the most rigorous reasoning of the round — worth pursuing as the first iter 6 target.

### Infra gaps evidenced

1. **Recovery prompt causes pivots** — agent loses in-progress reasoning state, defaults to safe fallback. Fix: pass last reasoning summary back at recovery, force completion of in-progress idea only.

2. **No assembly visibility** — all regressions were mysterious at source level. Agent counted muls in source but couldn't verify LLVM output. `cargo asm` would have caught iters 2-4 before submitting.

3. **Codebase state confusion** — iter 4 agent unsure whether round 1+2 improvements are applied. Fix: explicit one-line statement in prompt.

4. **Interrupted ideas not preserved** — iter 5's best idea died with the token cap. Fix: log `interrupted_idea` to experiments.jsonl at recovery, surface via history window.

5. **Context bloat** — iter 2 hit 501k input tokens. Agent re-reads same conclusions multiple times. Fix: context compaction within iteration.
