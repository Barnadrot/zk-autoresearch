# Jolt zkVM — zk-alloc benchmark results

**Date:** 2026-04-26
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 64GB DDR5)
**Jolt version:** 0.1.0 (c71ae8f55 2026-04-24)
**Default allocator:** glibc (no jemalloc/mimalloc in Jolt)
**All proofs cryptographically verified (prover + verifier in each run).**

---

## Methodology

zk-alloc integrated via `#[global_allocator]` in the jolt-core benchmark binary.
`phase_boundary()` called before witness generation + proving, `deactivate_arena()` after proving,
verification runs on system allocator. Overflow tracking enabled.

---

## SHA3-Chain (scale 18, ~2^18 trace)

| Allocator | Run 1 | Run 2 | Run 3 | Mean | vs glibc |
|-----------|-------|-------|-------|------|----------|
| glibc     | 2.70s | -     | -     | 2.70s | baseline |
| zk-alloc  | 2.66s | -     | -     | 2.66s | -1.5%   |

Small scale — noise-dominated, not meaningful.

## SHA3-Chain (scale 20, ~2^20 trace, ~750MB RSS)

| Allocator | Run 1 | Run 2 | Run 3 | Mean | vs glibc |
|-----------|-------|-------|-------|------|----------|
| glibc     | 6.41s | 6.49s | 6.45s | 6.45s | baseline |
| zk-alloc  | 6.55s | 6.54s | 6.52s | 6.54s | **+1.4%** |

Peak RSS: glibc 750MB, zk-alloc 771MB. No overflow.

## SHA3-Chain (scale 22, ~2^22 trace)

| Allocator | Run 1  | Run 2  | Run 3  | Mean   | vs glibc |
|-----------|--------|--------|--------|--------|----------|
| glibc     | 17.70s | 17.74s | 17.80s | 17.75s | baseline |
| zk-alloc  | 18.25s | 18.39s | 18.29s | 18.31s | **+3.2%** |

No overflow.

## SHA3-Chain (scale 24, ~2^24 trace, ~9.7GB RSS)

| Allocator | Run 1  | Peak RSS |
|-----------|--------|----------|
| glibc     | 59.18s | 9.73 GB  |
| zk-alloc  | 61.56s | 9.75 GB  |

Delta: **+4.0%** slower with zk-alloc. No overflow.

## Fibonacci (scale 22, ~2^22 trace)

| Allocator | Run 1  | Run 2  | Run 3  | Mean   | vs glibc |
|-----------|--------|--------|--------|--------|----------|
| glibc     | 16.92s | 16.93s | 17.01s | 16.95s | baseline |
| zk-alloc  | 17.46s | 17.55s | 17.46s | 17.49s | **+3.2%** |

No overflow.

---

## Summary

| Workload | Scale | zk-alloc vs glibc |
|----------|-------|--------------------|
| sha3-chain | 20 | +1.4% (slower) |
| sha3-chain | 22 | +3.2% (slower) |
| sha3-chain | 24 | +4.0% (slower) |
| fibonacci  | 22 | +3.2% (slower) |

**zk-alloc does not help on Jolt.** It is consistently 1-4% slower across all scales and workloads.
The regression grows with scale.

---

## Analysis: Why Jolt Differs from Plonky3

**Plonky3** (zk-alloc wins -12% to -17%):
- Hot path: trace generation → LDE (large contiguous vector allocations)
- Pattern: allocate large buffers, fill, commit, discard
- glibc overhead: mmap/munmap for large allocations, TLB invalidation, page faults
- Arena advantage: sequential bump through pre-faulted pages, zero free overhead

**Jolt** (zk-alloc loses +1% to +4%):
- Hot path: sumcheck rounds with many small polynomial operations
- Pattern: allocate small-medium buffers, use briefly, free, reallocate similar sizes
- glibc advantage: tcache (thread-local free-list) returns recently-freed same-size buffers instantly — better cache locality than advancing through cold arena pages
- Arena disadvantage: never reuses freed space, bump pointer advances through pages that may not be hot in cache

**Key insight:** The bump-only arena wins when the workload is allocation-heavy with large
buffers and batch-discard semantics. It loses when the workload is compute-heavy with
frequent small alloc/free cycles where glibc's tcache provides near-zero-overhead reuse
with hot cache lines.

Jolt's Dory commitment scheme uses Arkworks BN254 elliptic curve operations (MSM, pairings)
which are compute-dominated. The sumcheck pipeline allocates many small temporary vectors
that glibc efficiently recycles via tcache.
