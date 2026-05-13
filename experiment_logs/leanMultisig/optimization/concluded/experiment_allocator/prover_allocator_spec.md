# prover-alloc: a production memory allocator for ZK proving

## Motivation

Every ZK proving team (SP1, Plonky3, Halo2, Stwo, Barretenberg, Risc Zero) uses
off-the-shelf general-purpose allocators (jemalloc, mimalloc, glibc). No allocator
exists that exploits the specific structure of ZK proving workloads.

Our profiling data from experiment 6 (17 iterations, heaptrack + custom GlobalAlloc
instrumentation) reveals why general-purpose allocators leave performance on the table:

- **Allocator contention is the #1 bottleneck.** 3 of 4 KEEPs (-2.12%, -3.25%,
  -1.90%) targeted Rayon threads competing for glibc arena locks during concurrent
  reallocation cascades. General-purpose allocators treat thread contention as a
  secondary concern; in proving it's the primary one.
- **Cache traffic dominates after contention is fixed.** The largest single win
  (-16.8%) came from restructuring memory access patterns to fit L2. Allocators
  don't control traversal order, but they control *where* objects land in physical
  memory — layout determines cache behavior.
- **Phase structure is ignored.** Proving has clear phases (witness → commit →
  logup → sumcheck → WHIR/FRI). Each phase allocates heavily, then frees
  everything. General-purpose allocators maintain free lists across phase
  boundaries, fragmenting the heap. A phase-aware allocator can bulk-reset in O(1).
- **mimalloc's tradeoff is fundamental to general-purpose design.** -24% under
  memory pressure (16GB), +3.6% regression with headroom (64GB). The aggressive
  page retention that helps under pressure wastes cache lines with headroom. A
  proving allocator can adapt because it knows the workload structure.

## Design principles

1. **Drop-in `GlobalAlloc`.** Must work as `#[global_allocator]` with zero
   application code changes. The allocator handles everything internally.
2. **Rayon-native.** Thread-local arenas that understand Rayon's thread pool
   topology. Zero cross-thread synchronization on the hot path.
3. **Phase-aware.** Automatic phase detection via allocation pattern recognition
   (size-class distribution shifts between phases are distinctive). Bulk arena
   reset at phase boundaries.
4. **Adaptive.** Runtime memory-pressure detection via `/proc/meminfo` (or
   equivalent). Aggressive retention under pressure, eager return with headroom.
5. **Huge-page opportunistic.** Large allocations (>2MB) backed by transparent
   huge pages when available, reducing TLB pressure for polynomial buffers.
6. **Measurable.** Built-in lightweight telemetry (phase transitions, contention
   events, arena utilization) that can be enabled without recompilation.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   GlobalAlloc API                    │
│              (alloc, dealloc, realloc)               │
├─────────────────────────────────────────────────────┤
│                  Size Router                         │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │  Small    │  │   Medium     │  │    Large       │ │
│  │  ≤512B   │  │  512B–2MB    │  │   >2MB         │ │
│  │  Bump    │  │  Pool        │  │   mmap/huge    │ │
│  └──────────┘  └──────────────┘  └───────────────┘ │
├─────────────────────────────────────────────────────┤
│              Thread-Local Arena Layer                │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│  │ Worker 0│ │ Worker 1│ │ Worker 2│ │ Worker N│  │
│  │  Arena  │ │  Arena  │ │  Arena  │ │  Arena  │  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
├─────────────────────────────────────────────────────┤
│              Phase Manager                           │
│  ┌──────────────────────────────────────────────┐   │
│  │ Pattern detector → phase transition → reset  │   │
│  └──────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│              Pressure Adaptor                        │
│  ┌──────────────────────────────────────────────┐   │
│  │ /proc/meminfo poll → retention policy adjust │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Component details

### 1. Size router

Three allocation paths based on size class:

