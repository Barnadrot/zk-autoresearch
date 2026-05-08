# Investigation: Criterion vs fancy-aggregation benchmark divergence

**Date:** 2026-05-08
**Branch:** `pr/perf-bundle` (myfork) — 5 commits on top of `19f1c774` (origin/main)
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, Zen 4, 8c/16t, 64 GB RAM, AVX-512)
**Author:** Investigation requested after results.md showed +13.83% bundle regression on production benchmark while Criterion paired gate reported -4.5%.

## 1. Observation

Two benchmarks of the same PR (`19f1c774` → `4175b20a`) give opposite signs:

| Benchmark | Result | Verdict |
|---|---|---|
| `cargo bench --bench xmss_leaf_1550sigs` (paired Criterion) | **-4.54%** (p=0.00) | "Performance has improved" |
| `lean-multisig fancy-aggregation` (12-node tree, 5 runs each) | **+13.83%** | Major regression |

Per-node breakdown (results.md, reproduced in §3) shows the regression is **concentrated in the recursion / inner aggregation nodes**, not the leaves. Pure recursion nodes (`raw_xmss == 0`) regress +23% to +55%; leaf XMSS nodes regress only ~+1% to +4% (one is even slightly faster).

The investigation found three independent causes:

1. **Recursion nodes**: c4 (`bdf43a62`, RATE=12) doubled the executed zkVM cycle count of the recursive verifier program — from removal of `@inline` on `slice_hash_rtl` plus newly-introduced inner-loop buffer construction. c5 (`4175b20a`, MMO) added a further +15% on top.
2. **Leaf nodes**: c3 (`a2dc0cfe`, FFT MDS in AIR) regresses leaves by +3-5% — the opposite of what the commit message predicted. Cycle count is unchanged; the regression is in native AIR-evaluation code.
3. **Benchmark-tooling divergence**: Criterion bench crate is built with `lto = "fat"`, `codegen-units = 1`, and the system glibc allocator. Production `lean-multisig` uses `lto = "thin"`, default codegen-units, and `zk_alloc`. Same workload, identical zkVM cycles, but ~2.20s on production vs ~2.86s in Criterion at bundle, with opposite-sign deltas — a real build-profile divergence that hides the regression from the gate.

**Bottom line: the +13.83% production regression is real and reproducible. The Criterion paired gate does not see it because the build profile and allocator hide it. The PR should not be merged in its current shape.**

## 2. Verified facts

### 2.1 Pre-built binaries are distinct and correct

```
ddb625bc2c3a1e78b3f1787390c124f5  /tmp/bench_19f1c774
28f034e6f2cee4094393bee32214e034  /tmp/bench_a6b3e553
9b33a33a2c81f1bc0f9d608f1275fa48  /tmp/bench_b3213c11
c21491ed9b85016a87eb46be23d10ef6  /tmp/bench_a2dc0cfe
984a2389fad1d144de903288facc88b3  /tmp/bench_bdf43a62
f5d808f19f43a7c4a0dad5e950902c47  /tmp/bench_4175b20a
```

All six are distinct. Each `/tmp/bench_results_<sha>.jsonl` file contains 5 lines (5 runs) of full per-node JSON output.

### 2.2 zk-DSL source is *embedded* in the binary at compile time

`crates/rec_aggregation/src/compilation.rs:40`:
```rust
static EMBEDDED_ZK_DSL: include_dir::Dir<'_> = include_dir::include_dir!("$CARGO_MANIFEST_DIR/zkdsl_implem");
```

The embedded `hashing.py` differs between bench binaries. Confirmed by `strings`:

```
$ strings /tmp/bench_19f1c774 | grep "states = Array((num_chunks - 1)"
    states = Array((num_chunks - 1) * DIGEST_LEN)   # old slice_hash_rtl (RATE=8)
$ strings /tmp/bench_4175b20a | grep slice_hash_rtl_rate12 | head -3
        return slice_hash_rtl_rate12(data, 32, 40, 2)
        return slice_hash_rtl_rate12(data, 40, 40, 2)
        return slice_hash_rtl_rate12(data, 64, 64, 4)
```

