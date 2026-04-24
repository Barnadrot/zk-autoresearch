# zk-alloc: multi-experiment iteration plan

## Overview

Build the first memory allocator designed for ZK proving workloads, validated
against leanMultisig. Each experiment is self-contained with its own program.md,
iters.tsv, and gate criteria. Later experiments depend on earlier ones shipping.

After initial validation on leanMultisig, extend to Jolt, Plonky3, and SP1 to
confirm the design generalizes across proving systems.

## Writable scope

All experiments: **only `zk-alloc/`** (the allocator crate). leanMultisig code
is read-only — the allocator must work as a drop-in `#[global_allocator]` with
zero application changes.

## Baseline data

From leanMultisig experiment 6 (17 iterations):

| Allocator | Criterion (AWS 16GB) | Production (AWS 16GB) | Production (Hetzner 64GB) |
|-----------|---------------------|----------------------|--------------------------|
| glibc (origin/main) | baseline | 50.89s | pending |
| glibc (post-exp6) | -22% | 45.64s | pending |
| mimalloc (origin/main) | -33% | -24% | +3.6% regression |

Profiling data:
- 12.94M allocs per proof (origin/main), 1.77M (post-exp6)
- 70% of allocs ≤128B, 20% 128B–64KB, 9% 64KB–4MB, 1% >4MB
- Contention mechanism: Rayon threads competing for glibc arena locks
- Cache traffic: 274 STIR queries × 84MB = ~67GB DRAM (origin/main)

## Experiment sequence

### exp1_scaffold — Make it correct

**Goal:** Fix the current scaffold's memory safety bugs. Get leanMultisig's full
test suite passing with zk-alloc as `#[global_allocator]`.

**Why first:** Nothing else matters if the allocator corrupts memory. One
use-after-free invalidates all benchmark results.

**Known bugs to fix:**
1. Pointer ownership tracking (which allocator owns each pointer)
2. Cross-thread dealloc (Rayon work-stealing)
3. Arena growth (chain of slabs instead of 16MB cap + System fallback)
4. Phase reset safety (live references across phase boundaries)
5. pool_class edge cases

**Gate:** `cargo test --release` passes with zk-alloc active on leanMultisig.
All 56 workspace tests + 3 end-to-end proofs must produce correct results.

**Expected iterations:** 5–8

---

### exp2_baseline — Match glibc

**Goal:** No regression vs glibc on leanMultisig (origin/main). The allocator
works correctly under real proving load and doesn't slow anything down.

**Gate:** eval_paired.sh delta within ±1% of glibc (p > 0.05 = no significant
difference). Production via reproduce_prod.sh within ±2%.

**Iteration strategy:** Profile with heaptrack to find where zk-alloc is slower
than glibc, fix those paths. Likely: thread-local arena overhead on first
access, mmap syscall overhead for large allocs, free-list traversal in pools.

**Expected iterations:** 3–5

---

### exp3_contention — Beat glibc on contention

**Goal:** Capture the contention improvement that mimalloc gets (-24% on 16GB)
through thread-local arenas, without mimalloc's page retention overhead.

**Target:** -10% or better vs glibc on origin/main (16GB). This is the core
value proposition — thread-local arenas that eliminate the same arena lock
contention our exp6 KEEPs targeted at the source level.

**Gate:** >= 5% improvement, p < 0.01 on eval_paired.sh.

**Iteration strategy:** 
- Tune arena size per worker
- Optimize bump allocator hot path (minimize TLS lookup overhead)
- Size-class pool tuning for polynomial buffer sizes
- Cross-thread dealloc batching

**Expected iterations:** 5–10

---

### exp4_pressure — Solve the mimalloc tradeoff

**Goal:** Adaptive retention policy that works under both 16GB pressure and
64GB headroom. This is what no existing allocator does.

**Target:** -15% vs glibc at 16GB, neutral (±1%) at 64GB.

**Gate:** Must pass on BOTH memory conditions. Regression on either = discard.

**Requires:** Hetzner bare metal with cgroup-based memory limiting.

**Iteration strategy:**
- Pressure detection latency (how often to poll /proc/meminfo)
- Retention policy thresholds
- Page return strategy (madvise DONTNEED vs munmap)
- Huge page integration tuning

**Expected iterations:** 5–8

---

### exp5_phase — Phase-aware bulk deallocation

**Goal:** Exploit proving phase structure for O(1) arena reset between phases.

**Target:** Additional 3-5% on top of exp3/exp4.

**Gate:** >= 1% improvement, p < 0.01.

**Depends on:** Understanding where phase boundaries actually occur in
leanMultisig's proving pipeline. May require adding `phase_boundary()` calls
to leanMultisig (exception to read-only rule — minimal, opt-in).

**Iteration strategy:**
- Identify phase boundaries in leanMultisig via tracing
- Measure phase-local allocation lifetime distributions
- Tune bump region sizing per phase
- Test passive phase detection vs manual API

**Expected iterations:** 5–8

---

### exp6_generalize — Validate across proving systems

**Goal:** Confirm zk-alloc works on Jolt, Plonky3, and SP1.

**Target:** No regression on any system. Improvement on at least 2 of 3.

**This is where it becomes a real product, not a leanMultisig optimization.**

---

## Integration method

leanMultisig integration via cargo feature flag on myfork:

```toml
# leanMultisig/Cargo.toml (workspace root)
[workspace.dependencies]
zk-alloc = { path = "../zk-alloc", optional = true }

# leanMultisig/crates/lean_prover/Cargo.toml (or whichever crate has the binary)
[features]
zk-alloc = ["dep:zk-alloc"]

[dependencies]
zk-alloc = { workspace = true, optional = true }
```

```rust
// Binary entry point
#[cfg(feature = "zk-alloc")]
#[global_allocator]
static GLOBAL: zk_alloc::ZkAllocator = zk_alloc::ZkAllocator;
```

Benchmark switching:
```bash
# glibc (default)
cargo bench --bench xmss_leaf

# zk-alloc
cargo bench --bench xmss_leaf --features zk-alloc

# mimalloc (existing, for comparison)
cargo bench --bench xmss_leaf --features mimalloc
```

## Validation hardware

| | AWS c7a.2xlarge | Hetzner AX42-U |
|---|---|---|
| CPU | AMD EPYC Genoa (Zen 4) | AMD Ryzen 7 PRO 8700GE (Zen 4) |
| Cores | 8 vCPU (shared tenancy) | 8C/16T (dedicated) |
| RAM | 16 GB | 64 GB DDR5 |
| Role | Memory-pressure condition | Headroom condition + cgroup 16GB |

All experiments use Hetzner bare metal as primary. AWS for cross-validation
where noted. Cgroup methodology for memory pressure simulation:

```bash
sudo cgcreate -g memory:bench16g
echo 16G | sudo tee /sys/fs/cgroup/bench16g/memory.max
sudo cgexec -g memory:bench16g bash eval_paired.sh
```

## Timeline estimate

| Experiment | Duration | Cumulative |
|-----------|----------|------------|
| exp1_scaffold | 1 day | 1 day |
| exp2_baseline | 1 day | 2 days |
| exp3_contention | 2 days | 4 days |
| exp4_pressure | 1 day | 5 days |
| exp5_phase | 1 day | 6 days |
| exp6_generalize | 2 days | 8 days |

With autoresearch agent running overnight, exp1–exp4 could compress to a weekend.
