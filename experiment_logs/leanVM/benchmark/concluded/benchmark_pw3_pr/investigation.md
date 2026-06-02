# Benchmark Divergence Investigation: Criterion vs fancy-aggregation

**Date:** 2026-05-08
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, Zen 4, 8c/16t, 64GB RAM, AVX-512)
**PR:** `pr/perf-bundle` on `myfork` (5 commits on top of `19f1c774`)

## 1. Observation

Two benchmarks give opposite results for the same PR:

| Benchmark | Result |
|-----------|--------|
| Criterion `xmss_leaf_1550sigs` (leaf-only) | ~5% FASTER |
| `fancy-aggregation` (production, 12 nodes: 6 leaf + 6 recursion) | **13.83% SLOWER** |

## 2. Root Cause

**Power-of-2 trace padding threshold crossings in recursion nodes.**

The PR's commits (particularly commit 4: RATE=12 and commit 5: MMO feedforward sponge) increase the zkDSL bytecode execution cycle count and memory footprint for recursion nodes. This pushes the padded trace table sizes past power-of-2 boundaries, causing discrete 2x jumps in table size. The effect is catastrophic for recursion nodes but invisible for leaf nodes.

### Why the benchmarks disagree

- **Criterion benchmark** measures `xmss_leaf_1550sigs` -- a **leaf node** (no child proof verification). Leaf nodes have IDENTICAL cycle counts (994,842), memory (3,900,425), and Poseidon call counts (259,055) across all 6 SHAs. The leaf bytecode path (WOTS chain + Merkle auth) was not modified by the PR. The FFT MDS improvement (fewer multiplications in the AIR eval) provides a genuine wall-clock speedup for leaves.

- **fancy-aggregation** runs a full 12-node tree with 5 recursion nodes and 7 leaf nodes. Recursion nodes verify child proofs and then prove the aggregation, executing a DIFFERENT code path in the zkDSL (which includes the RATE=12 and MMO sponge changes). The increased work pushes them past trace boundaries.

### The threshold mechanism

The proving system pads each trace table to the next power of 2. When the number of rows in a table crosses a power-of-2 boundary, the padded size doubles, and proving work roughly doubles for that table.

| Node | Type | Baseline cycles | Bundle cycles | CPU table baseline | CPU table bundle | Jumped? |
|------|------|----------------:|------:|-----------:|-----------:|---------|
| 0.0.0 | RECUR | 282,702 | 588,682 | 524,288 (2^19) | 1,048,576 (2^20) | **CPU 2x + MEM 2x** |
| 0.0.1 | RECUR | 251,801 | 472,979 | 262,144 (2^18) | 524,288 (2^19) | **CPU 2x** |
| 0.1 | RECUR | 243,008 | 456,624 | 262,144 (2^18) | 524,288 (2^19) | **CPU 2x** |
| 0 | RECUR | 329,766 | 634,861 | 524,288 (2^19) | 1,048,576 (2^20) | **CPU 2x + MEM 2x** |
| root | RECUR | 109,703 | 226,757 | 131,072 (2^17) | 262,144 (2^18) | **CPU 2x** |
| 0.0.0.0 | LEAF | 994,842 | 994,842 | 1,048,576 (2^20) | 1,048,576 (2^20) | no |
| 0.1.0 | LEAF | 498,011 | 498,011 | 524,288 (2^19) | 524,288 (2^19) | no |

Every recursion node crosses at least one boundary. No leaf node crosses any.

The regression severity correlates with the number of boundaries crossed:
- Double boundary (CPU + MEM): +46% to +55% wall-clock
- Single boundary (CPU only): +23% to +34% wall-clock

## 3. Per-Commit Attribution

### Which commit causes the recursion explosion?

Tracking recursion node 0.0.0 (2 children) across commits:

| SHA | Commit | Cycles | CPU pad | Memory | MEM pad | Time (s) |
|-----|--------|-------:|--------:|-------:|--------:|---------:|
| 19f1c774 | baseline | 282,702 | 524,288 | 798,634 | 1,048,576 | 1.238 |
| a2dc0cfe | FFT MDS | 282,702 | 524,288 | 798,634 | 1,048,576 | 1.252 |
| bdf43a62 | RATE=12 | 503,584 | 524,288 | 1,084,758 | **2,097,152** | 1.222 |
| 4175b20a | MMO | 588,682 | **1,048,576** | 1,225,576 | 2,097,152 | **1.918** |

