# Experiment 4-monty: Analysis Report

## Executive Summary

4 separate runs, 6 total iterations, targeting Montgomery field arithmetic in `monty-31/src/x86_64_avx512/`. One improvement kept: **-0.41% (11ms)** via mask-based add/sub port pressure reduction. Total cost: **$36.81**.

---

## 1. Run Metadata

| Metric | Value |
|--------|-------|
| Total runs | 4 |
| Total iterations | 6 (counting restarts) |
| Improvements kept | 1 |
| Total cost | $36.81 |
| Total tokens | ~11.1M input / ~281K output |
| Total wall time | ~3900s (~65 min) |
| Baseline | 2659.80ms |
| Best score | 2648.90ms |
| Cumulative gain | **-0.41% (-11ms)** |

### Cost by Run

| Run | Duration | Tokens (in/out) | Cost | Result |
|-----|----------|-----------------|------|--------|
| Run 1 | 787.3s | 981,661 / 50,590 | $3.70 | Reverted (0.00%) |
| Run 2 | 992.3s | 1,860,360 / 74,940 | $6.71 | Reverted (+1.68% regression) |
| Run 3 | 669.3s | 2,387,466 / 43,961 | $7.82 | Reverted (-0.04%, below threshold) |
| Run 4 | 1735.8s | 5,698,303 / 112,102 | $18.78 | **KEPT (-0.41%)** |

---

## 2. Per-Iteration Breakdown

### Run 1 / Iteration 1 — Inlining butterfly functions
**Cost**: $3.70 | **Time**: 787.3s | **Tokens**: 981K in / 50K out

**Idea**: Add `#[inline(always)]` to six hot-path butterfly functions (`dit_layer_rev*`) to force inlining into parallel closures.

**Tool usage**: 14 read_file, 3 get_assembly, 1 write_file (dft/src/, 48259 chars), 2 list_dir

**Result**: 2666.70ms → 2666.70ms | Δ = 0.00% | p = 1.00 | **REVERTED**

**Analysis**: LLVM already inlines these functions or call overhead is negligible. The agent correctly used get_assembly to investigate but the hypothesis was wrong from the start. Run stopped early (STOP file after 1 of 10 planned iters).

---

### Run 2 / Iteration 1 — Mask-based add/sub (incomplete)
**Cost**: $6.71 | **Time**: 992.3s | **Tokens**: 1,860K in / 75K out

**Idea**: Replace `vpminud` in `Add`/`Sub` with `vpcmpgeud`/`vpcmpltud` mask approach to shift port 0 pressure to port 5.

**Tool usage**: 28 read_file, 1 get_assembly, 1 write_file (utils.rs only, 12520 chars), 4 list_dir

**Result**: 2634.00ms → 2678.30ms | Δ = +1.68% (regression) | **REVERTED**

**Critical failure**: Token cutoff prevented completing the change. The agent wrote new `add_avx512`/`sub_avx512` functions to `utils.rs` but never updated the `Add`/`Sub` impls in `packing.rs` to call them — dead code. The -1.68% is pure session variance on unchanged hot path.

**Note**: This result is logged in CLAUDE.md as a "Known False Dead End." The idea itself was not disproven.

---

### Run 3 / Iteration 2 — From<MontyField31> broadcast via _mm512_set1_epi32
**Cost**: $7.82 | **Time**: 669.3s | **Tokens**: 2,387K in / 44K out

**Idea**: Use `_mm512_set1_epi32(value.value as i32)` in `From<MontyField31>` impl so LLVM can prove the twiddle vector is uniform and eliminate `vmovshdup rhs_odd` in `mul`.

**Tool usage**: 36 read_file, 3 get_assembly, 1 read_experiment_diff, 1 write_file (packing.rs, 70048 chars)

**Result**: 2659.80ms → 2658.80ms | Δ = -0.04% | p = 0.88 | **REVERTED** (below 0.2% threshold)

