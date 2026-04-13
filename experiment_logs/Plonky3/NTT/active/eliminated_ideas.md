// eliminated_ideas.md

## Eliminated ideas (do not re-attempt)

### Run 1 eliminations (from CLAUDE.md)

- **Broad restructuring of `second_half_general` / `first_half_general`** (9 attempts, −0.58% to −2.02%)
- **Pre-reverse twiddle slice for sequential prefetcher access** (tried twice, −0.97%)
- **Fuse `layer_rev==3` and `layer_rev==2` (`dit_layer_rev_pair32`)** (−1.22%): Fusing two adjacent butterfly layers in second_half.
- **Manual loop unroll** (−49.4%): Manually unrolling the butterfly inner packed loop.
- **`#[inline(always)]` on butterfly functions** (regressed)
- **Remove `backwards` bool from `dit_layer_rev`** (broke correctness): The backwards flag changes block-twiddle pairing via `.rev()` on zip iterator.
- **Boundary-layer specialization (`dit_layer_rev_base`, `dit_layer_oop_base`)** (−0.68% to −0.73%)
- **Pre-broadcast hoisting outside per-block loop** (−0.73% to −0.92%)
- **`DifButterfly::apply_to_rows` pre-broadcast** (borderline, targets wrong path)

### Run 2 ideas considered but not attempted

- **TwiddleFreeButterfly in second_half for thread 0**: Only benefits 1 of 1024 threads. Too small impact.
- **Software prefetching in butterfly loops**: Hardware prefetcher handles sequential access well. Likely to regress.
- **Eliminate reverse_matrix_index_bits by fusing into first layer of second_half**: Would require non-sequential memory access in butterfly, defeating the purpose.

### Run 2, Experiment 2

- Attempted: **Extend layer fusion from 2 layers (0+1) to 3 layers (0+1+2) in `first_half_general` and `first_half_general_oop`**. Processes 8 rows at once instead of 4, applying layers 0, 1, and 2 in registers before writing back. Saves one additional full-matrix memory pass per coset DFT invocation.

### Run 2, Experiment 3

- Note: **Fuse `layer_rev==3` and `layer_rev==2`** was tried in Run 1 and regressed (−1.22%). That targeted middle-sized blocks (half_block=4 and 8). The current experiment targets the LAST two layers (layer_rev=0 and 1, half_block=1 and 2) in `second_half_general`, which is a fundamentally different fusion (smallest blocks, most memory pressure per block).

### Run 2, Experiment 4 — ideas considered

- **Reduce Montgomery multiplications algebraically in fused layer kernel**: The 4-mul structure in dit_fused_layers_0_1 is already optimal; alternative factorizations use ≥5 muls.
- **Process two row-pairs simultaneously for ILP**: The compiler and CPU OOO execution already handle this.
- **Specialize dit_layer_rev for layer_rev=0**: Function is already inlined; no overhead to eliminate.
- **Backwards flag removal**: Actually appears correctness-safe (Zip.rev preserves pairing), but was already tried in Run 1 and broke correctness through some other mechanism.

### Run 2, Experiment 5 — ideas considered but not implemented

- **Precompute rhs_odd in Montgomery mul for broadcast constants**: The `movehdup_epi32` on a broadcast constant is a no-op that the compiler likely eliminates. Even if emitted, runs on port 5, not the bottleneck port 0.
- **Fuse reverse_matrix_index_bits into OOP write**: Requires random writes (rows go to bit-reversed positions across all chunks), which trades one random-access pattern for another. Net effect uncertain and complex to implement.
- **Fuse layers 2+3 separately after fused 0+1**: Group of 16 rows = 16 registers for data + 12 for twiddles = 28 registers. Tight but feasible. However, similar to 3-layer fusion which regressed in experiment 2.
- **AVX512-level mul_by_constant specialization**: Would save at most 1 `vmovshdup` per mul (runs on port 5, ~0 throughput impact since port 0 is bottleneck with 6 `vpmuludq` instructions).

### Run 2, Experiment 6 — ideas considered

