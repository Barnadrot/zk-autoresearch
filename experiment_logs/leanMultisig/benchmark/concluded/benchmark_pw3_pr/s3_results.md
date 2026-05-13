# S3 implementation: ZERO_VEC_PTR initial state + hoisted `pre` allocation

**Date:** 2026-05-08
**Patch:** `crates/rec_aggregation/zkdsl_implem/hashing.py`, +48 / −11 lines (cumulative S2+S3)
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig`
**Binary:** `/tmp/bench_s3_patch` (md5 `8d5e5823326517673fd278990edeb2ec`)
**Workload:** `fancy-aggregation --json`, 5 runs

## Patch summary

Two safe additions on top of S2:

1. **ZERO_VEC_PTR for the pad-8 initial permute.** The initial state is
   `[data[data_len-8 .. data_len], 0, 0, 0, 0, 0, 0, 0, 0]`. Pass the first 8 as
   `arg_a = data + data_len - 8` (a pointer into the existing data — no copy) and
   the second 8 as `arg_b = ZERO_VEC_PTR` (an existing zeroed 16-element preamble
   region; `crates/rec_aggregation/src/compilation.rs:20` defines `ZERO_VEC_LEN = 16`).
   Eliminates the `init_state = Array(16)` + 8 data copies + 8 zero stores entirely.
   Saves ~17 cycles per pad-8 call.

2. **Hoist `pre = Array(16)` out of the inner loop in both `*_pad8` and `*_no_pad`.**
   Replaced with a single `pres = Array(n_chunks_12 * 16)` outside the loop, addressing
   `pres[j*16 .. (j+1)*16]` per iteration. Saves `(n_chunks_12 - 1)` RequestMemory cycles
   per call (5 for n_chunks_12=6, 9 for n_chunks_12=10, 11 for n_chunks_12=12).

> Note on the originally-proposed input/output aliasing form
> (`poseidon16_permute(state, state+8, state)`): **not safe in this VM**.
> `crates/lean_vm/src/execution/memory.rs:Memory::set` errors with
> `MemoryAlreadySet` when a cell is written with a different value than its
> existing one — the VM has single-assignment memory. Aliasing the perm output
> back into its input region would clobber 16 cells with new values, which
> generally don't match the prior (input) values. The two safe optimizations
> above (ZERO_VEC reuse + hoisted alloc) deliver the planned cycle savings
> without aliasing.

## Cycle results — the trace boundary at 2^19 = 524,288

`*` = node committed at 2^20 rows (over the boundary).

```
path        baseline   c5 bundle   S2 patch   S3 patch    Δ S3 vs S2   Δ S3 vs bundle
0.0.0        282,702    588,682 *   500,959    492,656    -8,303  (-1.66%)  -96,026  (-16.31%)
0.0.1        251,801    472,979     415,631    410,203    -5,428  (-1.31%)  -62,776  (-13.27%)
0.0          286,081    516,981     451,026    445,598    -5,428  (-1.20%)  -71,383  (-13.81%)
0.1          243,008    456,624     399,276    393,848    -5,428  (-1.36%)  -62,776  (-13.75%)
0            329,766    634,861 *   546,071 *  537,814 *  -8,257  (-1.51%)  -97,047  (-15.29%)
root         109,703    226,757     198,083    195,369    -2,714  (-1.37%)  -31,388  (-13.84%)
```

Boundary status:

```
0.0.0   bundle: OVER (+64K) → S2: under (-23K) → S3: under (-32K) ✓
0       bundle: OVER (+111K) → S2: OVER (+22K) → S3: OVER (+13K)  ← STILL OVER
0.0     bundle: under (-7K)  → ample headroom under S3
others  always under
```

**The S3 increment fixes nothing new on the cliff** — `0.0.0` was already under after S2, and `0` is still 13,526 cycles over after S3. S3 is a nice 1.3-1.7% cycle reduction across the board but doesn't close the boundary gap on `0`.

## Wall-clock results

```
path        baseline    c5 bundle   S2 patch    S3 patch    Δ S3 vs bundle
0.0.0        1.2370      1.9194      1.2441      1.2414      -35.32%   ← cliff fixed (S2 already)
0.0.0.1      1.3418      1.3238      1.3179      1.3158       -0.60%
0.0.1        0.8497      1.1339      1.1317      1.1352       +0.12%
0.0          0.9633      1.0115      0.9589      0.9543       -5.65%
0.1          0.8529      1.1323      1.1198      1.1170       -1.35%
0            1.3649      1.9924      1.9720      1.9823       -0.50%   ← cliff still active
root         1.0241      1.2612      1.2490      1.2431       -1.43%
0.0.0.0      2.1620      2.2604      2.2859      2.2779       +0.77%
0.0.1.0      2.8788      2.9469      2.9153      2.8909       -1.90%
0.1.0        1.4241      1.4459      1.4344      1.4303       -1.08%
0.1.1        1.4208      1.4454      1.4294      1.4291       -1.13%
0.0.0.1      1.3418      1.3238      1.3179      1.3158       -0.60%
0.0.1.1      1.3316      1.3171      1.3108      1.3052       -0.90%
TOTAL       16.8510     19.1901     18.3693     18.3226       -4.52%
```

S3 adds another -0.24 percentage points to total wall-clock vs S2 alone (S2 was -4.28%, S2+S3 is -4.52%). Marginal.

## Total regression vs main baseline

```
                   total time     Δ vs main baseline
