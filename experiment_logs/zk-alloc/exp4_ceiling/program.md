# exp4: ceiling check — is -27% the limit?

Status: ACTIVE
Baseline: zkalloc v0.2 (8GB slab, MAP_NORESERVE, LD_PRELOAD) = -27% vs glibc on bench-v2
Machine: Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 61GB DDR5)

## Context

exp3.5 established -27% with a 200-line bump+reset arena. Three of the original
six exp4 directions are already resolved:

- **F (memory pressure)**: SOLVED by MAP_NORESERVE. Works at 16/32/64GB.
- **E (alternative allocators)**: ANSWERED. mimalloc -2.9%, gap is structural.
- **D-cold (cold start)**: ANSWERED. No penalty — cold matches glibc, warm is the win.

This experiment checks whether the remaining three directions can push past -27%,
or whether we're at the local optimum. Compact format: 2 iters per direction,
stop if no signal.

## Protocol

1. Reset to v0.2 baseline before each iter
2. One change, measure: `prove_loop 3` at 64GB/16c
3. Record wall time, perf stat delta, RSS
4. SIGNAL if ≥2% improvement over v0.2 baseline (i.e. better than -27% vs glibc)

v0.2 warm baseline: **2.31s** at 16c, **2.36s** at 8c

## Direction B: Size-segregated regions

Hypothesis: Routing small allocs (≤128B, ~70% of allocs) to a dense slab
improves L1/L2 hit rate. Large allocs go to a separate region.

**Iter B1**: Two-slab split in LD_PRELOAD. Small slab (2GB, ≤256B) + large slab
(6GB, >256B). Both reset at phase_boundary. Threshold chosen to capture the
dense small-alloc majority without splitting medium allocs.

**Iter B2**: Based on B1 signal. If positive, tune threshold. If negative, try
alignment-aware routing (cache-line-aligned small slab).

## Direction D: Kernel memory hints

Hypothesis: THP or madvise tuning can improve the warm-proof page behavior.
The v0.2 arena already uses MADV_HUGEPAGE — but with reset, the THP calculus
may be different.

**Iter D1**: MADV_DONTNEED at phase_boundary reset. Returns physical pages to
the kernel between proofs, then re-faults on demand. Tests RSS reduction vs
re-fault cost.

**Iter D2**: Disable MADV_HUGEPAGE (use 4KB pages). THP can cause latency
spikes from compaction. Test whether 4KB pages are actually faster for the
bump pattern.

## Direction A: Delivery without LD_PRELOAD

Hypothesis: GlobalAlloc loses ~5pp of parallelism. Quantify the actual cost
on v0.2 to know if it matters.

**Iter A1**: Re-enable `#[global_allocator]` with the v0.2 arena (8GB slab,
MAP_NORESERVE, RESET). Measure parallelism gap vs LD_PRELOAD.

**Iter A2**: If gap exists, try `-Wl,--wrap,malloc` link-time wrapping as
a middle ground — no LD_PRELOAD, no GlobalAlloc.

## Exit criteria

- If all 6 iters show NO SIGNAL: v0.2 is the local optimum. Ship it.
- If any iter shows ≥2% improvement: extend that direction with 3 more iters.
- Budget: ~2 hours total. This is validation, not exploration.

## Dependencies (all met)

- [x] v0.2 .so built and verified
- [x] prove_loop with verification support
- [x] Profiling harness validated
- [x] bench-v2 pinned and tested
- [x] mimalloc .so built
- [x] Memory limiting validated
