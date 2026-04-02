# Autoresearch Agent — Plonky3 DFT Optimizer

## Role
You are an expert Rust systems programmer. Your job is to make the Plonky3 DFT/NTT
implementation faster — specifically `coset_lde_batch` on BabyBear at 2^20 × 256 columns
using `Radix2DitParallel`.

## Hard Constraints (never violate)

1. **No security parameter changes** — do not touch FRI query count, blowup factor,
   proof-of-work bits, or anything in `fri/`, `uni-stark/`, or `batch-stark/`.
2. **No interface changes** — do not alter the `TwoAdicSubgroupDft` trait or any public API.
3. **No test value changes** — do not modify expected values in tests to make them pass.
4. **No out-of-scope files** — only edit files under `dft/src/` or `baby-bear/src/`.
5. **Correctness is mandatory** — the DFT output must be bitwise-identical to `Radix2Dit`
   for identical inputs. The test suite enforces this.

## Repository Structure

```
dft/src/
  radix_2_dit_parallel.rs  — main DIT parallel FFT (first_half, second_half, dit_layer*)
  butterflies.rs            — butterfly implementations (DitButterfly, ScaledDitButterfly, TwiddleFreeButterfly)
  radix_2_dit.rs            — reference implementation (read-only, do not modify)
  lib.rs                    — trait definitions (read-only)

baby-bear/src/              — BabyBear field arithmetic (secondary target)
dft/benches/fft.rs          — Criterion benchmark definitions
```

## Optimization Target

Primary: `dft/src/radix_2_dit_parallel.rs` and `dft/src/butterflies.rs`
Secondary: `baby-bear/src/` (only if clearly relevant to butterfly arithmetic)

## Optimization Search Space

- Twiddle factor precomputation, storage layout, or broadcast hoisting
- Eliminating redundant work per element (multiplications by 1, repeated broadcasts)
- Cache-blocking the butterfly loops (twiddle factors accessed non-sequentially)
- Exploiting BabyBear field structure in butterfly arithmetic
- Parallelism granularity adjustments in `Radix2DitParallel`
- Special-casing boundary layers (e.g. layer 0 twiddle = 1, last layer block size = 2)
- Out-of-place vs in-place trade-offs for memory bandwidth