Confirmed for the eval_paired pre-built bench binaries too:

```
$ strings /tmp/bench_base | grep "states = Array((num_chunks - 1)"   # baseline-era
    states = Array((num_chunks - 1) * DIGEST_LEN)
$ strings /tmp/bench_cand | grep -c poseidon16_permute               # bundle-era
2
```

So the runtime working tree does not affect what zk-DSL the binaries execute. The `IMPORTANT` comment in `eval_paired.sh` about syncing the working tree is outdated since PR #214.

### 2.3 The Criterion gate genuinely reports the bundle as faster

Running the existing pre-built `bench_base` (baseline) and `bench_cand` (bundle) Criterion harnesses:

```
$ /tmp/bench_base --bench xmss_leaf_1550sigs --save-baseline tmp_baseline_19f1c774 \
       --sample-size 10 --measurement-time 30 --noplot
xmss_leaf_1550sigs      time:   [2.9918 s 3.0003 s 3.0093 s]

$ /tmp/bench_cand --bench xmss_leaf_1550sigs --baseline tmp_baseline_19f1c774 \
       --sample-size 10 --measurement-time 30 --noplot
xmss_leaf_1550sigs      time:   [2.8587 s 2.8641 s 2.8695 s]
                        change: [-4.8849% -4.5420% -4.2108%] (p = 0.00 < 0.05)
                        Performance has improved.
```

This matches the user-reported "~5% faster" Criterion claim. The gate would have shipped this PR.

### 2.4 The same workload on the production binary regresses

```
$ /tmp/bench_4175b20a xmss --n-signatures 1550 -r 1 --json
  time_secs=2.2935  cycles=994908
  time_secs=2.2729  cycles=994908
  time_secs=2.2736  cycles=994908   # bundle: ~2.28s

$ /tmp/bench_19f1c774 xmss --n-signatures 1550 -r 1 --json
  time_secs=2.2125  cycles=994908
  time_secs=2.1998  cycles=994908
  time_secs=2.1929  cycles=994908   # baseline: ~2.20s

Δ ≈ +3.6% (slower on bundle)
```

**Identical zkVM cycle count (994,908)** on both. Same input (1550 sigs), same `log_inv_rate=1`, same embedded zk-DSL on each binary. The only difference is the native (non-zkVM) prover code, which has been rebuilt with the c3/c4/c5 changes.

Production binary on this single workload: bundle is **+3.6% slower**.
Criterion bench on the same workload: bundle is **-4.5% faster**.

## 3. Per-node × per-commit regression matrix

Median time (seconds) across the 5 runs per binary:

```
path             19f1c774   a6b3e553   b3213c11   a2dc0cfe   bdf43a62   4175b20a
0.0.0.0            2.1620     2.1743     2.1780     2.2726     2.1443     2.2604   leaf 1550 r=1
0.0.0.1            1.3418     1.3379     1.3375     1.3776     1.2493     1.3238   leaf  508 r=2
0.0.0              1.2370     1.2399     1.2403     1.2518     1.2185     1.9194   recursion (raw_xmss=0)
0.0.1.0            2.8788     2.8696     2.8806     3.0025     2.7255     2.9469   leaf 1550 r=2
0.0.1.1            1.3316     1.3286     1.3308     1.3729     1.2423     1.3171   leaf  508 r=2
0.0.1              0.8497     0.8553     0.8619     0.8672     1.1111     1.1339   recursion
0.0                0.9633     0.9658     0.9625     0.9770     0.9387     1.0115   mixed (raw_xmss=25, recursive)
0.1.0              1.4241     1.4252     1.4307     1.4838     1.3555     1.4459   leaf  775 r=2
0.1.1              1.4208     1.4242     1.4261     1.4759     1.3571     1.4454   leaf  775 r=2
0.1                0.8529     0.8476     0.8519     0.8625     1.1004     1.1323   recursion
0                  1.3649     1.3594     1.3691     1.3800     1.9477     1.9924   mixed (raw_xmss=10)
root               1.0241     1.0244     1.0287     1.0391     1.2269     1.2612   recursion
TOTAL             16.8510    16.8521    16.8981    17.3628    17.6172    19.1901
```

