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



