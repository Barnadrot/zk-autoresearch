# exp4: signal search — what's beyond -7.2%?

Status: DRAFT — do not run until profiling harness (multihw_profiling) is complete

## Context

exp3a achieved -7.2% vs glibc with a single bump+reset arena via LD_PRELOAD.
That result came from 9 iterations, with the breakthrough in the last 2.
Of 32 total iterations across exp1-3a, only ~18 were design exploration,
and most tested variations of the same single-arena approach.

We have weak confidence that single bump+reset is optimal. This experiment
explores fundamentally different architectures to find which directions
produce validity signals — not to ship a final design.

## Approach: 5-iteration signal loop per direction

Each DIRECTION gets its own 5-iteration loop. A direction is a distinct
architectural idea (e.g. "multi-arena per phase" or "link-time wrapping").

### Loop structure

- **Iters 1-2: preset.** We specify exactly what the agent implements.
  Two concrete strategies that test the core hypothesis of the direction.
  Always reset to baseline before each iter.
- **Iters 3-5: free-roaming.** Agent decides approach based on signals
  from iters 1-2. Can refine a promising preset, try a variation, or
  pivot within the direction. Always reset to baseline before each iter.

### Per-iteration protocol

1. Reset to baseline (LD_PRELOAD bump+reset arena, exp3a iter 9)
2. Implement one approach (minimal, ≤200 lines changed)
3. Measure: `prove_loop 3` against glibc baseline
4. Record: wall time delta, perf stat (page faults, cache misses, IPC, CPUs), RSS
5. Verdict: SIGNAL / NO SIGNAL / REGRESSION
6. Log to iters.tsv

### Why always reset

Prevents compounding hacks. Each iteration is independently measurable
against the same baseline. If iter 2 shows -3% and iter 4 shows -5%,
we know they're independent findings, not one built on the other.

## Directions to explore

Each direction below becomes its own 5-iteration loop. Run sequentially.
Prioritize by strength of prior signal.

### Direction A: Delivery mechanism (parallelism recovery)

Question: Can we match LD_PRELOAD's parallelism (10.04 CPUs) without
LD_PRELOAD?

Preset iters:
1. Link-time wrapping (`-Wl,--wrap,malloc`) with RESET arena in Rust.
   No LD_PRELOAD, no GlobalAlloc, one binary.
2. `#[inline(never)]` GlobalAlloc with RESET. Iter 7 without RESET was
   +5.9%, but RESET changes page behavior — retest.

Free-roaming (3 iters): agent follows signal. Candidates: PGO on
GlobalAlloc binary, LTO tuning, `perf sched` to profile the parallelism
gap directly.

Prior: exp3a iter 8 (GlobalAlloc RESET) = -1.4% at 8.9 CPUs. Gap to
LD_PRELOAD is ~5.8pp of parallelism.

### Direction B: Size-segregated regions

Question: Does separating small (≤128B, 70% of allocs) and large
allocations into different memory regions improve cache behavior?

Preset iters:
1. Two bump regions in the LD_PRELOAD .so: small slab (1GB, dense) and
   large slab (3GB). Route by size at malloc. Both reset at phase_boundary.
2. Three regions: small (≤128B), medium (129B-4KB), large (>4KB). Tests
   whether the medium range matters.

Free-roaming (3 iters): agent follows signal. Candidates: size threshold
tuning, alignment-aware routing, separate THP policy per region.

Prior: No direct prior. 70% ≤128B is from exp3 profiling. Hypothesis is
that dense packing of small allocs improves L1/L2 hit rate.

### Direction C: Multi-arena per proving phase

Question: Do different proving phases benefit from different allocation
strategies?

Preset iters:
1. Separate arenas for witness gen (phase 0-0.5s) vs rest. Witness gen is
   small+hot; commitment/GKR are large+sequential. Switch arena at the
   phase transition. Both reset at proof boundary.
2. Per-phase RSS tracking WITHOUT changing allocation. Instrument the
   existing arena to log per-phase alloc count, bytes, and peak live.
   This is a profiling iter — produces data for free-roaming iters.

Free-roaming (3 iters): agent follows signal from the profiling data.
If phases have genuinely different patterns, explore phase-specific tuning.
If they don't, this direction is NO SIGNAL — move on.

Prior: exp3 profiling identified 5 phases but we never measured per-phase
allocation behavior in detail. exp3 also showed ALL intra-proof boundaries
are unsafe (1-4.6GB live), so phase switching is about locality, not reset.