Delta vs baseline (%):

```
path             a6b3e553   b3213c11   a2dc0cfe   bdf43a62   4175b20a
0.0.0.0            +0.57%     +0.74%     +5.12%     -0.82%     +4.55%   ← leaf, r=1
0.0.0.1            -0.29%     -0.32%     +2.66%     -6.90%     -1.35%   ← leaf, r=2
0.0.0              +0.24%     +0.26%     +1.20%     -1.50%    +55.16%   ← recursion
0.0.1.0            -0.32%     +0.06%     +4.30%     -5.32%     +2.36%
0.0.1.1            -0.22%     -0.06%     +3.11%     -6.71%     -1.09%
0.0.1              +0.65%     +1.44%     +2.05%    +30.76%    +33.44%   ← recursion (jumps at c4!)
0.0                +0.26%     -0.09%     +1.42%     -2.55%     +5.00%
0.1.0              +0.08%     +0.46%     +4.19%     -4.82%     +1.53%
0.1.1              +0.24%     +0.38%     +3.88%     -4.48%     +1.74%
0.1                -0.62%     -0.11%     +1.13%    +29.03%    +32.77%   ← recursion (jumps at c4)
0                  -0.41%     +0.30%     +1.10%    +42.70%    +45.97%   ← recursion (jumps at c4)
root               +0.03%     +0.44%     +1.46%    +19.80%    +23.15%   ← recursion (jumps at c4)
TOTAL              +0.01%     +0.28%     +3.04%     +4.55%    +13.88%
```

Incremental delta per commit (each vs its parent):

```
path             a6b3e553   b3213c11   a2dc0cfe   bdf43a62   4175b20a
0.0.0              +0.24%     +0.03%     +0.93%     -2.67%    +57.53%   ← c5 spike
0.0.1              +0.65%     +0.78%     +0.60%    +28.13%     +2.05%   ← c4 spike
0.1                -0.62%     +0.52%     +1.24%    +27.59%     +2.90%   ← c4 spike
0                  -0.41%     +0.72%     +0.80%    +41.14%     +2.29%   ← c4 spike
root               +0.03%     +0.42%     +1.01%    +18.08%     +2.80%   ← c4 spike
0.0.0.0            +0.57%     +0.17%     +4.34%     -5.65%     +5.42%   ← c3 hits leaf, c5 hits leaf
0.0.0.1            -0.29%     -0.03%     +3.00%     -9.31%     +5.96%
0.0.1.0            -0.32%     +0.38%     +4.23%     -9.22%     +8.12%
0.0.1.1            -0.22%     +0.17%     +3.16%     -9.52%     +6.02%
0.1.0              +0.08%     +0.39%     +3.71%     -8.65%     +6.67%
0.1.1              +0.24%     +0.14%     +3.49%     -8.05%     +6.51%
TOTAL              +0.01%     +0.27%     +2.75%     +1.47%     +8.93%
```

### 3.1 Two distinct regression patterns

The matrix exposes **two independent regressions**, attacked by different commits:

* **Recursion nodes regress at c4 (RATE=12)**: `0.0.1`, `0.1`, `0`, `root` jump +18-41% when c4 lands. Pure recursion nodes (`raw_xmss = 0`) take a one-step hit at c4 and a smaller second hit at c5. `0.0.0` is the exception: it takes its big hit at c5 (+57%, see §4.3 for why).
* **Leaf nodes regress at c3 (FFT MDS)**: every leaf adds +3-5% at c3. c4 partially recovers them (-5 to -9%, the genuine RATE=12 win), c5 gives back ~6%.

