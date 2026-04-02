# Experiment 2 Report — Round 2

**Date:** 2026-03-27
**Model:** claude-sonnet-4-6
**Token budget:** 20,000 tokens/iter (non-streaming)
**Iterations:** 20 (graceful stop)
**Baseline:** 2667.80ms
**Best:** 2638.00ms
**Net gain:** −1.12% (cumulative with Round 1: ~−4.1%)

---

## Executive Summary

Round 2 achieved a 1.12% improvement on `coset_lde_batch` at 2^20 × 256 columns on BabyBear,
with 4 improvements kept across 20 iterations and zero correctness failures. Combined with
Round 1's 3.00%, the cumulative gain from baseline is approximately 4.1%.

The round was preceded by a failed experiment (Round 2a / `experiments_with_bug.jsonl`) where
all 23 iterations failed due to a missing `proptest.workspace = true` in `dft/Cargo.toml` from
an incomplete cherry-pick of PR #1494. Once corrected and committed, Round 2 ran cleanly.

### Strategic Outlook

Round 2 reveals a clear pattern: the agent has good optimization intuitions but is constrained
by the 20k token budget, producing full-file rewrites (~50k chars) that the compiler cannot
optimize as well as the original code. The remaining high-value targets — `butterflies.rs`,
`baby-bear/src/x86_64_avx512/packing.rs` — require more tokens to reason about and write than
the current budget allows.

**On plateau and comparison to Karpathy's autoresearch:** We are observing a plateau
significantly earlier than Karpathy's original autoresearch. Three possible explanations,
likely acting in combination:

1. **Loop immaturity.** The 50k-character full-file rewrites are more likely a prompt
   engineering and agent memory shortcoming than a true optimization plateau. The agent
   lacks cross-experiment memory, has no surgical precision guidance, and is farming recovery
   prompts for token budget rather than executing targeted changes. These are fixable
   infrastructure problems, not fundamental limits of the search space.

2. **Domain difference.** Karpathy's autoresearch targeted parameter optimization — a
   continuous, differentiable search space with gradual improvement signals. zk-autoresearch
   targets code optimization for ZK proof systems: discrete changes, strict correctness
   requirements, and a search space shaped by compiler behavior and CPU microarchitecture.
   Plateau dynamics are inherently different; the cliff between "compiler handles it" and
   "manually restructured code regresses" is steeper and less predictable.

3. **Model ceiling at current token budget.** The remaining high-value targets (butterflies.rs,
   packing.rs AVX512 arithmetic) require more tokens to reason about and execute than the
   current 20k budget allows. This is not a plateau in the optimization space — it is a
   capability constraint on the agent.

The most reliable way to distinguish a true plateau from a tooling plateau is to optimize
the loop infrastructure on Sonnet first, then re-evaluate. If improvements resume after
fixing the surgical precision prompt and cross-experiment memory, it was tooling. If they
don't, it is the domain ceiling.

A third direction exists if structural code optimization plateaus definitively, target
**numerical parameters embedded in the code** — parallelism thresholds, chunk sizes, twiddle
precomputation cutoffs, cache blocking constants. This creates a smoother optimization
landscape closer to Karpathy's original setup, with bounded search spaces and less compiler
sensitivity. The current loop architecture is well-suited to structural code changes and that
remains the right primary direction; numerical parameter tuning is a natural fallback if the
structural search space is exhausted.

**On observability and loop engineering:** While the goal of zk-autoresearch is to automate
improvements, round 2 revealed that the ability to follow agent reasoning in real time —
and to understand what failed ideas were actually attempting — is critical for prompt and
loop engineering. The recovery prompt farming pattern, the full-rewrite tendency, and the
iter 9/11 duplicate were only diagnosable because we were watching the terminal output live.
The next round of infrastructure improvements addresses this directly: richer experiment
history, cross-experiment memory, and surgical precision guidance are all informed by what
we observed here. Fittingly, the most impactful infrastructure change — streaming — also
happens to be the one that makes agent reasoning fully visible in real time.

**Conclusion:** A plateau is expected — but with infrastructure optimization and model
scaling, several more productive rounds remain before it is reached. More importantly,
Karpathy's autoresearch has not deeply explored plateau behavior either; his setup has a
nearly unlimited parameter search space where the ceiling is rarely hit. A constrained,
production-grade codebase like Plonky3 — with strict bitwise correctness requirements,
compiler-enforced performance ceilings, and measurable benchmark signal — is a cleaner
environment to study where LLM-driven optimization actually terminates.

