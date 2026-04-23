# leanMultisig — Allocator Follow-up: Alternative Allocators

## Context

Source-code allocation reduction (experiment 6) captured -7.1% e2e from 3 keeps.
Remaining 724K runtime allocs are in glibc's tcache sweet spot — source fixes won't
help further. But mimalloc showed -24% under memory pressure (16GB, ~80% utilization)
by making *every* allocation faster, including the untouchable 724K.

mimalloc regresses +3.6% without memory pressure (64GB, ~20% utilization). The variable
is **RAM headroom, not hardware type** — one machine was AWS KVM (16GB), the other
Hetzner bare metal (64GB), but the difference is explained by memory pressure (htop
shows 12-13GB peak RSS during fancy-aggregation).

The question: is there an allocator configuration that helps under pressure without
hurting with headroom?

## Test environment: Hetzner bare metal only

AWS shared tenancy is unsuitable for allocator benchmarking. Hypervisor effects
(vCPU descheduling, nested page tables, noisy neighbors) are confounded with
allocator behavior — results are uninterpretable for allocator choice.

All testing must run on **Hetzner AX42-U bare metal** (64GB, dedicated), using
cgroups to simulate the 16GB memory-pressure condition:

```bash
# Create a 16GB memory-limited cgroup on the 64GB Hetzner box
sudo cgcreate -g memory:bench16g
echo 16G | sudo tee /sys/fs/cgroup/bench16g/memory.max

# Run benchmark under simulated pressure
sudo cgexec -g memory:bench16g bash eval_paired.sh

# Run benchmark without limit (native 64GB)
bash eval_paired.sh
```

Same hardware, same CPU, same OS — only RAM available changes. This is the only
setup that isolates allocator behavior from environment noise.

Exception: if the product specifically targets AWS cloud deployment, then AWS
results are the deployment-relevant ones. But for choosing an allocator that's
universally correct, bare metal is the only valid testbed.

## Candidates (prioritized)

### Tier 1: highest ROI, test first

| # | Allocator | Why | Expected outcome |
|---|-----------|-----|------------------|
| 1 | **mimalloc tuned** | Conservative purge/commit settings disable aggressive page retention — the specific thing that causes the 64GB regression — while preserving thread-local allocation speed | -15% under pressure, neutral with headroom |
| 2 | **Mesh** | Virtual memory aliasing compacts physical pages without moving objects. Drop-in `LD_PRELOAD`. Directly tests whether the glibc regression is fragmentation-driven | If fragmentation is the root cause, Mesh + glibc could match mimalloc under pressure without the headroom cost |
| 3 | **tcmalloc** | Adaptive per-thread cache sizing. Google-scale battle-tested. Adjusts cache aggressiveness based on actual usage, not fixed reservation | Moderate improvement across both conditions |

### Tier 2: worth trying if Tier 1 fails

| # | Allocator | Why | Risk |
|---|-----------|-----|------|
| 4 | **snmalloc** | Message-passing between threads instead of locks or thread-local segments. Adaptive by design | Less battle-tested in Rust ecosystem |
| 5 | **rpmalloc** | Thread-local + global cache, smaller footprint than mimalloc | Likely same tradeoff as mimalloc |

### Skip

| Allocator | Why skip |
|-----------|---------|
| **Hoard** | Bounded-blowup guarantee is for worst-case, not average-case perf |
| **scudo** | Security-hardened — optimizes for safety, not throughput |
| **jemalloc** | Already tested in exp6 iter (exp3/19): +74.8% regression |
| **bumpalo** | `!Sync` — cannot share across Rayon threads |

## Candidate 1 deep dive: mimalloc tuning

mimalloc's headroom regression is likely from aggressive page retention — thread-local
segments hold freed pages instead of returning them to the OS. With 64GB this wastes
cache lines; with 16GB the retention is beneficial (avoids page faults on re-allocation).

Tuning knobs to test:

```rust
use mimalloc::MiMalloc;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

fn configure_mimalloc() {
    // Return pages to OS immediately instead of retaining
    mimalloc::MiMalloc::set_option(mimalloc::Option::PurgeDelay, 0);

    // Don't pre-commit segment pages — commit on first touch only
    mimalloc::MiMalloc::set_option(mimalloc::Option::EagerCommit, 0);

    // Don't pre-commit arena pages
    mimalloc::MiMalloc::set_option(mimalloc::Option::ArenaEagerCommit, 0);
}
```

Test matrix: 3 configurations × 2 memory conditions = 6 runs.
- mimalloc default (baseline: -24% / +3.6%)
- mimalloc conservative (purge_delay=0, eager_commit=0)
- mimalloc aggressive (default but with arena_eager_commit=0 only)

## Candidate 2 deep dive: Mesh allocator

Mesh uses virtual memory aliasing to compact physical memory layout without moving
objects or changing virtual addresses. It directly attacks fragmentation — if glibc's
regression under pressure is caused by live objects scattered across many physical
pages, Mesh would compact them.

```bash
# Build Mesh from source (no Rust crate, use LD_PRELOAD)
git clone https://github.com/plasma-umass/Mesh.git
cd Mesh && mkdir build && cd build && cmake .. && make

# Run with Mesh as allocator (no code changes needed)
LD_PRELOAD=/path/to/libmesh.so ./target/release/bench_binary
```

This is the cleanest test of the fragmentation hypothesis. If Mesh + glibc matches
mimalloc under pressure, fragmentation was the bottleneck. If not, the benefit is
from thread-local allocation speed, not layout.

## Binius precedent and arena/bump patterns