**Commit 4 (RATE=12, `bdf43a62`)**: Cycles jump +78% (282K -> 504K) but STILL fit in 2^19 CPU table. Memory crosses 2^20 boundary (MEM table doubles). Wall-clock is flat because the CPU table dominates and didn't grow.

**Commit 5 (MMO, `4175b20a`)**: Cycles +17% more (504K -> 589K) which CROSSES 2^19 (524,288). CPU table doubles to 2^20. Wall-clock explodes +57% for this node.

### Why RATE=12 increases cycles so much

The RATE=12 rewrite of `slice_hash_rtl` in `hashing.py` changed the sponge algorithm. With RATE=8, each round consumed/produced 8 elements (DIGEST_LEN). With RATE=12, the sponge alignment requires more setup code:
- Padding logic to ensure `(padded_len - 16) % 12 == 0`
- Different loop structure with explicit capacity/rate separation
- Array allocation for intermediate states

This added ~220K cycles per recursion node (78% increase) even though Poseidon call count dropped by ~9% (fewer rounds due to higher rate).

### Why MMO doubles the cost per Poseidon call

The MMO feedforward sponge chains the FULL 16-element state between rounds (vs 8 elements for standard sponge). This requires:
1. **New `poseidon16_permute` precompile**: writes 16 elements to memory instead of 8
2. **10 more AIR columns per Poseidon row**: `flag_full_output`, `index_input_res_high`, `outputs_high[8]`
3. **19 more AIR constraints per Poseidon row**: boolean checks, mutual exclusion, output equality
4. **Additional memory lookup** for `outputs_high`
5. **2x state storage in zkDSL**: `Array((n_chunks_12 + 1) * 16)` vs `Array((n_chunks_12 + 1) * 8)`

The cost per Poseidon permutation (in wall-clock) increased from 42.5us to 72.6us (+71%).

## 4. Per-Node Regression Table

| Node | Type | Baseline (s) | Bundle (s) | Delta % | Boundary crossings |
|------|------|-----------:|-----------:|--------:|---|
| 0.0.0.0 | LEAF | 2.166 | 2.261 | +4.4% | none |
| 0.0.0.1 | LEAF | 1.342 | 1.324 | -1.4% | none |
| 0.0.0 | RECUR | 1.238 | 1.918 | **+54.9%** | CPU 2x + MEM 2x |
| 0.0.1.0 | LEAF | 2.880 | 2.942 | +2.2% | none |
| 0.0.1.1 | LEAF | 1.334 | 1.317 | -1.3% | none |
| 0.0.1 | RECUR | 0.850 | 1.137 | **+33.8%** | CPU 2x |
| 0.0 | RECUR | 0.963 | 1.013 | +5.2% | MEM 2x |
| 0.1.0 | LEAF | 1.423 | 1.446 | +1.6% | none |
| 0.1.1 | LEAF | 1.425 | 1.446 | +1.5% | none |
| 0.1 | RECUR | 0.853 | 1.131 | **+32.5%** | CPU 2x |
| 0 | RECUR | 1.363 | 1.996 | **+46.5%** | CPU 2x + MEM 2x |
| root | RECUR | 1.024 | 1.262 | **+23.3%** | CPU 2x |
| **Total** | | **16.862** | **19.193** | **+13.83%** | |

## 5. Evidence Summary

| Metric | Leaf nodes | Recursion nodes |
|--------|-----------|-----------------|
| Cycles | Unchanged (0.00%) | +80% to +108% |
| Memory | Unchanged (0.00%) | +44% to +57% |
| Poseidons | Unchanged (0.00%) | -2% to -9% (fewer, due to RATE=12) |
| Proof size | +1% to +1.5% | -2% to +9% (varies) |
| Wall-clock | -1% to +4% (noise) | +5% to +55% |
| CPU table pad | No boundary crossed | Every node crosses at least 1 |
| MEM table pad | No boundary crossed | Some nodes cross |

## 6. Why the experiment missed this

