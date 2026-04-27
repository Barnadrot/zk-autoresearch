# leanMultisig — zk-alloc benchmark results

**Date:** 2026-04-26
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 61GB DDR5)
**Workload:** xmss_aggregate, 1400 signatures, log_inv_rate=1
**DFT:** Parallel (rayon, 8-16 threads)
**All proofs cryptographically verified via xmss_verify_aggregation.**

## Warm proof time (proof 2-3 average)

| Config | glibc | mimalloc (LD_PRELOAD) | zk-alloc | vs glibc | vs mimalloc |
|--------|-------|----------------------|----------|----------|-------------|
| 64GB / 16c | 3.14s | ~3.05s (-2.9%) | 2.31s | **-26.4%** | **-24.2%** |
| 64GB / 8c | 3.33s | ~3.23s (-2.9%) | 2.36s | **-29.1%** | **-26.9%** |
| 32GB / 16c | 3.07s | — | 2.31s | **-24.8%** | — |
| 32GB / 8c | 3.36s | — | 2.38s | **-29.2%** | — |
| 16GB / 16c | 3.18s | — | 2.30s | **-27.5%** | — |
| 16GB / 8c | 3.32s | — | 2.39s | **-28.1%** | — |

Note: mimalloc numbers from LD_PRELOAD prototype testing phase (exp3a).
jemalloc was not tested on leanMultisig.

## Idle gap resilience

| Sleep between proofs | Warm proof |
|---------------------|-----------|
| 0ms (back-to-back) | 2.42s |
| 1.8s (prod: 4s block - 2.2s prove) | 2.40s |
| 10s | 2.40s |
| 30s | 2.43s |

## Key observations

1. **-27% average warm proof speedup** vs glibc across all configurations.
2. **mimalloc achieves only -0.5% to -2.9%** — general-purpose allocators can't eliminate
   per-allocation metadata and free-list overhead.
3. **Idle gap has zero effect** — pages stay resident in process virtual address space.
4. **Multi-threaded workload** — rayon parallel DFT means glibc's arena lock contention
   adds overhead that the thread-local bump allocator avoids entirely.