| Class | Size range | Strategy | Rationale |
|-------|-----------|----------|-----------|
| Small | ≤512B | Thread-local bump allocator | Field element Vecs (32–640B) dominate. Bump = pointer increment, zero overhead. Our profiling shows 70%+ of allocs are in this range. |
| Medium | 512B–2MB | Thread-local size-class pool | Polynomial scratch buffers. Power-of-two size classes (1KB, 2KB, ..., 2MB) with per-thread free lists. Covers trace columns, eq_mle temp buffers, sumcheck scratch. |
| Large | >2MB | Direct mmap with optional huge pages | NTT twiddle tables, full polynomial coefficient arrays, Merkle tree buffers. THP via `madvise(MADV_HUGEPAGE)` when available. |

Size class boundaries derived from experiment 6 profiling data:
- 70% of allocs: ≤128B (Rayon chunk Vecs, field element slices)
- 20% of allocs: 128B–64KB (trace columns, sumcheck buffers)
- 9% of allocs: 64KB–4MB (eq_mle buffers, matrix rows)
- 1% of allocs: >4MB (full polynomial buffers, Merkle trees)

### 2. Thread-local arena layer

Each Rayon worker thread gets a dedicated arena. Key properties:

- **No locks on alloc/dealloc.** The arena is thread-local; only the owning
  thread touches it. This eliminates the glibc arena lock contention that was
  the mechanism behind our 3 allocation KEEPs.
- **Cross-thread dealloc via message passing.** When Rayon work-stealing causes
  an object allocated on thread A to be freed on thread B, thread B posts the
  pointer to A's deferred-free queue (lock-free MPSC). Thread A processes the
  queue on its next allocation. This is the snmalloc approach — proven at scale.
- **Arena sizing.** Initial arena: 16MB per worker (covers 95th percentile phase
  memory from profiling). Grows by doubling. Shrinks at phase boundaries.

```rust
struct WorkerArena {
    small: BumpRegion,          // bump pointer for ≤512B
    pools: [FreeList; 12],      // size-class pools: 1KB, 2KB, ..., 2MB
    deferred_free: MpscQueue,   // cross-thread frees
    phase_watermark: usize,     // high-water mark this phase
    thread_id: usize,
}
```

### 3. Phase manager

Automatic phase detection without application instrumentation. Two mechanisms:

**Passive detection (default):** Monitor allocation pattern shifts. Each phase
has a distinctive size-class signature:

| Phase | Dominant size class | Pattern |
|-------|-------------------|---------|
| Witness generation | Small (32–128B) | Many small allocs, sequential |
| Trace commit | Medium (4KB–64KB) | Parallel burst of similarly-sized columns |
| NTT/DFT | Large (1MB–84MB) | Few large allocs, long-lived |
| Sumcheck | Small+Medium mix | Rapid alloc/dealloc cycles |
| WHIR/FRI | Medium (320KB tiles) | Parallel tiled access pattern |

When the rolling size-class distribution shifts beyond a threshold (KL divergence
> 0.5 from current phase profile), trigger a phase transition.

**Active detection (opt-in API):**

```rust
impl ProverAlloc {
    /// Hint that a proving phase is ending. All thread-local arenas
    /// bulk-reset their bump regions and return pooled buffers to the
    /// size-class free lists. O(1) per arena.
    pub fn phase_boundary();

    /// Begin a named phase for telemetry. Optional — passive detection
    /// works without this.
    pub fn begin_phase(name: &str);
}
```

Phase boundary action:
1. Each worker arena resets its bump pointer to the start of the bump region
2. Medium pool free lists are compacted (merge adjacent free blocks)
3. Large mmap regions from the previous phase are `munmap`'d or `madvise(DONTNEED)`'d
4. Pressure adaptor re-evaluates retention policy

### 4. Pressure adaptor

Solves the mimalloc 16GB-vs-64GB problem. Reads `/proc/meminfo` at startup and
periodically (every 1000 large allocs or every phase boundary):

