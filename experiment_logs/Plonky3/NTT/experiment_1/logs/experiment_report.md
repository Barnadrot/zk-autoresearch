# Experiment 1 Report — Round 1

**Date:** 2026-03-25
**Model:** claude-sonnet-4-6
**Token budget:** 20,000 tokens/iter (non-streaming)
**Iterations:** 74
**Baseline:** 2724.4ms
**Best:** 2642.8ms
**Net gain:** −3.00%

---

## Summary

Round 1 was the first run of the autoresearch loop on Plonky3's `coset_lde_batch`. Starting
from vanilla Plonky3 on BabyBear at 2^20 × 256 columns, the agent found 5 improvements across
74 iterations for a cumulative 3.00% speedup. Preliminary findings were shared publicly on X.

Multi-size benchmark not run for this round. See table.md for round 2 multi-size validation
which covers all cumulative improvements.

---

## Kept Improvements

| Iter | Score | Gain | Files | Description |
|------|-------|------|-------|-------------|
| 1 | 2723.0ms | +0.06% | butterflies.rs, radix | Added ScaledDitButterfly/ScaledTwiddleFreeButterfly; merged 1/N scaling into first butterfly layer of second_half, eliminating a separate O(N) memory pass |
| 6 | 2698.2ms | +0.96% | butterflies.rs, radix | Precomputed twiddle×scale in ScaledDitButterfly::new() as twiddle_times_scale; reduced per-element multiplications in hot loop from 3 to 2 |
| 9 | 2678.6ms | +0.73% | butterflies.rs | Pre-broadcast scalar twiddle into packed field once before inner loop in DitButterfly::apply_to_rows; eliminates 16 redundant scalar→vector broadcasts per row-pair at 256 cols/AVX512 width 16 |
| 16 | 2667.9ms | +0.40% | radix | TwiddleFreeButterfly for layer 0 of first_half — twiddles[0]=root^0=1, eliminates one Montgomery mul per element for that layer |
| 21 | 2642.8ms | +0.58% | butterflies.rs | Pre-broadcast on ScaledDitButterfly — same pattern as iters 10/11 which regressed, but unlocked by iters 16/19 changing surrounding code paths. Demonstrates interaction effects between kept improvements. |

---

## Key Findings

### Interaction effects between improvements
Iter 21's pre-broadcast on ScaledDitButterfly failed in iters 10 and 11, then succeeded in
iter 21 after iters 16/19 changed the surrounding code. The relative weight of the
ScaledDitButterfly hot path increased, making the broadcast amortization profitable.
This suggests improvements are not fully independent — earlier changes can unlock later ones.

### butterflies.rs as primary target
3 of 5 kept improvements touched butterflies.rs directly. The packed field broadcast pattern
(pre-broadcast scalar twiddle into F::Packing once per row-pair rather than per packed element)
is the dominant optimization theme of round 1.

### Dead ends
- Manual loop unroll (-49.4%) — LLVM handles ILP; manual unrolling broke vectorizer badly
- Forced inlining via #[inline(always)] — LLVM already making good decisions
- Removing backwards bool from dit_layer_rev — flag was doing real work
- Packed-broadcast on ScaledDitButterfly (iters 10, 11) — inverse DFT path doesn't amortize

### Token budget issues
Iters 2–5 and 7–8 hit MAX_TOKENS=8192 before writing (no_changes). Fixed mid-run by raising
to 20k and adding "you must always make a change" prompt. Iters 14–15 also exhausted budget
without writing.

---

## Infrastructure Built This Round

- loop.py initial implementation
- MAX_TOKENS: 8192 → 12000 → 20000
- Recovery prompt for max_tokens-without-writing
- Near-miss display in history
- Simplicity criterion in prompt
- Fixed compounding bug (best_ns now loaded from log on restart)
- Added agent_thinking and agent_time_s fields to experiments.jsonl