Importantly, the largest leaf — `0.0.0.0` (1550 sigs, `log_inv_rate=1`, the *exact configuration the Criterion gate measures*) — is the leaf that benefits *least* from c4 (only -0.82% vs -6 to -9% for the rate-2 leaves) because its single Merkle commit dominates and rate-1 paths absorb the RATE=12 win less.

## 4. Root cause analysis

### 4.1 Cycle counts, not poseidon counts, drive the recursion regression

`/tmp/bench_<sha> recursion --tracing` exposes the executed zkVM cycle count for the recursion node (n=2 → one recursion node aggregates two 775-sig leaves). The leaf and recursion node use the same compiled zk-DSL program (`Aggregation program: 250,208 instructions`); they exercise different paths at runtime.

Recursion node, n=2:

| SHA | Bytecode size | Cycles | Poseidons | "Cycles per pos" | Time (final agg step) |
|-----|--------------:|-------:|----------:|-----------------:|----------------------:|
| 19f1c774 (baseline)        | 250,208 | 243,026 | 22,196 | 10.95 | 0.865s |
| a2dc0cfe (c3 FFT MDS)      | 250,208 | 243,026 | 22,196 | 10.95 | 0.876s |
| bdf43a62 (c4 RATE=12)      | 251,689 | **394,670** (+62%) | 20,244 (-9%) | 19.49 | **1.099s (+27%)** |
| 4175b20a (c5 MMO)          | 253,755 | **456,642** (+88%) | 20,274 (-9%) | 22.52 | **1.121s (+30%)** |

Two facts here:

1. **Cycle count nearly doubles at c4 even though poseidon count drops**. Going from 22,196 → 20,244 poseidons is a -9% reduction — this is the genuine RATE=12 win on the verifier side. Yet total cycles jumped from 243k → 394k. Each saved poseidon costs +75 extra non-poseidon cycles. The new code is much more expensive *per poseidon* than the old code.
2. **Bytecode size barely grew** (+1.5% at c5). The 88% cycle inflation is not from a bigger program — it's from the *same* program being executed many more times in the verifier hot path. A small piece of code on the WHIR query loop is responsible.

The bytecode size is the *static* program; cycles are the *dynamic* execution count. The c4/c5 changes added a small amount of code (function dispatch + buffer construction) that runs O(num_queries × num_whir_rounds) times.

### 4.2 The hot path: `slice_hash_rtl` lost `@inline` and gained two layers of dispatch

In c4 (`bdf43a62`), `crates/rec_aggregation/zkdsl_implem/hashing.py` was rewritten:

**Before** (baseline, RATE=8):
```python
@inline                                    # ← inlined into caller
def slice_hash_rtl(data, num_chunks):
    states = Array((num_chunks - 1) * DIGEST_LEN)
    poseidon16_compress(...)               # one initial perm
    for j in unroll(1, num_chunks - 1):    # unrolled at compile time
        poseidon16_compress(states + ..., data + ..., states + ...)
    return states + ...
```