The goal of subsequent rounds is not only to find more speedups, but to map the optimization
frontier: where does Sonnet plateau, where does Opus extend it, and what is the theoretical
ceiling given the compiler's ability to match the agent's structural ideas. The ZK constraint
makes this more rigorous than prior work — every kept change is cryptographically verified
correct, every regression is measured cleanly against a fixed baseline. This is the data
needed to understand LLM-driven systems code optimization as a research area, not just as
an engineering tool.

**Our thesis is that optimizing the loop infrastructure on Sonnet before moving to Opus will
yield better overall results.** Opus at higher token budgets is the natural next step, but
running it on the current loop would waste expensive iterations on problems already identified:
the recovery prompt exploit, the full-rewrite tendency, the lack of cross-experiment memory.
Every infrastructure improvement validated on Sonnet carries over to Opus at no additional cost.
Opus on a well-tuned system is a fundamentally different experiment from Opus on the current one.

Additionally, the dead ends and caution areas accumulated across rounds (second_half_general
layer structure, always-forward iteration, forced inlining) are model-agnostic — they save
Opus those exploration iterations regardless of reasoning quality.

---

## Results

### Kept Improvements

| Iter | Speedup | Score | Change |
|------|---------|-------|--------|
| 1 | +0.38% | 2657.6ms | `dit_layer_rev_last` — inlined flat loop for last layer of `second_half_general`, pre-broadcasts twiddle once |
| 2 | +0.45% | 2645.6ms | `dit_layer_uniform_twiddle` — pre-broadcast single coset twiddle for layer 0 of `first_half_general` |
| 3 | +0.06% | 2644.1ms | `dit_layer_rev_last2` — fused last two layers of `second_half_general` into single 4-row pass |
| 8 | +0.23% | 2638.0ms | Extended `dit_layer_rev_last2` fusion to `second_half` (inverse DFT OOP path) |

Iter 3's 0.06% is at the noise boundary and may be reconsidered pending multi-size validation.

### Reverted Iterations

| Iter | Result | Idea |
|------|--------|------|
| 4 | −0.30% | Fuse first two layers of `first_half_general` |
| 5 | −0.58% | `dit_layer_two_uniform_twiddles` for layer 1 of `first_half_general` |
| 6 | −0.33% | Uniform twiddle pre-broadcast for `first_half_general_oop` layer 0 |
| 7 | −0.96% | Fuse last three layers of `second_half_general` into 8-row pass |
| 9 | −0.97% | `dit_layer_rev_forward` — pre-reverse twiddle slice for sequential prefetcher access |
| 10 | −1.22% | `dit_layer_rev_pair32` — fuse `layer_rev==3` and `layer_rev==2` |
| 11 | −0.79% | `dit_layer_rev_forward` (same idea as iter 9, independently rediscovered) |
| 12 | −1.02% | Inline `DitButterfly::apply_to_rows` in `second_half_general` general layers |
| 13 | −0.41% | Pre-broadcast all twiddles per layer of `first_half_general` + OOP |
| 14 | −1.32% | Restructure `second_half_general` while loop, hoist special cases outside |
| 15 | −0.50% | Specialize first layer of `second_half_general` with uniform twiddle |
| 16 | −0.88% | Replace `dit_layer` iterator-clone-per-block with `dit_layer_slice` |
| 17 | −0.97% | Inline packed butterfly loop in `first_half_general`, eliminate `apply_to_rows` |
| 18 | −1.03% | Fuse first two layers of `first_half_general_oop` |
| 19 | −0.71% | Uniform-twiddle optimization for `first_half_general_oop` layer 0 OOP |
| 20 | −2.02% | Remove `backwards` flag from `first_half_general` + OOP entirely |

---

## Key Findings

### Zero correctness failures
All 20 iterations passed both correctness stages (p3-dft property tests + p3-examples ZK
prove/verify end-to-end). The pre-flight test gate caught the proptest bug before wasting any
iterations. The agent respected all hard constraints across every iteration — no interface
changes, no test value modifications, no out-of-scope file edits.

### Full-rewrite pattern and the compiler ceiling
Iters 9–20 produced near-full rewrites of `radix_2_dit_parallel.rs` (~49–55k chars, 1205 lines
on server) targeting `second_half_general` layer structure and `first_half_general` twiddle
paths. All regressed 0.4–2.0%. The compiler already optimizes these regions well — manual
restructuring of compiler-friendly iterator patterns consistently produces worse codegen.
The correct approach is surgical targeted changes, not full-file architectural rewrites.