- **Algebraic restructuring of fused 0+1 kernel to make all 4 muls independent**: Requires 5 muls instead of 4, which tips the fused kernel from memory-bound to further into compute-bound territory. Analysis shows per-group compute (416 cyc for 4 muls) is already comparable to memory time (492 cyc), so adding a 5th mul (520 cyc) would regress.
- **Fuse layers 0+1 in inverse DFT's first_half**: Already tried (experiment #4, -1.84%). The inverse DFT's layer 0 is twiddle-free (0 muls), making the unfused version so lightweight that it acts as a free prefetch pass.
- **Change mid value for different first_half/second_half chunk sizes**: mid is baked into twiddle computation, would require coordinated changes everywhere. Too complex, uncertain benefit.
- **Batch multiple coset DFTs' second_half_general calls for cache reuse**: Different cosets use different twiddles, so twiddle reuse doesn't apply. Data matrices are each 1 GB, interleaving would thrash L2.
- **Inline DitButterfly::apply_to_rows into dit_layer_rev**: Already inlined by compiler. No overhead to eliminate.
- **Precompute packed slices to avoid pack_slice_with_suffix_mut overhead**: The packing is just a pointer cast + length check, compiler optimizes it away entirely.

### Run 2, Experiment 7 — ideas considered

- **Split bit-reversal into inter-chunk + intra-chunk for OOP path**: Mathematically incorrect decomposition. `reverse(chunk || local) = reverse(local) || reverse(chunk)`, NOT `reverse(chunk) || reverse(local)`. The bit-reversal mixes chunk and local bits, making it impossible to decompose into independent per-chunk operations.
- **Fuse last two layers of first_half_general (layers mid-2, mid-1)**: Block sizes are 256 and 512 half-rows respectively; too large to hold in registers. Would require 1024 AVX512 registers but only 32 available.
- **Non-temporal stores in OOP write**: Data is immediately reused by subsequent in-place layers within the same thread, so bypassing cache would force DRAM reads. Only helps when data is not reused.
- **Reduce multiplications in fused 0+1 kernel below 4**: Algebraically proven impossible; 4 distinct products are needed.
- **Pre-touch destination pages before parallel OOP DFTs**: Page faults are distributed across parallel threads (~100µs per thread), negligible compared to 2680ms total.

### Run 2, Experiment 8 — ideas considered

- **Unroll outer loop in fused 0+1 kernel to process 2 groups (8 rows) simultaneously**: Would improve ILP at group boundaries by hiding pipeline drain/fill. But outer loop has 256 iterations and each group takes ~416 cycles of compute; ROB can overlap ~1.7 iterations already. Boundary overhead is ~0.3% of total. Too small to matter.
- **Split bit-reversal into intra-chunk + inter-chunk phases**: Actually decomposition IS correct: `reverse(chunk||local) = reverse(local)||reverse(chunk)`. Phase 1 (intra-chunk) could be fused into OOP write. But phase 2 (inter-chunk swap) involves 512 swaps of 1MB chunks — similar total data movement to original. Uncertain benefit, high complexity.
- Previous experiment 7 (move scaling to last layer) had `tests_failed` due to usize underflow in `let last_layer = log_h - 1` when `log_h == 0`. Re-attempting with proper guard.

### Run 2, Experiment 9 — ideas considered

- **Use `mul_neg_2exp_neg_n_avx512` to replace scale multiplication in ScaledDitButterfly**: For scale=1/2^20, could use two `mul_neg_2exp_neg_n` calls (6 cyc vs 6.5 cyc for Monty mul). But: (a) second call requires canonical input and first outputs [0,P] not [0,P), needs extra canonicalization; (b) savings of 0.5 cyc per vector × 1 thread's first layer = negligible total impact (~0.006%).
- **Use dot_product_2 for ScaledDitButterfly**: `dot_product_2` is 9.5 cyc for l0*r0+l1*r1 vs 2×6.5=13 cyc for two independent muls. But need both sum AND difference, requiring 2 calls = 19 cyc vs 13 cyc. Worse.
- **Parallelize across cosets**: Each coset DFT already saturates all Rayon threads via `par_row_chunks_exact_mut`. Running multiple cosets simultaneously would cause thread contention.
- **Specialize dit_layer for layer=2 with TwiddleFreeButterfly for first row-pair**: Only applicable to non-coset (inverse) DFT where twiddles[0]=1. In coset DFTs, twiddles include coset shift so twiddles[0]≠1. Already optimized for the inverse DFT case via `dit_layer_first_one`.
- **Reorder operations in fused 0+1 kernel for ILP**: Critical path is 44 cyc (2 serial muls + 2 adds) but with 16 packed iterations per group, OOO overlaps ~4 iterations. Throughput (26 cyc/iter × 16 = 416 cyc) dominates. Reordering won't help.
- **Fuse reverse_matrix_index_bits into OOP write of first_half_general_oop**: Writing to bit-reversed positions scatters writes across 1 GB, causing cache thrashing. Each 4-row group writes to 4 random cache lines. Much worse than sequential write + separate bit-reversal.

