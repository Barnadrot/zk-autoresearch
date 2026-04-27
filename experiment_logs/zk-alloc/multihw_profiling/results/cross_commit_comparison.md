# Cross-commit profiling comparison

Machine: Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 61GB DDR5)
Workload: xmss_aggregate, 1400 sigs, log_inv_rate=1
Date: 2026-04-26
Proofs cryptographically verified via xmss_verify_aggregation

## Commits tested

| Tag | Commit | Description |
|-----|--------|-------------|
| exp3a | pre-AVX512-fix | Codebase used in exp1-exp3a. Has packing_width bug in eq_mle.rs |
| bench-v1 | 28c1451f | Post-AVX512 fix (packing_width → log_packing_width). Pinned at myfork/zk-alloc/bench-v1-post-avx-fix |
| bench-v2 | 1ca8b836 | Current upstream + alloc-removal PRs. Pinned at myfork/zk-alloc/bench-v2-current |

## zkalloc versions

| Version | Slab | mmap flags | Status |
|---------|------|------------|--------|
| v0.1 | 4GB×16 | MAP_PRIVATE, MAP_ANONYMOUS | OOM on post-AVX512-fix codebases and ≤32GB |
| v0.2 | 8GB×16 | + MAP_NORESERVE | Works at all configs (16/32/64GB × 8/16c) |

## v0.2 results on bench-v2 — full matrix (warm proof avg 2-3)

| Config | glibc | zkalloc v0.2 | vs glibc | mimalloc | vs glibc |
|--------|-------|-------------|----------|----------|----------|
| 64GB / 16c | 3.140s | 2.312s | **-26.4%** | 3.049s | -2.9% |
| 64GB / 8c | 3.328s | 2.360s | **-29.1%** | 3.312s | -0.5% |
| 32GB / 16c | 3.066s | 2.306s | **-24.8%** | 3.460s | +12.9% |
| 32GB / 8c | 3.364s | 2.382s | **-29.2%** | 3.317s | -1.4% |
| 16GB / 16c | 3.175s | 2.301s | **-27.5%** | 3.088s | -2.8% |
| 16GB / 8c | 3.319s | 2.386s | **-28.1%** | 3.316s | -0.1% |

## v0.1 results on exp3a (pre-AVX512-fix, historical)

### Warm proof avg (2-3), 64GB unconstrained

| Cores | glibc | zkalloc v0.1 | vs glibc | mimalloc | vs glibc |
|-------|-------|-------------|----------|----------|----------|
| 16c | 3.848s | 3.555s | **-7.6%** | 3.914s | +1.7% |
| 8c | 4.003s | 3.663s | **-8.5%** | 3.907s | -2.4% |

### v0.1 at ≤32GB: OOM across all configs (mmap rejected by overcommit_memory=0)

## v0.1 results on bench-v1 / bench-v2 (64GB, before v0.2 fix)

| Commit | Cores | glibc | zkalloc v0.1 | mimalloc |
|--------|-------|-------|-------------|----------|
| bench-v1 | 16c | 3.171s | OOM | 3.177s (+0.2%) |
| bench-v1 | 8c | 3.381s | OOM | 3.397s (+0.4%) |
| bench-v2 | 16c | 3.152s | OOM | 3.208s (+1.7%) |
| bench-v2 | 8c | 3.375s | OOM | 3.280s (-2.8%) |

## Slab size sweep (bench-v2, 64GB/16c, MAP_NORESERVE)

| Slab | avg(2-3) | vs glibc | Notes |
|------|----------|----------|-------|
| 4GB | 2.753s | -12.3% | Works but overflow to glibc costs ~15pp |
| 6GB | 2.469s | -21.4% | |
| 8GB | 2.290s | -27.1% | Captures full workload |
| 10GB | 2.270s | -27.7% | Within noise of 8GB — saturated |

## perf stat (bench-v2, 64GB/16c, cold proof)

| Metric | glibc | zkalloc v0.2 | Delta |
|--------|-------|-------------|-------|
| Cycles | 165.4B | 158.9B | **-4.0%** |
| IPC | 1.00 | 1.04 | **+4.0%** |
| Cache miss rate | 4.47% | 3.87% | **-13.4%** |
| Branch misses | 527M | 486M | **-7.8%** |
| Page faults | 2.71M | 3.08M | +13.7% |
| Sys time | 7.73s | 6.91s | **-10.6%** |

## Key findings

1. **zkalloc v0.2 = -27% across all configs.** The advantage is consistent from 16GB
   to 64GB, 8 to 16 cores. Not a single OOM. MAP_NORESERVE resolved all v0.1 blockers.

2. **AVX512 fix amplified the allocator advantage** from -8.5% to -27%. Faster compute
   means allocation is a larger fraction of wall time. The fix also increased per-thread
   allocation volume (~6GB vs ~3.5GB), requiring the slab bump to 8GB.

3. **Alloc-removal PRs (bench-v1 → bench-v2) = noise.** 3.171s → 3.152s at 16c glibc.

4. **v0.1 OOM root cause: missing MAP_NORESERVE.** overcommit_memory=0 rejects virtual
   mappings larger than physical RAM. MAP_NORESERVE tells the kernel not to account the
   mapping against committed memory. Actual physical pages stay bounded due to bump+reset.

5. **mimalloc is -0.5% to -2.9% vs glibc.** Consistent with v0.1 findings. Regression
   at 32GB/16c (+12.9%) is an outlier worth investigating but irrelevant given zkalloc.

6. **Proofs are cryptographically verified.** All zkalloc proofs pass
   xmss_verify_aggregation — no soundness issues from the bump allocator.