### Infinite token farming — iter 10
Iter 10 fired 6+ recovery prompts over ~30 minutes, consuming an estimated 150k+ tokens.
The recovery loop has no counter — the incentive structure accidentally rewards not-writing
(each failed write attempt grants another 20k token budget). This is the most significant
loop infrastructure bug discovered to date. Fix: cap recovery prompts at 2, log as `exhausted`.

### History surfacing failure — iters 9 and 11
`dit_layer_rev_forward` was independently rediscovered in iter 11 despite iter 9 appearing in
the `PREVIOUSLY TRIED` history. The one-line idea description was not specific enough for the
agent to recognize the structural overlap. Fix: richer history format with key changed
functions + optional `read_experiment_diff(N)` tool for agent-driven retrieval.

### butterflies.rs never written — two-step reasoning pattern
`butterflies.rs` was read in nearly every iteration but never written. The agent consistently
uses lower-level files (butterflies.rs, packing.rs) as *input* to inform radix changes rather
than targeting them directly. Iter 10 read butterflies → redesigned radix layer structure around
the butterfly interface. Iter 14 read packing.rs lines 1–100 → targeted specific radix sections.
This two-step pattern is the agent's correct approach given the token constraint — it cannot
hold the full butterflies reasoning chain and produce a write within 20k tokens.

### Within-run adaptation is working
By iter 14, the agent was performing precise targeted reads (specific line ranges) rather than
broad exploration. It moved away from the `second_half_general` cluster after 4 consecutive
reverts. The history format is effective for within-run learning; cross-experiment memory
would give round 3 this focus from iteration 1.

---

## Infrastructure Changes This Round

| Change | Reason |
|--------|--------|
| Pre-flight test gate at init | Catch correctness bugs before iter 1 (proptest missing) |
| STOP file cleanup in `--start-fresh` | Prevent stale STOP from blocking new run |
| try/except around execute_tool | Return error to agent instead of crashing loop |
| CLAUDE.md: baby-bear file tree added | Agent was missing packing.rs as a visible target |
| README: tmux pipe-pane logging by default | Save terminal output for analysis |
| PR #1494 cherry-picked + committed | Property tests for `Radix2DitParallel` now in correctness gate |
| changelog.md split into changelog.md + changelog_target.md | Separate repo changes from Plonky3 changes |

---

## Round 3 Priorities

**Critical (implement before next run):**
1. Cap recovery prompts at 2 — fix infinite token farming

**High:**
2. Streaming API + 100k token budget — required to unlock butterflies/packing targets
3. Surgical precision prompt — no full rewrites; benchmark ms is the only success metric
4. Cross-experiment memory — dead ends + caution areas in CLAUDE.md from rounds 1 and 2
5. Multi-size benchmark at experiment start/end — required for publishable results
6. Auto-stop on dry spell (15 consecutive non-improvements)
7. Richer history format + diff access tool — prevent idea rediscovery within a run

**Future:**
8. Opus experiment — after Sonnet infrastructure is fully tuned. Shorter run (20–25 iters),
   higher token budget, primary targets: butterflies.rs and packing.rs.

---

## Multi-Size Benchmark Validation (2026-03-28)

Run after all 4 round 2 improvements committed on `perf/dft-butterfly-optimizations`.
Criterion comparison vs prior commit baseline.

| Size | Optimized Time | Change | Significant? |
|------|---------------|--------|-------------|
| 2^14 × 256 | 54.5ms | −2.17% | No (p=0.38) |
| 2^16 × 256 | 171.0ms | −3.78% | Yes (p=0.00) |
| 2^18 × 256 | 676.5ms | −2.21% | Borderline (p=0.02) |
| 2^20 × 256 | 2.663s | −1.06% | Borderline (p=0.03) |
| 2^22 × 256 | 10.90s | **−8.57%** | Yes (p=0.00) |

Improvements generalize across all sizes. The 2^22 result (−8.57%) is notable — memory
bandwidth effects amplify at larger sizes where working sets exceed L3 cache. The loop
optimizes for 2^20 but the gains are larger at 2^22.

Note: unused `PackedField` import warning in radix_2_dit_parallel.rs — leftover from a kept
change. Should be cleaned up before PR submission.