```rust
enum RetentionPolicy {
    /// RSS < 50% of available: return pages eagerly via madvise(DONTNEED)
    Eager,
    /// RSS 50-80% of available: retain thread-local pages, return global
    Moderate,
    /// RSS > 80% of available: retain everything, use huge pages aggressively
    Aggressive,
}
```

Under `Eager` (64GB machine, 12GB RSS): arenas shrink at phase boundaries,
large mmap regions are immediately unmapped. No wasted cache lines from retained
pages.

Under `Aggressive` (16GB machine, 12GB RSS): arenas retain their pages across
phase boundaries (avoiding page fault storms on re-allocation), large regions
use `MAP_POPULATE` to fault in eagerly, huge pages are preferred.

### 5. Huge page integration

For allocations >2MB:

```rust
fn alloc_large(size: usize) -> *mut u8 {
    let ptr = mmap(null(), size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1, 0);

    // Opportunistic THP: hint the kernel, don't require it
    madvise(ptr, size, MADV_HUGEPAGE);

    // Under aggressive retention: pre-fault pages
    if PRESSURE.load() == Aggressive {
        madvise(ptr, size, MADV_WILLNEED);
    }

    ptr
}
```

This directly addresses the TLB pressure on large polynomial buffers. NTT twiddle
tables (persistent across proofs) and Merkle tree buffers (per-proof) both benefit.

## Implementation plan

### Phase 1: Drop-in foundation (2 weeks)

**Goal:** Match mimalloc performance under pressure, no regression with headroom.

1. Thread-local arena with bump allocator for small allocs
2. Size-class pools for medium allocs (static size classes, no phase awareness yet)
3. Direct mmap for large allocs with THP hints
4. Cross-thread dealloc via MPSC queue
5. Pressure adaptor reading `/proc/meminfo`

**Validation:** `eval_paired.sh` on both AWS c7a.2xlarge (16GB) and Hetzner AX42-U
(64GB) via cgroup. Must beat glibc on both. Target: -15% under pressure, neutral
with headroom.

Deliverable: `prover-alloc` Rust crate, `#[global_allocator]` compatible.

### Phase 2: Phase awareness (1 week)

**Goal:** Exploit proving phase structure for bulk deallocation.

1. Passive phase detection via size-class distribution monitoring
2. Phase boundary bulk reset (bump pointer reset, pool compaction)
3. Active `phase_boundary()` API for applications that want explicit control
4. Telemetry: phase transition log with timing and memory stats

**Validation:** Criterion + production benchmarks. Expect additional 3-5% from
reduced fragmentation across phase boundaries.

### Phase 3: Proving-specific optimizations (2 weeks)

**Goal:** Optimizations that only make sense for proving workloads.

1. **Polynomial buffer pool.** Recognize recurring power-of-two allocation
   patterns (same size allocated and freed repeatedly in a loop) and maintain
   a dedicated recycle pool. Targets the WHIR equality update pattern and
   sumcheck scratch buffers.
2. **NUMA-aware arena placement.** On multi-socket machines, bind each Rayon
   worker's arena to the local NUMA node. Uses `mbind()` on Linux.
3. **Prefetch integration.** For size-class pools, prefetch the next free-list
   entry during the current allocation. Hides the pointer-chasing latency of
   free-list traversal.
4. **Alignment guarantees.** All medium/large allocations aligned to cache line
   (64B) by default. Eliminates false sharing in parallel polynomial operations.

**Validation:** Full benchmark suite + `perf stat` comparison (page faults,
TLB misses, L2/L3 cache misses) against mimalloc and glibc.

### Phase 4: Hardening and portability (1 week)

1. macOS support (vm_allocate instead of mmap, no `/proc/meminfo` — use
   `sysctl` / `host_statistics`)
2. Stress testing under allocation fuzzing (random size distributions, random
   phase boundaries, cross-thread free storms)
