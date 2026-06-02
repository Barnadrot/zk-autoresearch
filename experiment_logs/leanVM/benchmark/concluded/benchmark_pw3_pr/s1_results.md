# S1 implementation: `@inline` on the leaf MMO helpers

**Date:** 2026-05-08
**Patch:** `crates/rec_aggregation/zkdsl_implem/hashing.py`, +59 / −12 lines (cumulative S1+S2+S3)
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig`
**Binary:** `/tmp/bench_s123_patch` (md5 `01e4fb04ab817d154f4add4644342494`)
**Workload:** `fancy-aggregation --json`, **10 runs total** (two 5-run passes for noise reduction)

## What S1 does

Adds `@inline` to `slice_hash_rtl_rate12_no_pad` and `slice_hash_rtl_rate12_pad8`, eliminating one function-call layer per `slice_hash_rtl` invocation. Both functions are single-return-point bodies, so the original multi-return-fall-through bug doesn't apply.

## What S1 does NOT do

- It does *not* `@inline` `slice_hash_rtl_rate12` (the dispatcher). That function has the `if padded_len == data_len: return ...; return ...` shape — the multi-return-on-Const pattern that triggered the original bug. With `@inline` it failed at runtime with `Runner(not equal: 500618 != 500071)` in the WHIR query path. Reverted to non-inline + monomorphized via `: Const` args.
- It does *not* `@inline` `slice_hash_rtl` (the outer dispatcher) — same multi-return reason.

## Compiler restriction discovered

`crates/lean_compiler/src/a_simplify_lang/mod.rs:539-544`:

```rust
if func.has_const_arguments() {
    return Err(format!(
        "Inlined function should not have \"Const\" arguments (function \"{}\")",
        func.name
    ));
}
```

`@inline` and `: Const` argument annotations are **mutually exclusive**. The two helpers were originally written with `: Const` annotations (`data_len: Const`, `padded_len: Const`, `n_chunks_12: Const`); my first attempt to add `@inline` panicked at compile time. The fix: drop the `: Const` annotations and rely on call-site constant propagation through the inliner — the same pattern used by other `@inline` helpers in this file (e.g., `slice_hash`, `slice_hash_with_iv`, `whir_do_*_merkle_levels`). Each call site of an `@inline` function gets the body spliced in with the call-site constants substituted, so the inner `unroll(0, n_chunks_12)` loops get unrolled correctly.

The dispatcher `slice_hash_rtl_rate12` keeps its `: Const` annotations and is monomorphized non-inline — the compiler creates a separate specialized copy per `(data_len, padded_len, n_chunks_12)` tuple. The if-branch resolves at compile time within each specialized copy, so the multi-return shape becomes a single-return shape after specialization.

## Cycle results (10-run-stable medians)

```
path        baseline   c5 bundle    S2 patch    S2+S3       S2+S3+S1    Δ S1 vs S3
0.0.0        282,702    588,682 *   500,959     492,656     489,224     -3,432  (-0.70%)
0.0.1        251,801    472,979     415,631     410,203     407,665     -2,538  (-0.62%)
0.0          286,081    516,981     451,026     445,598     443,174     -2,424  (-0.54%)
0.1          243,008    456,624     399,276     393,848     391,424     -2,424  (-0.62%)
0            329,766    634,861 *   546,071 *   537,814 *   536,073 *   -1,741  (-0.32%)
root         109,703    226,757     198,083     195,369     194,043     -1,326  (-0.68%)
```

`*` = over 2^19 = 524,288.

`0` is still **11,785 cycles over** the boundary. S1 doesn't close the gap on its own.

## Wall-clock results — ambiguous

Combined 10 runs (two 5-run passes back-to-back):

```
                mean (s)   stdev (s)   min       max       n
S2+S3          18.3950    0.0775     18.2495   18.4897    10
S2+S3+S1       18.4419    0.0462     18.3896   18.4972    10
                Δ = +0.0469s = +0.25%   (~½σ — within noise)
```

Per-node medians over the same 10 runs:

```
path           S2+S3      S2+S3+S1   Δ%
0.0.0          1.2481     1.2529    +0.38%      ← cliff-fixed in both
0.0.1          1.1377     1.1326    -0.44%
0.0            0.9592     1.0040    +4.67%      ← only node with a real shift
0.1            1.1179     1.1174    -0.04%
0              1.9870     1.9891    +0.11%      ← cliff still active in both
root           1.2431     1.2407    -0.19%
0.0.0.0        2.2875     2.2877    +0.01%      (leaf, unchanged cycles)
others         flat or ±0.4%
TOTAL         18.3859    18.4281    +0.23%
```

**Cycles drop on every recursion node, but wall-clock for `0.0` specifically regresses ~5%.** `0.0` has `raw_xmss=25` (a mixed leaf+recursion node), and its cycle count drops 451,026 → 443,174 even as wall-clock rises. The cycle reduction is real but the native prover apparently does *more* native work for this specific node despite fewer cycles — most plausibly because inlining changed the bytecode layout in a way that grows other AIR tables (memory access, executive bus) for that proof's specific shape. Other recursion nodes are within noise.

## Bytecode size

```
recursion (n=2) bytecode size:
  c5 bundle:    253,755
  S2 patch:     253,453    (S2 saved 302 instr)
  S2+S3:        253,315    (S3 saved 138 more)
  S2+S3+S1:     253,042    (S1 saved 273 more — function bodies eliminated > inline expansion growth)
