# Final verdict: S2+S3 hashing.py optimizations

**Date:** 2026-05-08
**Branch:** `fix/s123-hashing-opt` (off of `pr/perf-bundle` = 4175b20a)
**Patch:** `crates/rec_aggregation/zkdsl_implem/hashing.py`, +48 / −11 lines
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig`

S1 was attempted (see `s1_results.md`) and reverted: `@inline` is incompatible with `: Const` arguments per the compiler (`crates/lean_compiler/src/a_simplify_lang/mod.rs:539-544`), and stripping `: Const` to allow `@inline` triggered the multi-return fall-through bug at runtime in `slice_hash_rtl_rate12`. Final shipped patch is **S2 + S3 only**.

## The one number that matters

```
fancy-aggregation total time (3 fresh runs each, same hardware, single session):

main baseline (19f1c774):
  run 1: 17.0415 s
  run 2: 17.1022 s
  run 3: 17.0915 s
  median: 17.0915 s

S2+S3 patch:
  run 1: 18.3420 s
  run 2: 18.3972 s
  run 3: 18.3716 s
  median: 18.3716 s

S2+S3 is +1.2801 s (+7.49%) SLOWER than main baseline.
```

For comparison from earlier runs on the same hardware:

```
c5 bundle (4175b20a, no patch): 19.1826 s median  →  +12.24% vs main baseline
S2+S3 patch:                    18.3716 s median  →   +7.49% vs main baseline
```

S2+S3 recovers ~39% of the c5 bundle's wall-clock regression. Bundle was +1.97 s over main; S2+S3 is +1.28 s over main.

## Trace boundary outcome

```
path        baseline   c5 bundle   S2+S3      crosses 2^19?
0.0.0        282,702    588,682 *  492,656    bundle: OVER → S2+S3: UNDER ✓ (cliff fixed)
0.0.1        251,801    472,979    410,203    under in both
0.0          286,081    516,981    445,598    under in both
0.1          243,008    456,624    393,848    under in both
0            329,766    634,861 *  537,814 *  bundle: OVER → S2+S3: STILL OVER (by 13,526) ✗
root         109,703    226,757    195,369    under in both
```

**One node (`0`) is still 13,526 cycles over the 2^19 boundary** even with S2+S3 applied. That node continues to commit at 2^20 trace rows, paying ~2× native prover cost there. This is why total wall-clock is still +7.49% above main rather than approximately flat.

## Why S2+S3 is FASTER than bundle (+12.24% → +7.49%)

`0.0.0` was the heaviest cliff-affected node: 1.92 s in bundle vs 1.24 s in baseline. S2 alone got `0.0.0`'s cycles below 2^19 (588,682 → 500,959) and unhalved its native prover work, recovering 0.68 s wall-clock. S3 added ~13K more cycle savings across all nodes. Together the two optimizations recover ~0.81 s of the 2.32 s regression.

## Why S2+S3 is still SLOWER than baseline (+7.49% remaining)

Three components, in descending order of contribution:

1. **Node `0` still over the cliff (~0.6 s).** Same RATE=12+MMO recursion cost story as bundle: 537,814 cycles maps to 2^20 rows, paying double the FFT/Merkle/sumcheck work in native code. Closing this requires either a compiler bug fix (allow `@inline` on multi-return-on-Const dispatchers) or a new precompile that folds capacity copies into the perm row. Neither is in this patch.
2. **MMO-irreducible work (~0.4 s).** Even after S2+S3, every recursion proof's verifier program does the 12-element rate XOR + permute that didn't exist in main (which used RATE=8). This is structurally inside the MMO design — cannot be optimized in zk-DSL without changing the sponge.
3. **c3 (FFT MDS) leaf regression (~0.3 s).** A2dc0cfe regressed every leaf by +3-5% vs main. S2+S3 doesn't touch this — it's a native AIR-eval change, not a zk-DSL change. See `investigation.md` §4.4.

## Patch shape

```python
# slice_hash_rtl_rate12 dispatcher (unchanged decorators):
def slice_hash_rtl_rate12(data, data_len: Const, padded_len: Const, n_chunks_12: Const):
    if padded_len == data_len:
        return slice_hash_rtl_rate12_no_pad(data, padded_len, n_chunks_12)
    return slice_hash_rtl_rate12_pad8(data, data_len, n_chunks_12)   # NEW route

# NEW: skips materializing padded_data; uses ZERO_VEC_PTR for the high
# half of the initial state; hoists per-iter `pre = Array(16)`.
def slice_hash_rtl_rate12_pad8(data, data_len: Const, n_chunks_12: Const):
    states = Array((n_chunks_12 + 1) * 16)
    poseidon16_permute(data + data_len - 8, ZERO_VEC_PTR, states)   # S3 (a)
    pres = Array(n_chunks_12 * 16)                                  # S3 (b) hoist
    for j in unroll(0, n_chunks_12):
        chunk_idx = n_chunks_12 - 1 - j
        for k in unroll(0, 4):
            pres[j * 16 + k] = states[j * 16 + k]
        for k in unroll(0, 12):
            pres[j * 16 + 4 + k] = states[j * 16 + 4 + k] + data[chunk_idx * 12 + k]
        poseidon16_permute(pres + j * 16, pres + j * 16 + 8, states + (j + 1) * 16)
    return states + n_chunks_12 * 16

# slice_hash_rtl_rate12_no_pad: same hoisted-pres rewrite (S3 only; no padding logic).
```

## Correctness

- 6 fancy-aggregation runs total (3 baseline + 3 patched), 12 nodes each: every root proof verified (`verify_type_1` panics on failure; no panics observed).
- Recursion --tracing (n=2): cycles 393,866; proof verified.
- Total proof size: 2,604 KiB (S2+S3) vs 2,624 KiB (bundle) vs 2,571 KiB (baseline).

## Recommendation

The patch is a real win vs the c5 bundle (−4.45 percentage points of regression) but is **not a full restoration** of main-baseline performance. Three options going forward:

1. **Merge as a partial fix.** S2+S3 is strictly better than the bundle on every metric and does not change the security argument. Document the residual `0`-node cliff and the c3/MMO native costs as known accepted regressions.
2. **Keep S2+S3 + close the `0` cliff.** Requires a compiler change (allow `@inline` on multi-return-on-Const dispatchers, or fix the multi-return fall-through bug). Estimated additional ~17 K cycles savings on `0`, sufficient to cross under 2^19. Closes most of the residual gap.
3. **Revisit c4+c5 wholesale.** Baseline RATE=8 + capacity=8 already provides 124-bit collision security per `c × log2(p)/2`. The MMO design (c4 dropped capacity to 4 to gain RATE=12 throughput; c5 added MMO to recover security) is net negative on the recursion verifier even after full optimization. Reverting to RATE=8 makes the regression vanish at zero security cost. See `investigation.md` §4 and `solutions_analysis.md` §4 for the full security argument.

Option 3 is the cleanest if the security argument holds up under review.

## Files

```
modified: crates/rec_aggregation/zkdsl_implem/hashing.py            (+48 / −11)
new:      experiment_logs/leanMultisig/benchmark_pw3_pr/s123_final_results.md
new:      /tmp/bench_s23_final  (binary, md5 8d5e5823326517673fd278990edeb2ec)
new:      /tmp/bench_results_baseline_final.jsonl  (3 runs)
new:      /tmp/bench_results_s23_final.jsonl       (3 runs)
```
