// eliminated_ideas.md
// eliminated_ideas.md
// eliminated_ideas.md
// eliminated_ideas.md

## Eliminated ideas (do not re-attempt)


### Run 1 eliminations (from CLAUDE.md)

The following ideas were attempted by a previous agent (Sonnet 4.6) and did not yield statistically significant improvements. Review each before dismissing — Sonnet may have made implementation errors, missed edge cases, or stopped too early. Do not re-attempt without a concrete reason to believe the prior attempt was flawed.

- **Broad restructuring of `second_half_general` / `first_half_general`** (9 attempts, −0.58% to −2.02%):
  Many structural variants tried. Consistently regressed.

- **Pre-reverse twiddle slice for sequential prefetcher access** (tried twice, −0.97%):
  Reversing the twiddle slice so the prefetcher sees sequential access. Regressed both times.

- **Fuse `layer_rev==3` and `layer_rev==2` (`dit_layer_rev_pair32`)** (−1.22%):
  Fusing two adjacent butterfly layers into one pass. Regressed.

- **Manual loop unroll** (−49.4%):
  Manually unrolling the butterfly inner loop. Catastrophic regression.

- **`#[inline(always)]` on butterfly functions** (regressed):
  Adding `#[inline(always)]` to `DitButterfly`, `ScaledDitButterfly`, `TwiddleFreeButterfly`. Regressed.

- **Remove `backwards` bool from `dit_layer_rev`** (broke correctness):
  Attempting to eliminate the runtime branch. Broke output correctness.

- **Boundary-layer specialization (`dit_layer_rev_base`, `dit_layer_oop_base`)** (−0.68% to −0.73%):
  Specializing the first/last butterfly layers with dedicated functions. Regressed.

- **Pre-broadcast hoisting outside per-block loop** (`first_half_general_oop` layer 0, 
  `dit_layer_uniform`) (−0.73% to −0.92%):
  Hoisting twiddle broadcast outside the blocks loop. Regressed.

- **`DifButterfly::apply_to_rows` pre-broadcast** (borderline, targets `Radix2Bowers` not `Radix2DitParallel`):
  Pre-broadcasting in DifButterfly. Not in the coset_lde_batch hot path.


### Run 2 eliminations (from Opus 4.6, 23 iterations)

The following ideas were attempted by Opus 4.6 in Round 2 and did not yield statistically significant
improvements. 1 improvement was found (iter 2: `#[inline]` hints on layer functions, +1.02%, p=0.00).
The remaining 21 iterations explored variants of the backwards-bool DCE family.

- **`#[inline]` hints on layer functions** — ALREADY KEPT (iter 2, +1.02%).
  Applied to: `dit_layer`, `dit_layer_rev`, `dit_layer_rev_scaled`, `dit_layer_oop`,
  `dit_layer_twiddle_free`, `dit_layer_first_one`. Do not re-apply.

- **Loop unrolling to eliminate `backwards` bool** (21 attempts, −0.06% to +1.06%, all p > 0.05):
  Opus spent 21 consecutive iterations unrolling `dit_layer_rev` / `first_half_general` to create
  separate forward/backward code paths, hoping LLVM would DCE the branch and improve codegen.
  Warmest result: iter 7, +1.06%, p=0.06 (just outside gate). Never crossed p=0.05 despite
  many structural variants. Do not re-attempt without a fundamentally different approach (e.g.
  compile-time const generics instead of runtime unrolling).

- **`first_half_general` + `first_half_general_oop` backwards-specialized variants** (multiple):
  Splitting into separate forward/backward functions. Consistently weak signal, never p < 0.05.

- **Opus never explored `monty-31/src/x86_64_avx512/` scope** — this remains untested by Opus.
  The monty arithmetic (mul, add, sub, reductions) is a strong candidate for the next run.