**Analysis**: Twiddles are already packed vectors in the hot path — `From<MontyField31>` is not on the critical loop. The hypothesis was wrong. First successful full-file write (70K chars), clean implementation.

---

### Run 4 / Iteration 3 — vpcmpge_epu32_mask add/sub (complete)
**Cost**: $18.78 | **Time**: 1735.8s | **Tokens**: 5,698K in / 112K out

**Idea**: Replace `vpminud` in `Add` and `Sub` impls with `vpcmpge_epu32_mask + vpsubd{k}/vpaddd{k}` to shift port 0 pressure to port 5 — same pattern already used in `mul`'s final reduction step.

**Change**:
- Before `Add`: `vpaddd + vpsubd + vpminud` (ports 0+5 for vpminud)
- After `Add`: `vpaddd + vpcmpge_epu32_mask + vpsubd{k}` (comparison on port 5 only)
- Same pattern for `Sub`

**Tool usage**: 51 read_file, 2 write_file (packing.rs, 3 total writes counting import fix), 3 get_assembly, 1 read_experiment_diff, 3 list_dir

**Result**: 2659.80ms → 2648.90ms | Δ = **-0.41%** | p = 0.23 | **KEPT**

**Note on p=0.23**: This would be reverted by the new p-value gate (p < 0.10 required). The result is statistically weak and may be session variance. The change is committed but should be validated cross-session before upstream PR.

---

## 3. Tool Usage Patterns

| Run | read_file | write_file | get_assembly | read_experiment_diff |
|-----|-----------|------------|--------------|---------------------|
| Run 1 | 14 | 1 | 3 | 0 |
| Run 2 | 28 | 1 | 1 | 0 |
| Run 3 | 36 | 1 | 3 | 1 |
| Run 4 | 51 | **3** | 3 | 1 |
| **Total** | **129** | **6** | **10** | **2** |

**Key observations**:
- Read-to-write ratio: 129:6 = **21:1**. Agent spends vast majority of budget reading context.
- Run 4's 3 write_file calls = 3 full-file reconstructions of 1708 lines for one 20-line change. This is the `edit_file` problem in stark form.
- get_assembly used consistently (1-3x per iter) — good discipline.
- No `edit_file` calls — the tool was added to loop.py but not deployed to server before this run.

---

## 4. Behavioral Analysis

### The write_file Problem (Run 4)

Run 4 made **3 separate full-file writes** of the 1708-line packing.rs:

1. **Write #1** (~70048 chars): Agent panicked — "much shorter than 1672 lines" — but this was a line-count vs char-count confusion. File was likely correct.
2. **Write #2** (71396 chars): Full reconstruction with the actual optimization. Correct.
3. **Write #3** (71377 chars): Removed one unused import (`mm512_mod_sub`, -19 chars). Wrote the entire file again for a one-import change.

Total token cost of write overhead: estimated **~2M tokens** just on file reconstruction. With `edit_file`, this entire section would be 3 targeted calls of ~100 chars each.

### Indecision Pattern (Run 4)

The agent spent ~200 lines of reasoning exploring a **combined butterfly add/sub** approach before pivoting:
- Considered computing both `a+b` and `a-b` simultaneously sharing intermediates
- Worked through the math: `diff_corr = sum + (P - 2b)` — requires `P - 2b` precomputation, expensive
- Correctly concluded this requires 7 instructions not 6 — **abandoned correctly**

The pivot to mask-based approach was sound. Total time in reasoning before first write: ~45 min.

### Baseline Variance

Baselines across runs: 2666.70ms → 2634.00ms → 2659.80ms → 2659.80ms. The 32ms swing between Run 1 and Run 2 is session/hardware variance (~1.2%), not real drift. Run 3 and Run 4 show the same baseline (2659.80ms) = stable measurement session.

---

## 5. Agent Reasoning Quality

### Correct