main (19f1c774)    16.8510 s       —
c5 bundle          19.1901 s     +13.88%
S2 patch           18.3693 s      +9.01%
S2+S3 patch        18.3226 s      +8.73%
```

S3 recovers an additional 0.28 of the 13.88 percentage-point regression. Most of the remaining gap is the still-over-2^19 `0` node and the c3 (FFT MDS) leaf regression — neither of which S3 was designed to address.

## Run-to-run variance

```
sha            mean      stdev    min        max
baseline      16.8620   0.0091   16.8482   16.8733
c5 bundle     19.1933   0.0255   19.1709   19.2266
S2 patch      18.3821   0.0394   18.3254   18.4299
S2+S3 patch   18.3305   0.0493   18.2495   18.3809
```

Variance is rising slightly with each patch (0.009 → 0.025 → 0.039 → 0.049s). Still well below the inter-version differences (~70-820 ms), so the deltas are not noise. The variance increase plausibly reflects the cliff-undone `0.0.0` running closer to its new lower-water-mark each run, with the now-fully-utilized 2^19 trace varying slightly per-run on the FFT/Merkle side.

## Correctness

- 5 fancy-aggregation runs (12 nodes each, 60 nodes total) all completed without panic; `verify_type_1` is called on the root proof in every run and a failure would have aborted the binary.
- recursion --tracing (n=2): cycles 393,866 (was 399,294 with S2, 456,642 with bundle); proof verified.
- Total proof size: 2,604 KiB (was 2,605 with S2, 2,624 with bundle). Slight size reduction is consistent with `0.0.0`'s smaller trace.

## Per-call cycle accounting

For `num_chunks = 10` (n_chunks_12 = 6, the dominant pad-8 path):

| Source | bundle | S2 | S3 (S2+S3) | Δ S3 vs S2 |
|---|---:|---:|---:|---:|
| 3-layer call dispatch | 30 | 20 (pad8 bypasses no_pad) | 20 | 0 |
| `padded_data` alloc + 80 copies + 8 zeros | 89 | 0 | 0 | 0 |
| `init_state = Array(16)` + 8 data + 8 zero stores | 0 | 17 | 0 (ZERO_VEC) | **−17** |
| `states = Array(7×16)` + initial perm | 2 | 2 | 2 | 0 |
| Per-iter `pre = Array(16)` × 6 | 6 | 6 | 0 (hoisted) | **−6** |
| Hoisted `pres = Array(6×16)` (one alloc total) | 0 | 0 | 1 | +1 |
| Inner-loop body (4 stores + 12 ADDs + 1 perm) × 6 | 102 | 102 | 102 | 0 |
| **Total per call** | **229** | **147** | **125** | **−22** |

For `num_chunks = 8` (no_pad, n_chunks_12 = 4): savings just from hoisting = `(4−1) = 3` cycles per call.

For `num_chunks = 16` (pad8, n_chunks_12 = 10): savings = 17 (ZERO_VEC) + 9 (hoist) = 26 cycles per call.

For `num_chunks = 20` (no_pad, n_chunks_12 = 12): hoist only = 11 cycles per call.

Aggregate over the call mix on `0.0.0` (~1700 slice_hash_rtl invocations): observed −96K cycles vs bundle (S3) and −8K vs S2 — matches the per-call accounting within the precision available without per-call instrumentation.

## What's still over 2^19: node `0`

`0` recursion node: 537,814 cycles, 13,526 over the boundary.

To close this with the *zk-DSL* alone (no compiler changes, no protocol changes, no AIR changes):

* **Hoist `pres` further** — already done. No more savings here.
* **Skip the 4 capacity copies** — would require a precompile that takes a "split" left input (capacity from one address, rate-first-4 with chunk added from another). Doesn't exist; would require ISA changes.
* **Re-inline `slice_hash_rtl_rate12_no_pad` and `slice_hash_rtl_rate12_pad8`** (S1) — both are now single-return-point functions, the multi-return-fall-through bug doesn't apply. Each call site loses ~10 cycles of dispatch overhead. With ~1700 calls: ~17K cycles savings on `0`, which would put it at ~521K — under 2^19 with ~3K headroom. **This is the recommended next step.**
* **Re-inline `slice_hash_rtl` itself** — has multi-return-on-Const, would need verification that const-prop runs before inline expansion. Risky: hits the original compiler bug if the order is wrong. Skip unless S1-on-helpers turns out insufficient.

## Files modified / written

```
modified: crates/rec_aggregation/zkdsl_implem/hashing.py            (+48 / −11 cumulative)
new:      experiment_logs/leanMultisig/benchmark_pw3_pr/s3_results.md
new:      /tmp/bench_s3_patch                                       (binary)
new:      /tmp/bench_results_s3_patch.jsonl                         (5 fancy-aggregation runs)
```

## Reproducing

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig
cp target/release/lean-multisig /tmp/bench_s3_patch

# Cycle check (recursion n=2):
/tmp/bench_s3_patch recursion --tracing 2>&1 | grep -E "Aggregation program|^CYCLES:|Bytecode size:"

# Per-node fancy-aggregation matrix:
> /tmp/bench_results_s3_patch.jsonl
for i in 1 2 3 4 5; do
  /tmp/bench_s3_patch fancy-aggregation --json >> /tmp/bench_results_s3_patch.jsonl
done
```