### Run 2, Experiment 10 — ideas considered but not implemented

- **Eliminate bounds checks in fused kernel with unsafe get_unchecked**: The bounds checks from `split_at_mut` are trivially predicted by branch predictor (always pass). Eliminating them saves ~0 cycles in practice.
- **Reorder stores in DitButterfly::apply_to_rows**: `shorts_1` and `shorts_2` are from different rows, writes alternate between two separate memory regions. No store combining benefit from reordering.
- **Add #[inline(always)] to Mul/Add/Sub for PackedMontyField31AVX512**: Already has `#[inline]`, and with cross-crate monomorphization these are always inlined. Would not change codegen.
- **Change mid value (9 or 11 instead of 10)**: For log_h=20, mid=9 means second_half chunks are 2 MB (may exceed L2), mid=11 means first_half chunks are 2 MB. Current mid=10 gives 1 MB chunks that fit L2. Changing risks pushing one half out of L2.
- **Reorder coset DFT operations (all first_halves before all second_halves)**: Each matrix is 1 GB >> L3 (30 MB), so separating phases provides no cache reuse benefit. At most saves 30 MB of reads (~1ms, 0.04%).
- **Process two groups simultaneously in fused 0+1 kernel for MLP**: 8 rows = 8 data registers + 3 twiddle registers = 11 ZMM registers (of 32). Feasible, but OOO already overlaps adjacent groups at loop boundary. Marginal benefit (~0.3% of a single function's time).

### Run 2, Experiment 11 — ideas considered

- **Reorder DitButterfly::apply_to_rows writes (r0,r2,r1,r3 → r0,r1,r2,r3)**: No effect — OOO processor and compiler reorder stores freely. Live ranges unchanged.
- **Remove unused PackedField import**: No performance effect.
- **Pre-broadcast all twiddles for dit_layer at layer=2**: All blocks use the same 4 twiddles. But DitButterfly::apply_to_rows already pre-broadcasts per call. 508 extra broadcasts at 1 cyc each on port 5 = negligible.
- **Batch ALL first_half_general_oop layers for multiple cosets**: Experiment 5 showed -2.84% because interleaving 8+ in-place passes across cosets thrashes L2 cache. The current iteration tries batching ONLY the fused OOP layer (1 pass), not subsequent in-place layers.

### Run 2, Experiment 12 — ideas considered

- **Move `reserve_exact` before inverse DFT**: The reallocation copies 1 GB of data regardless of timing. On Linux with large allocations, `realloc` uses `mremap` which is essentially free (no copy). Moving it earlier doesn't save time and risks working on cold memory during the inverse DFT.
- **Use `mul_neg_2exp_neg_n_avx512` for scale=1/2^20**: N=20 exceeds the N<15 constraint for BabyBear (r=15, j=27). Would need decomposition into two calls (N=10 each) with canonicalization between, totaling ~9 cyc vs 13 cyc for 2 Monty muls. But only applies to 1 layer of the inverse DFT's second_half — negligible total impact.
- **ScaledTwiddleFreeButterfly for twiddle=1 case**: When twiddle=1, ScaledDitButterfly does `x1*scale + x2*scale` and `x1*scale - x2*scale` using 2 muls. Alternative `(x1+x2)*scale, (x1-x2)*scale` also uses 2 muls. No savings possible.
- **Decompose bit-reversal into intra-chunk + inter-chunk**: Even with correct decomposition `reverse(chunk||local) = reverse(local)||reverse(chunk)`, the inter-chunk phase still requires swapping 512 pairs of 1 MB chunks across 1 GB, with similar total data movement to the original full bit-reversal.
- **Specialize dit_layer_rev for layer_rev=0 (last layer, half_block=1)**: Each block is just 1 row-pair with 16 packed iterations. Already inlined by compiler; DitButterfly is Copy with zero overhead. 512 calls × 16 iterations each; OOO processor overlaps consecutive calls perfectly.
- **Pad coset twiddle arrays to avoid false sharing**: Twiddles are read-only during DFTs; no false sharing occurs on read-only data.