### Direction D: Kernel-level memory management

Question: Can we eliminate the remaining page fault cost with prefaulting
or smarter madvise?

Preset iters:
1. MAP_POPULATE on arena slabs — pre-fault all pages at init. Trades
   startup cost for zero minor faults during proving.
2. MADV_DONTNEED at phase_boundary + MADV_WILLNEED before next proof.
   Returns physical pages (RSS drops) then prefaults them back. Tests
   whether the round-trip is cheaper than holding pages resident.

Free-roaming (3 iters): agent follows signal. Candidates: userfaultfd,
MADV_HUGEPAGE tuning (2MB vs 1GB pages), mlock to pin pages.

Prior: THP (MADV_HUGEPAGE) was tested in exp3a iter 1 with no improvement.
But that was without RESET — page reuse changes the THP calculus.

### Direction E: Alternative allocators as baseline

Question: How much of zk-alloc's advantage is vs glibc specifically,
vs any modern allocator?

Preset iters:
1. mimalloc via LD_PRELOAD (no zk-alloc). Baseline comparison — how does
   mimalloc's thread-local design compare to glibc and our arena?
2. mimalloc + phase boundary hint. Patch mimalloc to call mi_heap_collect
   at phase_boundary. Tests whether a general allocator with reset hints
   can match the bump arena.

Free-roaming (3 iters): agent follows signal. Candidates: jemalloc,
snmalloc, tcmalloc. Or: mimalloc with custom heap per proof
(mi_heap_new / mi_heap_destroy).

Prior: exp3a iter 4 — mimalloc matched glibc at -0.2%. But that was
without any phase hints. The question is how much phase awareness helps
a general allocator.

### Direction F: Memory pressure / constrained environments

Question: How does zk-alloc behave on 16GB and 32GB machines?

Preset iters:
1. Current zk-alloc (4GB × 16 slabs) under systemd-run MemoryMax=16G.
   Expected: OOM. Record when and how it fails.
2. Reduced slab (512MB × 16 = 8GB) with glibc overflow. Measure how much
   performance degrades when ~50% of allocs spill to glibc.

Free-roaming (3 iters): agent follows signal. Candidates: dynamic slab
sizing from /proc/meminfo, MADV_DONTNEED at reset to bound RSS, adaptive
slab count (fewer threads = larger slabs).

Prior: Current design is 64GB virtual. Works on 64GB machine. Untested
elsewhere. Profiling shows ~1.1GB peak per thread.

## Baselines

All measurements against two pinned commits:
- `myfork/zk-alloc/bench-v1-post-avx-fix` (28c1451f) — correct AVX512, pre-alloc-removal
- `myfork/zk-alloc/bench-v2-current` (1ca8b836) — all upstream optimizations

Three allocators at each commit:
- glibc (no LD_PRELOAD, no GlobalAlloc)
- zk-alloc bump+reset (LD_PRELOAD preload_arena.so)
- mimalloc (LD_PRELOAD libmimalloc.so)

## Success criteria

Per iteration — a SIGNAL if:
- Wall time delta ≥2% (either direction)
- OR perf stat change ≥10% in page faults, cache misses, or CPUs utilized
- OR RSS change ≥20%

Per direction (after 5 iters) — PROMISING if ≥2 iters show signal in the
same direction. DEAD END if 0-1 iters show signal.

## Priority order

Run directions in this order (strongest prior signal first):
1. **E: Alternative allocators** — cheapest to run (just swap .so), establishes
   whether zk-alloc's advantage is real vs modern allocators, not just glibc
2. **A: Delivery mechanism** — answers the GlobalAlloc question that blocks
   pure-Rust delivery
3. **F: Memory pressure** — must be solved for production regardless of other results
4. **B: Size-segregated regions** — cache locality hypothesis, moderate prior
5. **D: Kernel-level** — prefaulting hypothesis, moderate prior
6. **C: Multi-arena per phase** — weakest prior signal, most implementation complexity

## What this experiment is NOT

- Not trying to ship a production allocator
- Not building across directions — each direction is independent
- Not exhaustive — 5 iters per direction is signal search, not optimization
- Not committed to all 6 directions — stop early if clear winner emerges

## Dependencies

- [ ] multihw_profiling harness complete and baselined
- [ ] prove_loop binary validated
- [ ] Pinned branches built and tested
- [ ] mimalloc .so built for this machine
- [ ] Memory limiting validated (systemd-run + swapoff)