The poseidon_whir_3 experiment (iters 1-33) used the Criterion `xmss_leaf_1550sigs` benchmark as its gate. This is a leaf-only benchmark. The experiment correctly measured that RATE=12 and MMO improve leaf throughput by ~5%.

The fancy-aggregation benchmark was not part of the eval gate. The experiment's `tier2_criterion_pct` column tracked only leaf performance. The recursion regression was invisible to the gate because:

1. Leaf nodes don't execute the modified sponge code paths (no child proof verification)
2. Leaf cycle counts and trace sizes are identical across all commits
3. The Criterion benchmark's ~5% improvement is real -- for leaves

The divergence is structural: the PR makes leaves faster but makes recursion nodes much more expensive due to trace boundary crossings.

## 7. Recommendation

### Do not merge the PR as-is

The 13.83% production regression outweighs the ~5% leaf improvement. The production workload (fancy-aggregation) is dominated by recursion node time, and the MMO changes push recursion nodes past critical trace boundaries.

### Potential remediation paths

1. **Split the PR**: Ship commits 1 (InternalLayer16 elim) and 2 (parallel stacking) which are neutral. Ship commit 3 (FFT MDS) which improves leaves by ~2% with minimal recursion impact. Hold commits 4 and 5.

2. **Reduce recursion cycle count**: The RATE=12 zkDSL rewrite added significant overhead. Optimize `slice_hash_rtl_rate12_no_pad` to minimize Array allocations and intermediate state. The MMO path allocates `(n_chunks_12 + 1) * 16` elements of state per hash -- explore reusing state buffers.

3. **Eliminate the power-of-2 cliff**: The root problem is that recursion cycles went from ~280K (just under 2^19) to ~589K (just over 2^19). If cycles can be brought back under 524,288, the CPU table stays at 2^19 and the regression disappears. This requires shaving ~65K cycles from the recursion path.

4. **Reconsider MMO**: The MMO construction was added to achieve 124-bit collision security with capacity=4. Alternative: use a larger Poseidon permutation (Poseidon-24 with capacity=8) that achieves 124-bit collision without MMO overhead. Or prove that the protocol requires only preimage resistance (124-bit with c=4) rather than collision resistance.

5. **Test both benchmarks in the gate**: Add `fancy-aggregation` (or a simplified recursion-only benchmark) to the eval gate so recursion regressions are caught during experiments.

## 8. Commands Run

All analysis was performed on pre-existing benchmark data in:
- `~/zk-autoresearch/experiment_logs/leanMultisig/benchmark_pw3_pr/raw_results.json`
- `~/zk-autoresearch/experiment_logs/leanMultisig/benchmark_pw3_pr/results.md`

Git operations:
```bash
cd ~/zk-autoresearch/leanMultisig
git remote add myfork https://github.com/Barnadrot/leanMultisig
git fetch myfork --depth=50
git log --oneline myfork/pr/perf-bundle
git diff 19f1c774..a6b3e553 --stat  # commit 1
git diff a6b3e553..b3213c11 --stat  # commit 2
git diff b3213c11..a2dc0cfe         # commit 3 (FFT MDS)
git diff a2dc0cfe..bdf43a62         # commit 4 (RATE=12)
git diff bdf43a62..4175b20a         # commit 5 (MMO)
```

Source code analysis:
- `src/main.rs` -- fancy-aggregation topology definition
- `crates/rec_aggregation/src/benchmark.rs` -- benchmark runner, per-node timing
- `crates/rec_aggregation/src/lib.rs` -- `xmss_aggregate()` proving + child verification
- `harness/leanmultisig/bench/benches/xmss_leaf.rs` -- Criterion benchmark (leaf-only)
- `harness/leanmultisig/scripts/eval_paired.sh` -- eval gate (uses Criterion leaf bench)
- `crates/backend/symetric/src/sponge.rs` -- sponge + MMO implementations
- `crates/whir/src/merkle.rs` -- Merkle tree building with sponge
- `crates/lean_vm/src/tables/poseidon_16/mod.rs` -- Poseidon AIR table (columns + constraints)
- `crates/rec_aggregation/zkdsl_implem/hashing.py` -- zkDSL sponge for recursive verification

Note: Rust toolchain was not available on this machine, so no builds or live benchmarks were run. All analysis is based on the raw_results.json from the previous benchmark session plus source code review.
