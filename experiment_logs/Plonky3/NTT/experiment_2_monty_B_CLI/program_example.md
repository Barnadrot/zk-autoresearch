# Attention Kernel Autoresearch

## Role
You are an expert GPU kernel engineer specializing in Triton and CUDA. Your job is to make the block-sparse attention forward kernel as fast as possible on H100.

## The Challenge
You are optimizing `submission/submission.py` — a Triton kernel implementing block-sparse causal attention forward pass. The evaluation harness is in `attention-kernel-challenge/`.

**Fixed constants:** `BLOCK_SIZE = 128`, `HEAD_DIM = 128`, inputs in bfloat16.

**Sparsity structure (CSR format):**
- `row_ptr[batch, head, q_block]` → start index into `col_idx` for that query block
- `col_idx[batch, head, i]` → which key block that query block attends to
- Three families: `sliding_window`, `sliding_window_global`, `sliding_window_retrieval`

**Function signature:**
```python
block_sparse_attn_fwd(q, k, v, row_ptr, col_idx, seq_lens) -> (o, lse)
# q, k, v: (batch, heads, t_max, head_dim) bfloat16
# o: same shape, bfloat16
# lse: (batch, heads, t_max) float32
```

## The Metric
**Lower is better.** Score = geometric mean of per-family median latency in ms across 3 families.

## How to Evaluate

**Run the eval script (correctness + timing, use this in the loop):**
```bash
cd /home/agent/attention-kernel-research && /venv/main/bin/python -m attention_kernel_challenge eval-submission --submission-dir submission/ --suite quick --device cuda --serverlike > eval.log 2>&1
cat eval.log
```

The `--serverlike` flag enables `isolate_submission_process=True`, which matches Modal's evaluation environment exactly (including the subprocess sandbox). This catches submission failures before they reach the leaderboard. Parse the `Geometric mean family latency (ms)` line — that is your score. Lower is better.

**Baseline: quick geomean = 0.32ms** (all_correct=True, established with num_stages=1, num_warps=4)

## Files
- `submission/submission.py` — **the only file you edit**
- `attention-kernel-challenge/attention_kernel_challenge/reference.py` — reference implementation (read-only, ground truth)
- `attention-kernel-challenge/example_submission/submission.py` — PyTorch baseline (read-only, for reference)
- `iters.tsv` — your experiment log (append one row after each iteration)

## Experiment Loop

LOOP FOREVER:

1. Read `iters.tsv` to understand what has been tried, what params were used, and what the current best score is.
2. Read `submission/submission.py` to understand the current kernel.
3. Devise ONE targeted change. Think about what to change and why before touching code.
4. Edit `submission/submission.py`.
5. `git commit -am "iter N: <short description>"`
6. Run eval: `/venv/main/bin/python /home/agent/eval.py > eval.log 2>&1`
7. Read `eval.log`. Extract quick suite geomean ms and per-family scores.
8. If correctness failed or crashed: try a quick fix, or `git revert HEAD` and try a different idea.
9. If score improved: keep the change, append row to `iters.tsv`.
10. If score did not improve: `git revert HEAD`, append row to `iters.tsv`.

## Logging

Append one tab-separated row to `iters.tsv` after every experiment. The file has a header row already. Columns:

```
iter	geomean_ms	delta_ms	window_ms	global_ms	retrieval_ms	status	params	description
```

- `iter`: incrementing iteration number
- `geomean_ms`: geometric mean latency across 3 families (the actual score) — use `-` if crashed
- `delta_ms`: change from previous best, negative = faster — use `-` for baseline or crash
- `window_ms`: median latency for sliding_window family — use `-` if crashed
- `global_ms`: median latency for sliding_window_global family — use `-` if crashed
- `retrieval_ms`: median latency for sliding_window_retrieval family — use `-` if crashed
- `status`: `keep`, `discard`, or `crash`
- `params`: compact key=value pairs for tuning knobs changed this iter (e.g. `num_warps=8,num_stages=3`) — use `-` if not applicable
- `description`: what you changed and why (no tabs in this field)

Example rows:
```
1	-	-	-	-	-	keep	num_warps=4,num_stages=1	baseline Triton Flash Attention kernel
2	22.1	-2.2	20.1	22.8	23.4	keep	num_warps=8,num_stages=2	more warps + 2-stage pipeline
3	22.9	+0.8	21.0	23.5	24.2	discard	num_warps=8,num_stages=3	3-stage pipeline — slower
4	-	-	-	-	-	crash	num_warps=16,num_stages=2	too many warps — OOM
```

## H100 Optimization Hints

These are non-obvious insights for H100 specifically — start here before exploring blindly:

- **Use bf16 for tl.dot inputs, fp32 for accumulation.** H100 tensor cores run bf16 matmuls natively. Keeping Q/K in bf16 for `tl.dot(q, k.T)` and V in bf16 for `tl.dot(p, v)` maximizes tensor core throughput. Only convert to fp32 for the softmax numerics. The current baseline converts to fp32 immediately after load — this is the first thing to fix.
- **Pipeline stages (`num_stages`).** Triton's software pipelining overlaps memory loads with compute. Try `num_stages=2` or `3` in `@triton.jit` — this is often the single biggest win on memory-bound kernels.
- **Warp count (`num_warps`).** Default is 4. Try 8 for this workload (BLOCK_SIZE=128, HEAD_DIM=128). More warps = better latency hiding but more register pressure.
- **Persistent kernels.** Launch overhead accumulates across many small Q blocks. A persistent kernel that loops over multiple Q blocks per program can reduce this.
- **Variant specialization.** `sliding_window` has denser sparsity patterns (more K blocks per Q block) than `sliding_window_retrieval`. Declare multiple variants in `VARIANT_MANIFEST` to tune `num_warps`/`num_stages` per family. Read `cases.py` for exact shapes per family.
- **setup() for JIT warmup.** The first kernel call pays JIT compilation cost. Use `setup()` to pre-warm the Triton kernel with representative inputs so the loop iteration pays zero compilation overhead.

## What to Optimize

The kernel is a Triton Flash Attention implementation for block-sparse patterns. Areas to explore:
- **Tile sizes and block shapes** — experiment with constexpr tile dimensions
- **Memory access patterns** — coalescing, vectorized loads, avoid bank conflicts
- **Instruction-level** — fused ops, reduced type conversions, eliminate redundant ops
- **Pipeline / prefetching** — overlap compute and memory loads
- **Variant specialization** — VARIANT_MANIFEST can declare specialized kernels per family or t_max range
- **setup() compilation** — use setup() to torch.compile or pre-warm Triton JIT
- **Algorithm** — online softmax accumulation order, skipping fully masked blocks early

Read `attention-kernel-challenge/attention_kernel_challenge/cases.py` to understand what input shapes the `quick` and `full` suites use, so you can tune for the actual workload.

## Hard Constraints

1. **Only edit `submission/submission.py`** — nothing else.
2. **Maintain correctness** — output `o` (bfloat16) and `lse` (float32) must match reference within tolerances: `output_atol=1e-3, output_rtol=1e-2, lse_atol=1e-5, lse_rtol=1e-5`.
3. **Only import `torch`, `triton`, `numpy`** — no other top-level imports. (`import math` is also fine.)
4. **`VARIANT_MANIFEST` must be defined** — at minimum `[{"name": "default"}]`.
5. **`setup()` has 30s budget** — don't make it too slow.
7. **`num_stages` must be 1 or 2.** `num_stages=3` triggers a different Triton compilation path that invokes a blocked subprocess on Modal's evaluation backend (Python 3.11, torch 2.8.0, triton 3.4.0). Confirmed: submissions with `num_stages=3` fail evaluation. Stick to `num_stages=2` max.

6. **`setup()` MUST pre-warm the kernel.** The evaluation sandbox blocks subprocess calls (including `ptxas`) during timed evaluation. Triton JIT-compiles on first call — if setup() doesn't warm the kernel, the first timed call triggers compilation inside the sandbox and the submission crashes. Always call the kernel in setup() with a dummy input:

```python
def setup(suite_specs, device, variants):
    B, H, T = 1, 1, BLOCK_SIZE * 2
    q = torch.zeros((B, H, T, HEAD_DIM), device=device, dtype=torch.bfloat16)
    k = torch.zeros_like(q)
    v = torch.zeros_like(q)
    row_ptr = torch.zeros((B, H, T // BLOCK_SIZE + 1), device=device, dtype=torch.int32)
    col_idx = torch.zeros((B, H, 1), device=device, dtype=torch.int32)
    seq_lens = torch.tensor([T], device=device, dtype=torch.int32)
    block_sparse_attn_fwd(q, k, v, row_ptr, col_idx, seq_lens)
    torch.cuda.synchronize()
    return None
```

This is also a free speedup — zero compilation cost during timed eval.

## CRITICAL: Padding Constraint (read before touching allocation or stores)

`o` is allocated with `torch.empty_like` and `lse` with `torch.empty`. This is intentional and correct ONLY because the kernel encodes padding via `tl.where` in the finalize step with **unmasked stores**:

```python
# Correct pattern — tl.where encodes padding, store is unmasked:
out = tl.where(q_mask[:, None], acc / l_safe[:, None], 0.0)
lse_out = tl.where(q_mask, m_i + tl.log(l_safe), float("-inf"))
tl.store(O_ptr + ..., out.to(tl.bfloat16))   # NO mask= argument
tl.store(LSE_ptr + ..., lse_out)              # NO mask= argument
```

**DO NOT:**
- Remove the `tl.where` in the finalize step (padding positions would get garbage values)
- Add `mask=q_mask` back to the stores (redundant + slower)
- Switch back to `torch.zeros_like` / `torch.full(..., -inf)` unless you also add store masks

**bf16 dot inputs break correctness.** The tolerance is 1e-3. Loading Q/K/V as bf16 and doing `tl.dot` in bf16 accumulation exceeds this. Keep: load → bf16, convert to fp32 for `tl.dot` inputs, accumulate in fp32.

## NEVER STOP

Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped. If you run out of ideas, re-read the reference implementation, read the cases file for workload characteristics, and think harder about what hasn't been tried.
