// eliminated_ideas.md
// eliminated_ideas.md
// eliminated_ideas.md

## Eliminated ideas (do not re-attempt)

### Run 2 eliminations

- **`vpsubd t` + `vptestmd t, SIGN_BIT` for Sub** (iter #002, -1.45%):
  Using the sign bit of the raw subtraction result to detect underflow in Sub.
  Regressed — worse than vpcmpltud.

- **Manual first-iteration peel for `scale_applied` in `second_half`** (iter #003, -0.56%):
  Peeling the first iteration of the `Some(scale)` branch in `second_half` to eliminate
  the `scale_applied` bool. LLVM already handles this; manual peeling hurts codegen.

- **Fused add/sub in butterfly (single comparison for both)** (analyzed, not implemented):
  `(a + b) mod P` and `(a - b) mod P` require two different conditions (overflow and
  underflow respectively) — there is no single comparison that covers both.

- **Lazy reduction (skip final step of `mul`)** (analyzed):
  Skipping the final `vpcmpltud + vpaddd_mask` in `mul` produces values in
  [2^32 - P + 1, 2^32 - 1] which are not usable as `mul` inputs (violates 2^32*P bound).

- **Reverse twiddle slice instead of `.rev()` in `dit_layer_rev`** (analyzed):
  Rust's `Zip::next_back()` already aligns mismatched-length iterators correctly,
  so reversing the twiddle slice is equivalent to forward iteration.

- **Memory-bandwidth bottleneck** (analyzed repeatedly):
  Compute bound ~1.38s (640M vec ops × 13 instructions at 3GHz/IPC-2), observed 2.677s.
  Gap is memory bandwidth for large blocks. Twiddle slice prefetch already tried (−0.97%).
  Do not re-derive this analysis or attempt prefetch optimizations.

- **Combining `apply_to_rows_oop` with `ScaledDitButterfly`** : `first_half_general_oop` 
  calls `dit_layer_oop` which uses `DitButterfly`, not `ScaledDitButterfly`. 
  There is no scale in the forward DFT. Cannot apply.

- **Scalar×vector `mul` specialization when `rhs` is a broadcast** : 
  If `rhs` is a broadcast, `rhs_odd == rhs_evn`, so `movehdup_epi32(rhs)` is redundant. 
  Saves 1 instruction per mul. But LLVM already hoists `rhs_odd = movehdup_epi32(twiddle_packed)` outside 
  the apply_to_rows loop since `twiddle_packed` is loop-invariant. Net saving: 0.

- **`backwards` bool via const generics** (analyzed):
  Making `backwards` a const generic to specialize `dit_layer_rev`. LLVM already hoists
  the `if backwards` branch outside the inner loop. Zero benefit.

- **`TwiddleFreeButterfly` anywhere in coset forward DFT** (analyzed):
  For `first_half_general`, `first_half_general_oop`, `second_half_general` — twiddles[layer][0]
  = `shift^{2^layer}` where `shift ≠ 1`. None are 1. Cannot apply.

- **`TwiddleFreeButterfly` last layer of `second_half`** (analyzed):
  For the non-coset IDFT last layer (layer_rev=0), only 1 block out of 512 per thread has
  twiddle=1 (thread 0, block 0 only). Not worth specializing.

- **`ScaledDitButterfly` in `second_half_general`** (analyzed):
  No scale in the forward coset DFT path. Cannot apply.

- **`ScaledDitButterfly` in `first_half_general`** (analyzed):
  No scale in forward DFT. Cannot apply.

- **`ScaledTwiddleFreeButterfly` for thread 0 block 0 in `second_half`** (analyzed):
  Thread 0's first block has twiddle=1 so twiddle_times_scale=scale. Saves 512 muls
  out of 503M total — negligible.

- **Two row-pairs simultaneously for ILP in `apply_to_rows`** (analyzed):
  Unrolling by 2 to pipeline the 21-cycle mul latency. LLVM already pipelines independent
  chains across iterations automatically. No gain.

- **`DifButterflyZeros` in hot path** (analyzed):
  Not called anywhere in the `coset_lde_batch` hot path. Irrelevant.

- **`confuse_compiler` prevents LLVM hoisting twiddle-derived computations** (analyzed):
  `confuse_compiler` is applied to `prod * MU` where `prod` depends on `lhs` (changes each
  iter). The only hoistable rhs computation is `rhs_odd = movehdup_epi32(rhs)`, which
  LLVM already hoists since `twiddle_packed` is loop-invariant.

- **Remove `backwards` from `dit_layer_rev` / `dit_layer_rev_scaled`** (iter #008, -3.88%):
  These use per-block unique twiddles from an outer iterator. Reversing blocks+twiddles
  together (`.rev()` on the zip) IS different from forward-only when correctness is needed.
  Also produced worse codegen.

- **Exact-slice twiddle for `dit_layer_rev` backwards alignment** (analyzed):
  Zip::next_back() alignment via nth_back() on a slice iterator is O(1) (pointer arithmetic).
  Passing exact-length slice instead of [first_block..] has negligible overhead.

- **Port 0 pressure further reduction beyond iter #001** (analyzed):
  The masked vpaddd/vpsubd instructions in Add/Sub and mul underflow correction
  all require port 0. No known instruction sequence achieves the same result on port 5 only.
  vpblendmd (port 5) + vpaddd (port 0) = 2 instructions vs 1 masked instruction, no net gain.

- **Non-temporal stores in apply_to_rows_oop** (analyzed):
  dst data is read again soon (subsequent butterfly layers), so NT stores would cause
  cache misses on the next read. Not applicable.

### Run 1 eliminations (from CLAUDE.md)

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

- **Add/sub mask-based approach in monty-31** (iter 1 monty — result NOT valid):
  Code was dead (never called from hot path). 