3. Valgrind/ASan compatibility mode (disable custom mmap, fall through to
   system allocator)
4. Documentation and benchmark reproduction scripts

## Success criteria

| Metric | Target | Measurement |
|--------|--------|-------------|
| Criterion (16GB) | ≥ mimalloc (-33%) | `eval_paired.sh` on cgroup-limited Hetzner |
| Criterion (64GB) | ≥ glibc (no regression) | `eval_paired.sh` on native Hetzner |
| Production (16GB) | ≥ mimalloc (-24%) | `reproduce_prod.sh` on cgroup-limited Hetzner |
| Production (64GB) | ≥ glibc (no regression) | `reproduce_prod.sh` on native Hetzner |
| Cross-thread dealloc | < 50ns p99 | Microbenchmark |
| Phase boundary reset | < 1ms per worker | Microbenchmark |
| Binary size overhead | < 100KB | `size` comparison |

## Existing data we can leverage

From experiment 6:
- Allocation size distribution (12.94M allocs profiled, size classes known)
- Phase-by-phase allocation counts (custom GlobalAlloc phase counters)
- Contention sites identified (glibc arena locks under Rayon)
- Cache traffic analysis (DRAM bandwidth measurement via L2 tiling experiment)
- Per-site allocation counts (heap_runner atomic counters)
- Criterion and production baselines on both AWS and Hetzner

From mimalloc experiment (exp3/exp5):
- mimalloc -24% production / -33% Criterion on 16GB
- mimalloc +3.6% regression on 64GB
- jemalloc +74.8% regression (rules out jemalloc's approach)

## Why this hasn't been built

1. **Small market.** ZK proving teams are small; allocator work is infrastructure
   that doesn't directly ship features. Every team independently picks
   jemalloc/mimalloc and moves on.
2. **Hard to measure.** Allocator effects are confounded with hardware, OS, and
   workload. Our experiment framework (eval_paired.sh, cgroup isolation, phase
   instrumentation) is unusual — most teams don't have this.
3. **Phase awareness requires domain knowledge.** A general-purpose allocator
   team doesn't know that proving has phases. A proving team doesn't know how
   to build allocators. The intersection is narrow.
4. **"Good enough" bar.** mimalloc gives 25% on the common case (memory-pressured
   cloud VMs). Teams ship mimalloc and call it done. The 64GB regression is
   tolerated because dev machines have plenty of RAM.

## Risk assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Phase detection false positives | Medium | Conservative threshold + manual override API |
| Cross-thread dealloc overhead | Low | MPSC queues are well-studied; batch processing amortizes |
| Unsafe code bugs | High | Allocators are inherently unsafe. ASan, Miri (where possible), extensive fuzzing |
| Platform portability | Medium | Linux-first, macOS Phase 4. No Windows initially |
| Worse than mimalloc under pressure | Low | Pressure adaptor directly replicates mimalloc's retention strategy |

## Open questions

1. **Should the passive phase detector use allocation count windows or byte
   volume windows?** Count-based is simpler but byte-based captures the
   large-alloc phases better.
2. **MPSC queue implementation:** Use crossbeam-queue, roll our own, or adapt
   snmalloc's approach? Crossbeam adds a dependency; custom code adds risk.
3. **Should the allocator be proving-system-agnostic or leanMultisig-specific?**
   Starting leanMultisig-specific (we have the profiling data) and generalizing
   later is lower risk. But other proving systems (SP1, Stwo) have similar
   phase structures.
4. **Interaction with the OS page cache under memory pressure.** When RSS
   approaches physical RAM, the kernel starts reclaiming pages. Does our
   retention policy fight the kernel's, or complement it?
5. **Can we use `userfaultfd` for lazy arena initialization?** Instead of
   `mmap` + `MAP_POPULATE`, use `userfaultfd` to fault in pages on first
   access. Avoids wasting physical memory on arena pages that might not be
   touched this phase.
