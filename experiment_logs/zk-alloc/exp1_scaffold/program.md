# exp1_scaffold: make zk-alloc correct under real proving load

## Objective

Fix memory safety bugs in the zk-alloc scaffold so that leanMultisig's full
test suite passes with zk-alloc as `#[global_allocator]`. No performance
targets — only correctness.

## Writable scope

**Only files under `zk-alloc/`**. Do not modify leanMultisig source code.
leanMultisig integrates zk-alloc via a cargo feature flag on a dedicated
branch (`zk-alloc-integration` on myfork).

## Build and test commands

```bash
# Unit tests (zk-alloc crate only)
cd ~/zk-autoresearch/zk-alloc && cargo test

# Integration test (leanMultisig with zk-alloc)
cd ~/zk-autoresearch/leanMultisig && git checkout zk-alloc-integration
cargo test --release --features zk-alloc

# Full workspace test (56 tests, 3 end-to-end proofs)
cargo test --release --workspace --features zk-alloc
```

## Known bugs (fix in order)

### Bug 1: No pointer ownership tracking

When the bump arena fills (16MB), `alloc_small` falls back to `System`. But
`dealloc_small` is a no-op — so System-allocated memory is never freed. And
`dealloc_medium` puts pointers into the free list regardless of origin — a
System-allocated pointer in our free list = use-after-free when the pool
recycles it.

**Fix:** Track whether a pointer belongs to our arena (address-range check:
`ptr >= arena.base && ptr < arena.base + arena.capacity`). Fall through to
`System.dealloc()` for foreign pointers.

### Bug 2: Cross-thread deallocation

Rayon work-stealing means objects allocated on thread A may be freed on thread
B. Thread B's `dealloc_small` is a no-op (correct for bump) but
`dealloc_medium` puts the pointer into thread B's free list — wrong pool,
wrong thread. When thread B's pool recycles it, it hands out a pointer that
belongs to thread A's arena (which may have been reset).

**Fix:** Check pointer ownership on dealloc. If the pointer belongs to a
different thread's arena, either:
- (Simple) Fall through to System.dealloc() — accept the leak for now
- (Correct) Post to the owning thread's deferred-free MPSC queue

Start with the simple approach. Optimize in exp3.

### Bug 3: Arena growth

The 16MB arena is a fixed mmap region. When full, all allocations fall through
to System. Under leanMultisig (12-13GB peak RSS), the arena fills immediately
and zk-alloc becomes a thin wrapper around System with extra overhead.

**Fix:** Chain of arena slabs. When the current slab fills, mmap a new one
(double the size: 16MB, 32MB, 64MB, ...). Track all slabs for cleanup and
pointer ownership checking.

### Bug 4: Phase reset safety

`reset_arena()` resets the bump pointer to 0, making all bump-allocated memory
available for reuse. But callers may still hold references to that memory.
With Rayon parallelism, there's no safe point to call reset unless all threads
synchronize.

**Fix for now:** Remove automatic reset from `phase_boundary()`. Make it only
compact the medium pools and update the pressure policy. Bump memory stays
allocated until the thread exits. Phase-aware reuse is exp5 territory.

### Bug 5: pool_class edge cases

`pool_class(513)` computes `32 - leading_zeros(1024) - 10 = 32 - 22 - 10 = 0`,
which is correct. But `pool_class(2_097_152)` = `32 - 11 - 10 = 11`, which is
the last valid index. `pool_class(2_097_153)` = 12, which overflows the
`pools[12]` array (only 12 elements, indices 0-11).

**Fix:** Clamp to NUM_SIZE_CLASSES - 1, or route oversized "medium" allocs
to the large path.

## Iteration strategy

Each iteration fixes one bug or a closely related group. After each fix:
1. `cargo test` in zk-alloc (7 unit tests must pass)
2. Add new tests targeting the specific bug
3. Once all bugs fixed: `cargo test --release --workspace --features zk-alloc`
   on leanMultisig

Expected iteration sequence:
1. Pointer ownership tracking (address-range check on dealloc)
2. Arena slab chaining (growable arena)
3. Cross-thread dealloc (ownership check + System fallback)
4. Phase reset safety (remove bump reset, keep pool compaction)
5. pool_class edge cases + additional stress tests
6. leanMultisig integration test (all 56 tests)
7. End-to-end proof correctness (3 proof generation + verification tests)
8. Buffer: fix any issues found in steps 6-7

## Gate criteria

**PASS:** All 56 leanMultisig workspace tests pass with `--features zk-alloc`.
All 3 end-to-end proofs (test_xmss_signature, test_recursive_aggregation,
test_aggregation) produce correct results.

**No performance gate.** This experiment is correctness-only. Performance
measurement begins in exp2.

## What not to do

- Do not optimize for performance. Correct and slow beats fast and wrong.
- Do not add phase detection logic. That's exp5.
- Do not tune size-class boundaries. That's exp3.
- Do not read /proc/meminfo adaptively. Hardcode Moderate policy. That's exp4.
- Do not modify leanMultisig source code.