Binius (Irreducible's ZK proof system) tried bumpalo and removed it (PR #718):
- bumpalo is `!Sync` — can't share across Rayon threads
- Their replacement: Mutex-wrapped BumpAllocator — serializes threads, same contention

The *idea* behind bump allocation is strong for ZK proving:
- O(1) allocation (increment a pointer, no free-list traversal)
- Zero fragmentation by design (linear layout)
- No per-alloc metadata overhead
- Phase-aligned lifetime: proving has clear phases (witness → commit → logup →
  sumcheck → WHIR), each allocates heavily then frees everything

The viable version for this codebase would be **thread-local bump arenas per Rayon
worker, reset between proving phases**. This is essentially what mimalloc does at
the segment level, but tuned to the proving pipeline's phase structure.

This is NOT a drop-in allocator change — it requires modifying allocation call sites
to use the arena. Only pursue if the drop-in candidates (Tier 1) all fail.

## Can agents build a workload-specific allocator?

A general-purpose allocator: no. Memory allocators are among the most subtle systems
code (thread safety, alignment, metadata layout, page management — decades of research).

A **workload-specific allocation wrapper**: yes. We have profiling data (heaptrack +
custom `GlobalAlloc` counters) showing the exact
allocation size distribution, lifetimes, call sites, and thread affinity. An agent could:

1. Analyze the allocation profile (724K remaining allocs, dominated by medium-sized
   Vecs in Rayon threads, phased lifetime pattern)
2. Generate a thin `GlobalAlloc` adapter that selects strategy at runtime:
   ```rust
   struct AdaptiveAlloc;

   impl AdaptiveAlloc {
       fn under_pressure() -> bool {
           // Check /proc/meminfo at startup, cache the result
           AVAILABLE_RAM_GB.load(Ordering::Relaxed) < 32
       }
   }

   unsafe impl GlobalAlloc for AdaptiveAlloc {
       unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
           if Self::under_pressure() {
               MIMALLOC.alloc(layout)
           } else {
               System.alloc(layout)
           }
       }
       // ...
   }
   ```
3. Or more ambitiously: a phase-aware arena wrapper that pre-allocates per-phase
   buffers and uses bump allocation within each phase, falling back to the system
   allocator for cross-phase allocations.

Option 2 (runtime selection) is trivial to implement and directly addresses the
observed problem. Option 3 (phase-aware arena) is a full experiment of its own.

## Sustainable methodology: periodic agent-driven sweeps

The zk-autoresearch experiment framework (heaptrack/custom-alloc profiling → agent-driven iteration
loop → eval_paired.sh gate → iters.tsv audit log) is the reusable CI-like tool.

Running an allocation experiment every ~3 months catches contention sites that
accumulate from development. This is better suited than per-commit CI for this
problem because:
- Allocation contention is emergent (interaction of many call sites under Rayon)
- Requires deep analysis, not threshold checking
- Expensive to run (~5 min benchmarks, ~16 iterations)
- Agent explores creatively — different approach each iteration

Combined with the right allocator choice, periodic source-code sweeps could
asymptotically approach optimal allocation behavior without the hardware-dependent
tradeoffs of a single allocator swap.

## Validation requirement

### Confounded variables in existing data

The mimalloc result (-24% AWS / +3.6% Hetzner) was measured across machines that
differ in at least 5 variables, not just RAM:

| Variable | AWS c7a.2xlarge | Hetzner AX42-U |
|---|---|---|
| RAM | 16GB | 64GB |
| Tenancy | Shared (KVM) | Dedicated bare metal |
| CPU | EPYC Genoa (server) | Ryzen 7 PRO 8700GE (desktop) |
| Storage | EBS gp3 (network) | 2x NVMe RAID 1 (local) |
| Hypervisor | KVM + nested page tables | None |

We cannot confidently attribute the delta to RAM alone. Hypervisor-specific
effects that could inflate mimalloc's advantage on AWS:

- **vCPU descheduling amplifies lock contention.** If KVM deschedules a vCPU
  holding a glibc arena lock, other threads wait orders of magnitude longer
  than on bare metal. This makes glibc look worse and mimalloc look better.
- **Nested page tables (EPT).** TLB misses under KVM walk both guest and host
  page tables. mimalloc's page retention avoids page faults that are more
  expensive under EPT. This advantage would be hypervisor-specific.
- **Noisy neighbors.** Shared tenancy means other VMs compete for LLC and
  memory bandwidth. mimalloc's compact thread-local layout may be more
  resilient to LLC eviction from neighbors.

### Required: isolate RAM via cgroup on one machine

The cgroup approach is **scientifically necessary**, not just convenient.
Testing `cgroup memory.max=16G` on 64GB Hetzner bare metal isolates the RAM
variable from tenancy/CPU/hypervisor:

- If mimalloc gives -20% under cgroup-limited 16GB on Hetzner → RAM pressure
  is the dominant variable, hypervisor effects are secondary.
- If mimalloc gives ~0% or regresses under cgroup-limited 16GB on Hetzner →
  the AWS -24% was hypervisor-amplified, and the RAM hypothesis is wrong.

This test MUST be run before drawing conclusions about any allocator.

### glibc is a candidate, not the baseline

We have no evidence that glibc is optimal on 64GB. It is the unoptimized
default. The validation should measure **absolute performance of each
allocator under each memory condition**, not just delta-vs-glibc:

```
                    16GB (cgroup)      64GB (native)
glibc               candidate          candidate
mimalloc default     candidate          candidate
mimalloc tuned       candidate          candidate
tcmalloc             candidate          candidate
Mesh                 candidate          candidate
```

An allocator wins if it is best (or within noise of best) under BOTH conditions.
There may not be a single winner — in which case the runtime-adaptive wrapper
becomes the answer.

## Estimated effort

~4 hours total:
- Research + setup: 30 min
- Tier 1 testing: 3 candidates × 2 memory conditions × 15 min = 90 min
- mimalloc tuning matrix: 3 configs × 2 conditions × 15 min = 90 min
- Analysis + writeup: 30 min

If Tier 1 produces a winner, skip Tier 2. If not, add ~60 min for Tier 2 candidates.

## Expected outcomes

**Best case:** mimalloc with conservative purge settings gives -15% under pressure
and neutral with headroom. Combined with source fixes: -20%+ universally portable.

**Good case:** Mesh confirms the fragmentation hypothesis and provides a drop-in
fix that works across memory conditions. Informs future allocator choices.

**Worst case:** All thread-local designs regress with headroom. The tradeoff is
fundamental. Source-code reduction (-7.1%) remains the only universal solution, and
the runtime-adaptive allocator wrapper becomes the pragmatic answer.
