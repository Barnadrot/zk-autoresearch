# Experiment Results — Global Summary

Optimization target: `coset_lde_batch` on BabyBear, `Radix2DitParallel`, 2^20 × 256 columns.

---

## Cumulative Progress

| Experiment | Model | Iters | Baseline | Best | Gain | Validated |
|------------|-------|-------|----------|------|------|-----------|
| Round 1 | Sonnet 4.6 | 74 | 2724.4ms | 2642.8ms | −3.00% | cross-session p=0.00 ✓ |

---

## Round 1 — Kept Improvements (5 of 74 iterations)

| Iter | File(s) | Gain | Description |
|------|---------|------|-------------|
| 1 | butterflies.rs, radix | +0.06% | ScaledDitButterfly — merge 1/N scaling into first butterfly layer |
| 6 | butterflies.rs, radix | +0.96% | Precompute twiddle×scale in ScaledDitButterfly::new(), reduce multiplications 3→2 |
| 9 | butterflies.rs | +0.73% | Pre-broadcast twiddle into packed field once before inner loop in DitButterfly::apply_to_rows |
| 16 | radix | +0.40% | TwiddleFreeButterfly for layer 0 of first_half — eliminates Montgomery mul where twiddle=1 |
| 21 | butterflies.rs | +0.58% | Pre-broadcast on ScaledDitButterfly — unlocked by iter 16/19 changing surrounding code paths |

---

## Multi-Size Validation — Round 1 (cross-session, run_benchmark.sh)

| Size | Baseline | Optimized | Change | p |
|------|----------|-----------|--------|---|
| 2^20 × 256 | 2724.4ms | 2642.8ms | −3.00% | 0.00 |

> Multi-size run pending for Round 1 standalone. Round 2 multi-size results archived in `discarded/table_rounds1-2.md`.
