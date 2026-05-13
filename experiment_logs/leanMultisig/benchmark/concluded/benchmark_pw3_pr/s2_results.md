# S2 implementation: skip `padded_data` materialization

**Date:** 2026-05-08
**Patch:** `crates/rec_aggregation/zkdsl_implem/hashing.py`, +40 / −7 lines
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig`
**Binary:** `/tmp/bench_s2_patch` (md5 `72b720d6677477f3b4fb4676ee0b91f8`, distinct from bundle)
**Workload:** `fancy-aggregation --json`, 5 runs (single-process invocation each, fresh)

## Patch summary

Added `slice_hash_rtl_rate12_pad8(data, data_len, n_chunks_12)` that runs the MMO sponge directly over `data` without materializing a `padded_data` buffer. The 8 trailing zero pads survive only in the initial-state's high half, which is built directly into a 16-element `init_state`. The inner loop reads chunks straight from `data`, which is correct because `chunk_idx * 12 + 12 ≤ data_len` for all supported `(num_chunks, n_chunks_12)` pairs.

The `slice_hash_rtl_rate12` dispatcher routes the padded branch through the new helper. The no-pad branch is unchanged. `slice_hash_rtl_rate12_no_pad` is unchanged.

## Cycle results — the trace boundary

`*` marks nodes whose CPU table commits at 2^20 = 1,048,576 rows (i.e., crossed the 2^19 = 524,288 boundary).

```
path        baseline       c4 (RATE12)    c5 bundle     S2 patch     S2 vs bundle
0.0.0.0      994,842 *      994,842 *     994,842 *    994,842 *      0           (leaf, unchanged)
0.0.0        282,702        503,584       588,682 *    500,959        -87,723   (-14.9%)  ← was OVER, now UNDER ✓
0.0.1        251,801        408,024       472,979      415,631        -57,348   (-12.1%)
0.0.1.0      994,824 *      994,824 *     994,824 *    994,824 *      0
0.0          286,081        444,486       516,981      451,026        -65,955   (-12.8%)
0.1          243,008        394,652       456,624      399,276        -57,348   (-12.6%)
0            329,766        551,393 *     634,861 *    546,071 *      -88,790   (-14.0%)  ← STILL OVER (by 21,783)
root         109,703        192,594       226,757      198,083        -28,674   (-12.6%)
```

**S2 alone gets `0.0.0` (the largest recursion node) below 2^19 by 23,329 cycles.** It also drops every other recursion node by 12-14% on cycles. **`0` (the second-heaviest recursion node) is still 21,783 cycles over the boundary**, so the `0` subtree continues to hit the 2^20 trace and pays the doubled native-prover cost there.

Leaf nodes (`*.0`, `*.1`) are 0-cycle delta as expected — leaves do not run `slice_hash_rtl`. They were already fixed-cycle across all SHAs.

## Wall-clock results

`fancy-aggregation` per-node median time across 5 runs (seconds):

```
path        baseline   c4         c5 bundle  S2 patch   Δ vs bundle
0.0.0        1.2370     1.2185     1.9194     1.2441     -35.18%   ← cliff fixed
0.0.0.1      1.3418     1.2493     1.3238     1.3179      -0.44%
0.0.1        0.8497     1.1111     1.1339     1.1317      -0.19%
0.0          0.9633     0.9387     1.0115     0.9589      -5.20%
0.1          0.8529     1.1004     1.1323     1.1198      -1.11%
0            1.3649     1.9477     1.9924     1.9720      -1.02%   ← cliff still active
root         1.0241     1.2269     1.2612     1.2490      -0.96%
0.0.0.0      2.1620     2.1443     2.2604     2.2859      +1.13%
0.0.0.1      1.3418     1.2493     1.3238     1.3179      -0.44%
0.0.1.0      2.8788     2.7255     2.9469     2.9153      -1.07%
0.0.1.1      1.3316     1.2423     1.3171     1.3108      -0.48%
0.1.0        1.4241     1.3555     1.4459     1.4344      -0.80%
0.1.1        1.4208     1.3571     1.4454     1.4294      -1.11%
TOTAL       16.8510    17.6172    19.1901    18.3693      -4.28%
```

`0.0.0` collapses from 1.92s back to 1.24s — that's the trace-boundary cliff being undone. The 23K cycles between current count (500,959) and 2^19 mean its CPU table now packs to 2^19 rows instead of 2^20, halving the FFT/Merkle/sumcheck work for that node alone. This single fix is worth ~0.7s of wall-clock per fancy-aggregation run.

`0` still crosses the boundary so it doesn't get the cliff-undo benefit — its 1% wall-clock improvement is just the cycle reduction at constant trace size.

## Total regression vs baseline

```
                    total time     Δ vs main baseline
