# exp4_pressure: solve the mimalloc 16GB/64GB tradeoff

## Objective

Make zk-alloc work well under BOTH memory pressure (16GB) and headroom (64GB).
This is the problem no existing allocator solves — mimalloc gives -24% at 16GB
but regresses +3.6% at 64GB.

## Prerequisites

exp3_contention PASSED: zk-alloc >= 5% faster than glibc on 16GB.

## Writable scope

**Only files under `leanMultisig/zk-alloc/`**.

## Commit point

**origin/main** (pre-exp6).

## Hardware requirement

**Hetzner AX42-U bare metal** (64GB DDR5). Use cgroups to simulate 16GB:

```bash
# 16GB memory-limited environment
sudo cgcreate -g memory:bench16g
echo 16G | sudo tee /sys/fs/cgroup/bench16g/memory.max
sudo cgexec -g memory:bench16g bash eval_paired.sh

# 64GB native (no cgroup)
bash eval_paired.sh
```

Same hardware, same CPU, same OS — only RAM available changes.

## Gate criteria

**PASS:** Both conditions must be met simultaneously:
- 16GB (cgroup): >= 10% improvement vs glibc, p < 0.01
- 64GB (native): within ±1% of glibc (no regression), p > 0.05

**FAIL:** Regression on either condition.

## Target performance matrix

| Condition | glibc | mimalloc | zk-alloc target |
|-----------|-------|----------|-----------------|
| 16GB (cgroup) | baseline | -24% | -15% |
| 64GB (native) | baseline | +3.6% | ±0% |

## Iteration strategy

The pressure adaptor (`src/pressure.rs`) reads `/proc/meminfo` and adjusts
retention policy. Iterations tune the policy thresholds and mechanisms:

1. **Retention policy thresholds.** Current: Eager (<50%), Moderate (50-80%),
   Aggressive (>80%). These may not be right. Profile actual RSS/MemAvailable
   ratio during proving on both 16GB and 64GB.

2. **Page return strategy under Eager.** When RSS is low relative to available
   RAM, return pages aggressively:
   - `madvise(MADV_DONTNEED)` — lazy, kernel reclaims on demand
   - `munmap` + re-mmap — immediate, but syscall overhead
   - `madvise(MADV_FREE)` — lazy, kernel reclaims under pressure only
   Profile which minimizes cache waste without syscall overhead.

3. **Page retention under Aggressive.** When RSS is high:
   - Keep arena slabs allocated across phase boundaries
   - Use `madvise(MADV_WILLNEED)` to pre-fault pages
   - Prefer `MAP_POPULATE` for new large allocs
   This is what mimalloc does well — replicate it.

4. **Poll frequency.** How often to re-read `/proc/meminfo`?
   - Every phase boundary (cheapest, but may miss pressure spikes)
   - Every N large allocs (amortized)
   - Never (detect at startup, cache the result)
   Start with startup-only detection (simplest). If the workload's RSS changes
   significantly during a proof, add periodic polling.

5. **Huge page policy.** THP via `madvise(MADV_HUGEPAGE)` may help under
   pressure (fewer TLB misses for large buffers) but hurt with headroom
   (huge page allocation can stall). Make it pressure-dependent.

Expected iterations: 5–8.

## What not to do

- Do not add phase detection (exp5).
- Do not change the core arena/pool design (that's exp3's job).
- Do not optimize for a single memory condition. Every change must be tested
  on BOTH 16GB and 64GB.
- Do not modify leanMultisig source code.