- **Port pressure identification**: Correctly identified `vpminud` (ports 0+5) competing with `vpmuludq` (port 0) for port 0 bandwidth in the butterfly hot loop
- **Pattern recognition**: Recognized that `mul`'s final reduction already uses the mask pattern; correctly extended it to `Add`/`Sub`
- **Correctness verification**: Traced unsigned wraparound semantics for both add and sub; proved semantic equivalence of `vpminud` and `vpcmpge + conditional op`
- **Rejecting the combined butterfly**: Correctly abandoned the 7-instruction approach via explicit instruction counting

### Incorrect / Missed

- **Run 1 inlining**: LLVM already handles this; not a real opportunity
- **Run 2 scope completion**: Failed to finish packing.rs changes due to token cutoff at 20k MAX_TOKENS (now fixed to 40k)
- **Run 3 broadcast**: Twiddles don't go through `From<MontyField31>` in the hot path
- **Memory bandwidth blindspot**: Agent briefly noted "this might be memory-bandwidth-bound at 2^20 × 256 = 256MB >> L3 cache" but didn't pursue the implication fully — that arithmetic optimizations may have limited headroom if bandwidth-bound

### The Memory Bandwidth Question (Unresolved)

In Run 4's reasoning the agent correctly noted:
- 2^20 × 256 cols = 256MB of data
- 256MB >> typical server L3 cache (~32MB)
- At each DFT layer: 1 load × 2 rows + 1 mul + 1 add + 1 sub + 1 store × 2 rows

If the benchmark is memory-bandwidth-bound, **all arithmetic optimizations in monty-31 have limited headroom**. The existing improvements (fused last-2 layers, parallel split) already addressed the highest-leverage cache/bandwidth angles. This remains the most important open question for experiment 5 planning.

---

## 6. Results Summary

| Iteration | Idea | Status | Delta |
|-----------|------|--------|-------|
| Run 1 / Iter 1 | `#[inline(always)]` butterfly functions | Reverted | 0.00% |
| Run 2 / Iter 1 | Mask add/sub — incomplete (dead code) | Reverted | +1.68% regression (false) |
| Run 3 / Iter 2 | `_mm512_set1_epi32` twiddle broadcast | Reverted | -0.04% (noise) |
| Run 4 / Iter 3 | `vpcmpge_epu32_mask` add/sub complete | **KEPT** | **-0.41%** |

**Baseline**: 2659.80ms → **Best**: 2648.90ms → **Gain**: -0.41% (p=0.23, statistically weak)

---

## 7. Infrastructure Issues Identified & Fixed

| Issue | Impact | Fix Applied |
|-------|--------|-------------|
| MAX_TOKENS=20k → token cutoff in Run 2 | Dead code write, false regression | Bumped to 40k ✓ |
| write_file requires full file reconstruction | Run 4: 3× 1708-line writes for 20-line change | `edit_file` tool added ✓ |
| No p-value gate on keep decision | p=0.23 result kept as "improvement" | p < 0.10 gate added ✓ |
| Baseline re-measured on every resume | 153s wasted each restart | Baseline skip on resume added ✓ |

---

## 8. Recommendations for Experiment 5

1. **Validate the p=0.23 kept change**: Run cross-session head-to-head before claiming it as upstream-worthy. The new p-value gate would have reverted this.

2. **Test memory bandwidth hypothesis**: Profile whether the benchmark is compute-bound or bandwidth-bound at 2^20 × 256. If bandwidth-bound, redirect effort to cache access patterns rather than arithmetic.

3. **Confirm `edit_file` deployment**: Verify the tool is live on the server before next run — will prevent the 3× full-file write problem.

4. **Consider the add/sub mask idea further**: The correctly-executed version (Run 4) showed a signal. But with p=0.23, it needs validation. Could also try combining with other port 0 reductions.

5. **Explore `mul` latency vs throughput**: The `mul` at 6.5 cyc/vec throughput, 21 cyc latency is the dominant cost. Any latency reduction in the critical path (even at throughput cost) could help the sequential DFT layers.
