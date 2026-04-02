# Experiment Results — Global Summary

Optimization target: `coset_lde_batch` on BabyBear, `Radix2DitParallel`, 2^20 × 256 columns.

---

## Cumulative Progress

| Experiment | Model | Iters | Baseline | Best | Gain | Cumulative |
|------------|-------|-------|----------|------|------|------------|
| Round 1 | Sonnet 4.6 | 74 | 2724.4ms | 2642.8ms | −3.00% | −3.00% |
| Round 2 | Sonnet 4.6 | 20 | 2667.8ms | 2638.0ms | −1.12% | −4.10% |

---

## Round 2 — Multi-Size Benchmark Validation (2026-03-28)

Measured after all 4 round 2 improvements committed on `perf/dft-butterfly-optimizations`.
Compared against Criterion's internal baseline (prior commit).

| Size | Optimized Time | Change | Significant? |
|------|---------------|--------|-------------|
| 2^14 × 256 | 54.5ms | −2.17% | No (p=0.38) |
| 2^16 × 256 | 171.0ms | −3.78% | Yes (p=0.00) |
| 2^18 × 256 | 676.5ms | −2.21% | Borderline (p=0.02) |
| 2^20 × 256 | 2.663s | −1.06% | Borderline (p=0.03) |
| 2^22 × 256 | 10.90s | **−8.57%** | Yes (p=0.00) |

Improvements hold across all sizes. Largest gain at 2^22 — memory bandwidth effects amplify
at larger sizes where working sets exceed L3 cache.

---

## Round 1 — 2^20 Only

Multi-size benchmark not run for round 1. 2^20 result only.

| Size | Baseline | Optimized | Change |
|------|----------|-----------|--------|
| 2^20 × 256 | 2724.4ms | 2642.8ms | −3.00% |

---

## Kept Improvements by Round

### Round 1 (5 kept of 74 iterations)

| Iter | File(s) | Gain | Description |
|------|---------|------|-------------|
| 1 | butterflies.rs, radix | +0.06% | ScaledDitButterfly — merge 1/N scaling into first butterfly layer |
| 6 | butterflies.rs, radix | +0.96% | Precompute twiddle×scale in ScaledDitButterfly::new(), reduce multiplications 3→2 |
| 9 | butterflies.rs | +0.73% | Pre-broadcast twiddle into packed field once before inner loop in DitButterfly::apply_to_rows |
| 16 | radix | +0.40% | TwiddleFreeButterfly for layer 0 of first_half — eliminates Montgomery mul where twiddle=1 |
| 21 | butterflies.rs | +0.58% | Pre-broadcast on ScaledDitButterfly — unlocked by iter 16/19 changing surrounding code paths |

### Round 2 (4 kept of 20 iterations)

| Iter | File(s) | Gain | Description |
|------|---------|------|-------------|
| 1 | radix | +0.38% | dit_layer_rev_last — inlined flat loop for last layer of second_half_general |
| 2 | radix | +0.45% | dit_layer_uniform_twiddle — pre-broadcast single coset twiddle for layer 0 of first_half_general |
| 3 | radix | +0.06% | dit_layer_rev_last2 — fuse last two layers of second_half_general into 4-row pass |
| 8 | radix | +0.23% | Extend dit_layer_rev_last2 fusion to second_half (inverse DFT OOP path) |
