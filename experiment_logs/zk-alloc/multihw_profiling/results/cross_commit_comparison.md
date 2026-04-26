# Cross-commit profiling comparison

Machine: Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 61GB DDR5)
Workload: xmss_aggregate, 1400 sigs, log_inv_rate=1
Date: 2026-04-26
zkalloc version: v0.1 (4GB×16 slab, LD_PRELOAD arena)

## Commits tested

| Tag | Commit | Description |
|-----|--------|-------------|
| exp3a | pre-AVX512-fix | Codebase used in exp1-exp3a. Has packing_width bug in eq_mle.rs |
| bench-v1 | 28c1451f | Post-AVX512 fix (packing_width → log_packing_width). Pinned at myfork/zk-alloc/bench-v1-post-avx-fix |
| bench-v2 | 1ca8b836 | Current upstream + alloc-removal PRs. Pinned at myfork/zk-alloc/bench-v2-current |

## Warm proof average (proof 2-3), 64GB unconstrained

### 16 cores

| Commit | glibc | zkalloc | vs glibc | mimalloc | vs glibc |
|--------|-------|---------|----------|----------|----------|
| exp3a | 3.848s | 3.555s | **-7.6%** | 3.914s | +1.7% |
| bench-v1 | 3.171s | OOM | — | 3.177s | +0.2% |
| bench-v2 | 3.152s | OOM | — | 3.208s | +1.7% |

### 8 cores

| Commit | glibc | zkalloc | vs glibc | mimalloc | vs glibc |
|--------|-------|---------|----------|----------|----------|
| exp3a | 4.003s | 3.663s | **-8.5%** | 3.907s | -2.4% |
| bench-v1 | 3.381s | OOM | — | 3.397s | +0.4% |
| bench-v2 | 3.375s | OOM | — | 3.280s | -2.8% |

## Cold start (proof 0), 64GB unconstrained

| Commit | Cores | glibc | zkalloc | mimalloc |
|--------|-------|-------|---------|----------|
| exp3a | 16c | 3.803s | 3.990s (+4.9%) | 3.807s (+0.1%) |
| exp3a | 8c | 3.966s | 4.189s (+5.6%) | 3.898s (-1.7%) |
| bench-v1 | 16c | 3.082s | OOM | 3.103s (+0.7%) |
| bench-v1 | 8c | 3.382s | OOM | 3.244s (-4.1%) |
| bench-v2 | 16c | 3.075s | OOM | 3.130s (+1.8%) |
| bench-v2 | 8c | 3.410s | OOM | 3.302s (-3.2%) |

## Key findings

1. **AVX512 fix = 18% speedup** (exp3a → bench-v1). glibc 16c: 3.848s → 3.171s.
   This dwarfs any allocator advantage. The fix changes the allocation profile enough
   to overflow zkalloc's 4GB per-thread slab.

2. **Alloc-removal PRs (bench-v1 → bench-v2) = noise**. 3.171s → 3.152s at 16c.
   The batch_stir_queries removals did not materially affect wall time on this workload.

3. **zkalloc v0.1 is broken on post-AVX512-fix codebases**. OOMs at 64GB unconstrained.
   The 4GB×16 slab design is a hard blocker. Direction F (slab sizing) is now critical-path.

4. **mimalloc pattern holds on new codebases**: -2.8% at 8c on bench-v2, regression at 16c.
   Consistent with exp3a observations.

5. **The -8.5% zkalloc advantage was measured on a buggy codebase**. We don't know
   if the advantage holds post-fix until slab sizing is resolved. The allocation profile
   may be fundamentally different.
