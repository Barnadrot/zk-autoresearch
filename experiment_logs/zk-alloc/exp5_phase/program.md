# exp5_phase: phase-aware bulk deallocation

## Objective

Exploit the proving pipeline's phase structure for O(1) arena reset between
phases. This is the uniquely-ZK optimization — no general-purpose allocator
can do this because it requires domain knowledge about allocation lifetimes.

## Prerequisites

exp4_pressure PASSED: zk-alloc beats glibc under pressure, no regression with
headroom.

## Writable scope

**`leanMultisig/zk-alloc/`** for the allocator. **Exception:** minimal
`phase_boundary()` call sites may be added to leanMultisig proving pipeline
(requires user approval per call site).

## Commit point

**origin/main** initially, then validate on **post-exp6** to measure combined
effect.

## Gate criteria

**KEEP:** >= 1% additional improvement over exp4 result, p < 0.01.

**DISCARD:** < 1% improvement, or correctness regression.

## Proving phases in leanMultisig

The proving pipeline has these phases (identified from tracing + heaptrack):

1. **Witness generation** — execute VM, build trace columns. Many small allocs
   (field elements), freed at end of phase.
2. **Trace commitment** — Merkle tree construction over trace. Large allocs
   (polynomial buffers), freed after commitment.
3. **Logup/sumcheck** — constraint evaluation. Medium allocs (scratch buffers),
   rapid alloc/dealloc cycles within phase.
4. **WHIR/FRI** — polynomial commitment queries. Large allocs (equality
   polynomial buffers), systematic access patterns.
5. **Proof serialization** — small allocs, postcard encoding. Negligible.

## Iteration strategy

1. **Identify phase boundaries.** Add tracing instrumentation to leanMultisig
   (temporary, not committed) to measure exact points where allocation patterns
   shift. Map these to code locations.

2. **Manual phase_boundary() placement.** Add `zk_alloc::phase_boundary()` calls
   at identified boundaries. Measure impact of each placement individually.
   Keep only those that improve performance.

3. **Arena reset strategy.** At phase boundary:
   - Reset bump pointer (reclaim all small alloc space)
   - Compact medium pool free lists
   - Return large mmap regions if under Eager retention policy
   Must handle live cross-phase references safely — some objects survive
   phase boundaries (e.g., committed polynomials used in later phases).

4. **Per-phase arena sizing.** Different phases have different allocation
   volumes. Size the arena slab chain per phase based on profiling data:
   - Witness gen: many small, ~500MB total
   - Trace commit: few large, ~2GB total
   - Sumcheck: medium churn, ~200MB total
   - WHIR: medium + large, ~1GB total

5. **Passive phase detection (stretch goal).** Monitor size-class distribution
   in a rolling window. When the distribution shifts (KL divergence > threshold),
   trigger phase transition automatically. No manual API needed.

Expected iterations: 5–8.

## Safety concern

Phase reset is the most dangerous operation in the allocator. If any object
survives a phase boundary and the bump region is reused, it's a silent
use-after-free. Mitigations:

- **Epoch tracking.** Each allocation records the current phase epoch. On
  access (debug mode only), assert the epoch hasn't advanced.
- **Conservative reset.** Only reset if the arena's reference count (debug
  mode) drops to zero.
- **Large allocs exempt.** Objects >2MB are mmap'd individually and never
  part of the bump region — they survive phase boundaries safely.

## What not to do

- Do not redesign the core arena (exp1-3 already shipped that).
- Do not change pressure policy (exp4 already shipped that).
- Do not generalize to other proving systems yet (exp6).