main (19f1c774)     16.8510 s       —
c4 (bdf43a62)       17.6172 s      +4.55%
c5 bundle           19.1901 s     +13.88%   ← original regression
S2 patch            18.3693 s      +9.01%   ← after S2
```

S2 alone recovers ~35% of the bundle regression (4.87 of 13.88 percentage points). Most of the remaining gap is the `0` node still crossing the boundary, plus the genuine MMO/AIR overhead and the c3 (FFT MDS) leaf regression — neither of which S2 was designed to address.

## Run-to-run variance

```
sha            mean      stdev    min        max
baseline      16.8620   0.0091   16.8482   16.8733
c4            17.6726   0.1436   17.5603   17.8688
c5 bundle     19.1933   0.0255   19.1709   19.2266
S2 patch      18.3821   0.0394   18.3254   18.4299
```

S2 stdev (0.039s) is tighter than c4 (0.144s) and looser than baseline/bundle (0.009-0.026s) but well below the +0.82s wall-clock improvement. The result is unambiguous, not noise.

## Correctness

- `recursion --tracing` (n=2): proof verified, no panic. Recursion-node cycles dropped 456,642 → 399,294.
- `fancy-aggregation --json` × 5 runs: all 12 nodes per run completed and the root proof verified (`run_aggregation_benchmark` calls `verify_type_1(&aggregated).expect(...)` at the end of every run, so a failure would have panicked).
- Total proof size: 2,624 KiB (bundle) → 2,605 KiB (S2 patch). The −19 KiB is consistent with the cliff-undo on `0.0.0`: smaller PCS commitment when the CPU trace shrinks one log step. No size change on leaves.
- Bytecode size: 253,755 (bundle) → 253,453 (S2). The −302 instructions are the unrolled padded-data copy/zero loops eliminated from `slice_hash_rtl_rate12`'s body.

## Per-call cycle accounting

For `num_chunks = 10` (the dominant padded path):

| Source | bundle cyc | S2 cyc | Δ |
|---|---:|---:|---:|
| Function-call dispatch (3 layers) | 30 | 20 (one fewer level — no_pad bypassed) | −10 |
| `padded_data = Array(88)` + 80 copies + 8 zero stores | 89 | 0 | −89 |
| `init_state = Array(16)` + 8 copies + 8 zero stores | 0 | 17 | +17 |
| `states = Array(7×16)` | 1 | 1 | 0 |
| Initial perm | 1 | 1 | 0 |
| Inner loop (6 iters × 18 cyc) | 108 | 108 | 0 |
| Total | 229 | 147 | **−82** |

Per-call cycle savings (num_chunks=10): ~82 cycles. With ~600 num_chunks=10 calls per `0.0.0`: ~49K cycles. Add similar but smaller savings on num_chunks=4 and num_chunks=16 padded paths and ~30K from the no-pad paths gaining one less function-call layer (because the dispatcher now branches earlier), and the total tracks the observed −87K cycles for `0.0.0`.

## Next step: closing the gap on node `0`

`0` is 21,783 cycles over the 2^19 boundary after S2. To push it below:

* **S1 — `@inline` `slice_hash_rtl_rate12_no_pad` and `slice_hash_rtl_rate12`.** Saves ~10-20 cycles per call by removing one or two function-call layers. With ~1,700 calls in `0`, that's 17K-34K cycles. Likely sufficient, but `slice_hash_rtl_rate12` has a multi-return-on-Const pattern that originally tripped the inliner bug — needs verification that current const-propagation eliminates one branch before inline expansion.
* **S3 — in-place state with `poseidon16_permute(state, state+8, state)` aliasing**, eliminating the per-iter `pre = Array(16)` and 4 capacity copies. Saves ~5 cyc/iter × n_chunks_12 × calls ≈ 30-40K cycles on `0`. Independent of S1.

Either S1 or S3 on top of S2 should put `0` below 2^19 and recover most of the remaining wall-clock regression on the `0` subtree. Recommend S3 first — it's compiler-bug-safe (single non-inlined function, no multi-return concerns).

## Files written/modified

```
modified: crates/rec_aggregation/zkdsl_implem/hashing.py            (+40 / −7)
new:      experiment_logs/leanMultisig/benchmark_pw3_pr/s2_results.md
new:      /tmp/bench_s2_patch                                       (lean-multisig binary)
new:      /tmp/bench_results_s2_patch.jsonl                         (5 fancy-aggregation runs)
```

## Reproducing

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig
cp target/release/lean-multisig /tmp/bench_s2_patch

# Quick correctness + cycle check (n=2 recursion):
/tmp/bench_s2_patch recursion --tracing 2>&1 | grep -E "Aggregation program|^CYCLES:|Bytecode size:|the final aggregation step"

# Full per-node fancy-aggregation matrix:
> /tmp/bench_results_s2_patch.jsonl
for i in 1 2 3 4 5; do
  /tmp/bench_s2_patch fancy-aggregation --json >> /tmp/bench_results_s2_patch.jsonl
done
```