```

S1 actually *shrinks* the static bytecode despite inlining, because each helper had been monomorphized into 6 separate copies (one per `(data_len, padded_len, n_chunks_12)` tuple seen at call sites); inlining replaces those 6 separate function bodies with copies spliced into their callers, but the call setup/teardown overhead for each invocation is gone. Net: −273 instructions.

## Correctness

- 10 fancy-aggregation runs (12 nodes each, 120 nodes total): all root proofs verified (`verify_type_1` would have panicked).
- recursion --tracing (n=2): cycles 391,442 (vs 393,866 with S2+S3); proof verified.
- Total proof size: 2,612 KiB (vs 2,604 with S2+S3, 2,624 with bundle). The +8 KiB is from the changed bytecode-table commitment shape.

## Cumulative comparison

```
                   total time     Δ vs main      Status of node `0`
main (19f1c774)    16.8510 s       —              under 2^19
c5 bundle          19.1901 s     +13.88%         OVER (634,861)
S2 patch           18.3693 s      +9.01%         OVER (546,071)
S2+S3 patch        18.3226 s      +8.73%         OVER (537,814)
S2+S3+S1 patch     18.4419 s      +9.44%         OVER (536,073)   ← node `0` still over by 11,785
```

The total wall-clock for S2+S3+S1 is essentially tied with S2+S3 (within 1σ). Cycle savings on every recursion node are real. But the cliff on `0` persists.

## Per-call cycle accounting

For `num_chunks = 10`:

| Source | bundle | S2 | S3 | S1 | Δ S1 vs S3 |
|---|---:|---:|---:|---:|---:|
| 3-layer call dispatch | 30 | 20 | 20 | **10** | **−10** |
| `padded_data` materialization | 89 | 0 | 0 | 0 | 0 |
| `init_state` setup | 0 | 17 | 0 | 0 | 0 |
| `pre = Array(16)` per iter × 6 | 6 | 6 | 0 | 0 | 0 |
| Hoisted `pres` alloc | 0 | 0 | 1 | 1 | 0 |
| Inner-loop body | 102 | 102 | 102 | 102 | 0 |
| **Total per call** | **229** | **147** | **125** | **115** | **−10** |

S1 saves the function-call dispatch overhead for the inlined leaf helper (~10 cycles per call). With ~1700 calls on `0`, ~17K cycles savings predicted; observed −1,741 in `0`'s cycles. The smaller-than-predicted savings is consistent with not all calls being on the pad8/no_pad path the same way (and `0` has different call distribution vs `0.0.0`).

## Why `0` is so stubborn

`0` recursion node aggregates two type-1 proofs (the largest pair in the topology). Its specific WHIR query distribution lands on a call mix where S1's per-call savings are small (~1 cyc/call effective in `0` vs ~2 cyc/call in `0.0.0`). The 11,785-cycle remaining gap is too small to close with another zk-DSL trick of the kind we've been doing — every per-call optimization that's inside the inner loop is already applied.

To push `0` below 2^19 without protocol or AIR changes, the realistic options are:

1. **Compiler change: allow `@inline` + `: Const`.** This would let `slice_hash_rtl_rate12` itself be inlined (currently blocked by the rule + the multi-return-bug). Estimated additional ~10 cyc/call ≈ 17K cycles on `0` — would close the gap.
2. **Compiler fix for the multi-return-fall-through bug** in the inliner. Same effect: re-enable `@inline` on `slice_hash_rtl` and `slice_hash_rtl_rate12`. Probably the cleanest path.
3. **A new precompile** that takes `(capacity_4_ptr, rate_12_ptr_with_chunk_already_added, output_ptr)` — would eliminate the 4 capacity copies per inner iter (~24 cyc on `0`).
4. **Accept the cliff for `0`.** It crosses 2^19 by 2.2% — the trace doubles to 2^20. Currently `0` takes 1.99s wall-clock; halving native work via cliff-undo would put it at ~1.0s. But this requires the cycle gap to close, which we've not done.

Option (2) is the highest-leverage and lowest-risk: it fixes a known compiler bug and unlocks a class of optimizations beyond just MMO sponge.

## Recommendation

S1 is implemented and the cycle accounting is correct, but on this hardware/build profile the wall-clock effect is neutral-to-slightly-negative. Options:

- **Keep S1**: cycles strictly better, wall-clock essentially tied, structurally cleaner.
- **Revert S1**: simpler code, no risk of `0.0` regression in production runs.

Without a clear wall-clock win, I lean **revert** unless the cycle metric is independently valuable (e.g., for a future iai-instruction-count gate). Keep S2 + S3 — those are net positive on every metric.

## Files

```
modified: crates/rec_aggregation/zkdsl_implem/hashing.py            (+59 / −12 cumulative)
new:      experiment_logs/leanMultisig/benchmark_pw3_pr/s1_results.md
new:      /tmp/bench_s123_patch                                     (binary)
new:      /tmp/bench_results_s123_patch.jsonl                       (5 runs)
new:      /tmp/bench_results_s123_patch_v2.jsonl                    (5 more runs)
new:      /tmp/bench_results_s3_patch_v2.jsonl                      (5 more S3 runs for noise floor)
```

## Reproducing

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig
cp target/release/lean-multisig /tmp/bench_s123_patch

# Cycle check (recursion n=2):
/tmp/bench_s123_patch recursion --tracing 2>&1 | grep -E "Aggregation program|^CYCLES:|Bytecode size:"

# Per-node fancy-aggregation matrix (do 10 runs to beat noise):
> /tmp/bench_results_s123_patch.jsonl
for i in 1 2 3 4 5 6 7 8 9 10; do
  /tmp/bench_s123_patch fancy-aggregation --json >> /tmp/bench_results_s123_patch.jsonl
done
```