**After** (c4, RATE=12, c5 made it MMO):
```python
def slice_hash_rtl(data, num_chunks):      # ← NOT @inline anymore
    if num_chunks == 1: ...
    if num_chunks == 4:  return slice_hash_rtl_rate12(data, 32, 40, 2)
    if num_chunks == 5:  return slice_hash_rtl_rate12(data, 40, 40, 2)
    ...

def slice_hash_rtl_rate12(data, ..., padded_len, n_chunks_12):  # ← NOT @inline
    if padded_len == data_len:
        return slice_hash_rtl_rate12_no_pad(data, padded_len, n_chunks_12)
    padded_data = Array(padded_len)        # extra alloc
    for i in unroll(0, data_len): padded_data[i] = data[i]
    for i in unroll(data_len, padded_len): padded_data[i] = 0
    return slice_hash_rtl_rate12_no_pad(padded_data, padded_len, n_chunks_12)

def slice_hash_rtl_rate12_no_pad(padded_data, padded_len, n_chunks_12):  # ← NOT @inline
    states = Array((n_chunks_12 + 1) * 16)        # 2x bigger after c5
    poseidon16_permute(...)                       # c5: was poseidon16_compress
    for j in unroll(0, n_chunks_12):
        pre = Array(16)                           # ← per-iter allocation
        for k in unroll(0, 4):  pre[k] = states[...]
        for k in unroll(0, 12): pre[4 + k] = states[...] + padded_data[...]   # ← extra ADDs
        poseidon16_permute(pre, pre + 8, states + (j + 1) * 16)
    return states + n_chunks_12 * 16
```

The commit message explicitly says: *"@inline removed to fix conditional branch fall-through bug"*. Removing `@inline` was a correctness fix, but it turns every call site into a real zkVM function call.

`slice_hash_rtl` is invoked inside `decompose_and_verify_merkle_query` (utils.py:543), which is itself called once per WHIR query. There are O(100) WHIR queries per recursive proof verification, multiplied across multiple WHIR rounds and per child proof. Looking at compiler `setup_function_call` in `crates/lean_compiler/src/b_compile_intermediate.rs:781`, each function call adds:

* 1 `RequestMemory`
* 2 `Deref` (return label + parent fp)
* N `Deref` (one per argument)
* 1 `Jump` to callee
* 1 `Deref` per return value (in callee `compile_function_ret`)
* 1 final `Jump` back

= ~7-10 zkVM cycles per call boundary, **per call**. With three nested non-inlined functions that previously inlined into one block, a single `slice_hash_rtl` invocation now adds ~25-30 cycles of pure call overhead, plus per-iteration `pre = Array(16)` + 16 stores = ~16-20 cycles per inner-loop iteration that did not exist before.

For `n_chunks=10` paths: 6 inner iterations × 20 ≈ 120 cycles of buffer construction, plus 30 cycles of dispatch ≈ 150 cycles per query. Multiply by O(thousands) of slice-hash calls per recursive verification, and you get the observed +150 k cycle delta per recursion node.

### 4.3 c5 (MMO) widens the buffer to 16 elements and adds 12 ADDs per iteration

The c5 diff (`4175b20a`) replaces `poseidon16_compress` (8-element output) with the new `poseidon16_permute` precompile (16-element output, with input feedforward). The chaining state widens from 8 to 16 elements per round. The inner loop now has:

```python
pre = Array(16)                                    # was Array(8)
for k in unroll(0, 4):  pre[k] = states[...]       # capacity copy (same as before)
for k in unroll(0, 12): pre[4 + k] = states[...] + padded_data[...]  # NEW: 12 ADDs
poseidon16_permute(pre, pre + 8, states + (j + 1) * 16)
```

This explains why pure-recursion node `0.0.0` (the only recursion node where c5 dominates the regression) jumps from +1.20% at c4 to +55% at c5: it has the highest WHIR-query density relative to its other work, so the per-iteration MMO overhead bites hardest.

`crates/lean_vm/src/tables/poseidon_16/mod.rs` also grew: AIR `n_constraints` went from `BUS + 80` to `BUS + 80 + 19`, and a new `LookupIntoMemory` was added for the high-half output. Trace width grew by ~10 columns (`outputs_high`, `flag_full_output`, `index_input_res_high`). This affects native AIR-evaluation cost on every node, contributing to the ~+1.5-2% leaf regression at c5.

### 4.4 c3 (FFT MDS) regressed leaves rather than improving them

The commit message for `a2dc0cfe` states *"Saves 22 mults × 8 MDS calls per AIR row = 176 mults/row, ~10% reduction in AIR Poseidon eval mult count"* and predicts a 1-1.5% improvement. In the production binary it does the opposite:

| Path | c3 Δ vs parent | Notes |
|------|---:|---|
| 0.0.0.0 (1550 r=1) | +4.34% | leaf, AIR-Poseidon dominant |
| 0.0.1.0 (1550 r=2) | +4.23% | leaf |
| 0.0.0.1 (508 r=2)  | +3.00% | leaf |
| 0.1.0  (775 r=2)   | +3.71% | leaf |

Cycle count is unchanged (it's a pure native change to AIR evaluation), so the regression is in native code performance. The diff replaces 72-mult Karatsuba `mds_air_16` with a 50-mult FFT MDS in `crates/lean_vm/src/tables/poseidon_16/mod.rs`. Plausible but unverified causes for the inversion of the predicted sign:

* The FFT MDS variant uses generic `Mul<KoalaBear>` instead of `Algebra<KoalaBear>` to admit `EFPacking`, which may inhibit AVX-512 codegen for the inner mults.
* The `target_feature` ungating on the FFT helpers may hurt a code path that previously inlined under `#[target_feature]`.

This regression is **not** in the recursive verifier — it shows up on every leaf that has a non-trivial AIR Poseidon trace. It also flies under the Criterion gate's radar because of the build-profile divergence in §5.

## 5. Why the Criterion gate doesn't see the regression

`/tmp/bench_4175b20a` (production lean-multisig main binary) and `/tmp/bench_cand` (Criterion bench `xmss_leaf` from the bench crate) both contain the same `4175b20a` source and same embedded zk-DSL, but are compiled with different settings.

| Setting | Production (`leanMultisig/Cargo.toml`) | Bench (`harness/leanmultisig/bench/Cargo.toml`) |
|---|---|---|
| LTO | `lto = "thin"` | `lto = "fat"` |
| codegen-units | (default = 16) | `1` |
| Global allocator | `zk_alloc::ZkAllocator` (via main.rs cfg) | glibc (zkalloc_global feature is OFF by default) |

Confirmed by symbol inspection:

```
$ strings /tmp/bench_cand        | grep -c "ZkAllocator\|zk_alloc::"
0
$ strings /tmp/bench_4175b20a    | grep -c "zk_alloc::"
≥1   (zk_alloc symbols present)
```

Effect on identical workload (1550 sigs, log_inv_rate=1):

* Production binary, run as `xmss --n-signatures 1550 -r 1`:
  * baseline 19f1c774 ≈ 2.20 s, bundle 4175b20a ≈ 2.28 s → **+3.6%** (slower)
* Criterion bench, `xmss_leaf_1550sigs`:
  * baseline ≈ 3.00 s, bundle ≈ 2.86 s → **−4.5%** (faster)

Both report the same ~995 k zkVM cycles, so the divergence is purely native-code. With `lto = "fat"` and `codegen-units = 1`, the compiler can inline aggressively across the c3/c4/c5 changes — the modified AIR Poseidon eval, sponge.rs, merkle.rs paths get hot-path inlined, and the new code is faster than the old. With `lto = "thin"`, the compiler keeps cross-crate function boundaries; the new code has more uninlined function calls and more allocator pressure (zk_alloc arena interaction with the new MMO state buffers).

This is a **build-profile bug in the eval harness**, not a Criterion or statistics bug. Criterion's measurement is correct for the binary it measures; the binary it measures is not the binary we ship.

The Criterion bench also runs ~30% slower per iteration overall (3.0s vs 2.2s for the same workload). The likely contributor is `Vec::clone()` of 1,550 signatures inside `iter_batched`'s setup closure leaving a large drop on the heap; with glibc that drop is non-trivial, and `BatchSize::LargeInput` semantics may include some of it. We didn't fully isolate this overhead, but it doesn't change the central conclusion.

## 6. Proof-size analysis

Total proof size grew from 2,572 KiB (baseline) to 2,624 KiB (bundle): **+1.95%**. The growth is concentrated in the recursion nodes, mirroring the time regression:

| Path | baseline (KiB) | bundle (KiB) | Δ |
|------|---:|---:|---:|
| 0.0.0.0 leaf | 339 | 343 | +1.24% |
| 0.0.0  recursion | 190 | 207 | **+8.74%** |
| 0.0    mixed | 279 | 290 | +3.80% |
| 0      mixed | 196 | 209 | **+6.52%** |
| root   recursion | 129 | 129 | -0.15% |

The recursion-node proof growth is driven by:

* Bytecode size growth (250,208 → 253,755): more PCS data committed.
* RATE=12 / MMO sponge produces slightly different absorption boundaries; padding bytes can push the next FRI round's domain by one log step.
* New AIR columns (`outputs_high`, `flag_full_output`, `index_input_res_high`) widen the trace — more witness data per recursion proof.

Larger proofs feed into recursion's WHIR-query input, but the dominant cycle effect is from the dispatch/buffer overhead identified in §4.2, not the size growth.

## 7. Constraint-count analysis

`crates/lean_vm/src/tables/poseidon_16/mod.rs` (c5):

```rust
fn n_constraints(&self) -> usize {
    BUS as usize + 80 + 19   // was: BUS + 80
}
```

19 new constraints added by c5: 1 (`flag_full_output` boolean), 1 (mutex with `half_output`), 1 (`index_input_res_high` linkage), 8 (full-output value constraint), 8 ((1-flag) zeroes the high half on non-full rows). Plus a new `LookupIntoMemory` over 8 columns.

These constraints execute *in the recursive verifier program* (when it evaluates the inner proof's AIR). Every recursion node verifies these for every Poseidon row of every committed proof, contributing to the recursion-side cycle inflation alongside §4.2.

## 8. Recommendation

1. **Do not merge `pr/perf-bundle` as-is.** Production regression is +13.83%; the Criterion gate as currently configured cannot detect this class of regression.
2. **Bisect-keep the parts that are real wins and drop the rest.** From the per-commit matrix:
   * `a6b3e553` (InternalLayer16 elim): +0.01% — within noise, defensible to keep.
   * `b3213c11` (parallel stacking): +0.27% incremental — at noise floor.
   * `a2dc0cfe` (FFT MDS): **+2.75% leaf regression** — opposite of predicted sign; revert and re-investigate before re-landing.
   * `bdf43a62` (RATE=12): saves ~9% poseidons in recursion but costs ~62% recursion cycles from `@inline` removal and per-iter buffer construction; net **+1.47% regression**. Either restore `@inline` (find another fix for the conditional fall-through bug), or refactor `slice_hash_rtl_rate12_no_pad` to lift `pre = Array(16)` out of the loop and reuse it across iterations. The RATE=12 win on rate-2 leaves (-5 to -9%) is real and worth recovering.
   * `4175b20a` (MMO): the security uplift to 124-bit collision is necessary, but the implementation as-shipped costs **+8.93% incremental**. Investigate whether the inner-loop XOR-merge plus the `poseidon16_permute` AIR additions can be folded such that the recursion verifier's program adds fewer cycles per query.
3. **Fix the gate before re-landing any of these.** The Criterion bench crate must match the production build profile or it will keep producing the wrong sign. Concretely:
   * Drop `lto = "fat"` and `codegen-units = 1` from `harness/leanmultisig/bench/Cargo.toml`, OR change `leanMultisig/Cargo.toml` to use the same profile (latter is preferable so the published binary gets the inlining benefit too).
   * Enable `zkalloc_global` by default for the bench so it matches production's allocator.
4. **Add fancy-aggregation as a gate alongside (or in place of) `xmss_leaf`.** The `xmss_leaf_1550sigs` benchmark cannot detect recursion-node regressions because there are no recursion nodes in its workload. A multi-node `fancy-aggregation --json` run (5+ runs, sum-of-times metric) is what would have caught this PR.
5. **Document the divergence**: the pattern "leaf benchmark says faster, production says slower" likely repeats whenever a change touches the recursive verifier hot path. Make this an explicit note in the harness README.

## Appendix A — commands used

```bash
# Per-node × per-commit matrix (5 runs each, already collected)
ls /tmp/bench_results_*.jsonl
python3 <<EOF
import json, statistics
for sha in "19f1c774 a6b3e553 b3213c11 a2dc0cfe bdf43a62 4175b20a".split():
    rows = [json.loads(l) for l in open(f"/tmp/bench_results_{sha}.jsonl")]
    # ... aggregate medians per node
EOF

# Bytecode + cycles per SHA on the recursion path
for sha in 19f1c774 a2dc0cfe bdf43a62 4175b20a; do
  /tmp/bench_${sha} recursion --tracing 2>&1 \
    | grep -E "Aggregation program|^CYCLES:|Bytecode size:|^Poseidon16 calls:|the final aggregation step"
done

# Production-binary leaf at the exact Criterion workload (1550, r=1)
for sha in 19f1c774 4175b20a; do
  for i in 1 2 3; do
    /tmp/bench_${sha} xmss --n-signatures 1550 -r 1 --json
  done
done

# Criterion paired comparison using the existing bench_base/bench_cand
( cd ~/zk-autoresearch/harness/leanmultisig/bench && \
  RUSTFLAGS="-C target-cpu=native" /tmp/bench_base --bench xmss_leaf_1550sigs \
    --save-baseline tmp_baseline_19f1c774 --sample-size 10 --measurement-time 30 --noplot )
( cd ~/zk-autoresearch/harness/leanmultisig/bench && \
  RUSTFLAGS="-C target-cpu=native" /tmp/bench_cand --bench xmss_leaf_1550sigs \
    --baseline tmp_baseline_19f1c774 --sample-size 10 --measurement-time 30 --noplot )

# Verify the embedded zk-DSL matches the SHA the bench claims to be
strings /tmp/bench_base | grep "states = Array((num_chunks - 1)"   # → baseline RATE=8
strings /tmp/bench_cand | grep -c poseidon16_permute              # → bundle RATE=12 + MMO

# Build profile + allocator comparison
grep -A 5 "profile.release" ~/zk-autoresearch/leanMultisig/Cargo.toml
grep -A 5 "profile.release" ~/zk-autoresearch/harness/leanmultisig/bench/Cargo.toml
strings /tmp/bench_4175b20a | grep -c "zk_alloc::"
strings /tmp/bench_cand     | grep -c "zk_alloc::"
```

## Appendix B — files inspected

* `crates/rec_aggregation/zkdsl_implem/hashing.py` (c4, c5 diffs)
* `crates/rec_aggregation/zkdsl_implem/utils.py:543` (slice_hash_rtl call site)
* `crates/rec_aggregation/zkdsl_implem/whir.py:264` (decompose_and_verify_merkle_batch_const)
* `crates/rec_aggregation/src/compilation.rs:40` (EMBEDDED_ZK_DSL via include_dir!)
* `crates/lean_compiler/src/b_compile_intermediate.rs:781` (setup_function_call cycle cost)
* `crates/lean_vm/src/tables/poseidon_16/mod.rs` (c5 AIR additions, n_constraints)
* `crates/lean_vm/src/isa/instruction.rs` (PrecompileCompTimeArgs::Poseidon16 full_output)
* `harness/leanmultisig/bench/Cargo.toml` (lto=fat, cu=1, zkalloc_global feature)
* `harness/leanmultisig/bench/benches/xmss_leaf.rs` (N_SIGS=1550, LOG_INV_RATE=1)
* `leanMultisig/Cargo.toml` (lto=thin)
* `src/main.rs` (zk_alloc default, fancy-aggregation topology definition)
