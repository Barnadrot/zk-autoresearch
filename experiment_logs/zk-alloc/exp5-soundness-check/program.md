# zk-alloc — Experiment 5: Soundness Check

## Role
You are a systems programmer investigating memory safety in zk-alloc, a bump+reset
arena allocator for ZK proving workloads. You understand GlobalAlloc, thread-local
storage, rayon's work-stealing internals, and crossbeam-deque. You write reproducing
test cases and reason about allocation lifetimes across concurrent threads.

**Hardware:** AMD Ryzen 7 PRO 8700GE (Zen 4), 8 cores / 16 threads, 64GB RAM.

## Repos Under Test

| Repo | Path | Branch | Role |
|------|------|--------|------|
| zk-alloc (standalone) | `~/zk-autoresearch/zk-alloc` | `main` | The allocator crate. Changes land here. |
| Plonky3 | `~/zk-autoresearch/plonky3` | `feat/zk-alloc` | Multi-workload stress target (Poseidon1/BB, Poseidon2/BB, Poseidon2/KB) |
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `main` (fc1a9903) | Single large workload (XMSS 1400sigs, WHIR commitment) |

## The Known Bug (jumpoff point)

**Commit:** `leanEthereum/leanMultisig@f5e2299`

Rayon's global `crossbeam_deque::Injector` is a linked list of heap-allocated blocks
(64 slots, `BLOCK_CAP=63`). When `rayon::join` is called from a non-worker thread, it
pushes a `JobRef` into one of these blocks via the injector.

Under zk-alloc: if the arena is active during that push, the block is allocated inside
the arena slab. On the next `begin_phase()`, that slab is recycled. Rayon's injector
still holds the pointer → next job push writes into recycled memory → silent corruption.

**Trigger conditions (all must hold):**
1. `rayon::join` called from a non-worker thread (goes through injector, not per-worker deque)
2. The injector block was allocated during an active arena phase
3. That block still has unconsumed slots at next `begin_phase()`
4. Application allocates over the recycled memory before rayon writes to it

**Emile's fix:** Flood 256 no-op `rayon::join(|| {}, || {})` at `end_phase()` to force
workers to consume all old blocks, causing crossbeam to dealloc them. Fresh tail block
lands in system allocator (arena is inactive during flush).

**Problems with current fix:**
- Magic constant 256 tied to crossbeam's `BLOCK_CAP=63` (could break on version bump)
- 256 rayon joins per phase boundary has real overhead (wakes all workers, sync barrier)
- Depends on crossbeam deallocating blocks when fully consumed (implementation detail)

## Goals

1. **Reproduce the bug** under both Plonky3 and leanMultisig workloads with a reliable
   test harness (not just "rare edge case")
2. **Find additional bugs** of the same class — any allocation that outlives the arena
   phase it was allocated in. Candidates:
   - Other rayon internals (per-worker deques, Registry, ThreadBuilder)
   - Thread-local caches in other dependencies (hashbrown, smallvec, etc.)
   - Tracing/logging infrastructure allocations
   - crossbeam-channel or crossbeam-epoch (if used transitively)
3. **Design a better fix** that doesn't depend on crossbeam internals or magic constants

## Investigation Plan

### Phase 1: Reproduce and Characterize

- Build the MRE from Emile's commit as a standalone test
- Run under ASan (`-Zsanitizer=address`) and MSan (`-Zsanitizer=memory`) if possible
- Instrument `alloc`/`dealloc` in zk-alloc to log allocations that:
  - Originate from non-application threads (rayon worker ID tracking)
  - Are smaller than typical ZK allocations (crossbeam blocks are ~512-1024 bytes)
  - Survive past `end_phase()` (never freed before next `begin_phase`)
- Profile allocation patterns under Plonky3 workloads with phase cycling

### Phase 2: Systematic Audit

- Map all transitive dependencies that allocate from the global allocator:
  ```
  cargo tree -p p3-zk-alloc --edges=normal | grep -v "proc-macro"
  ```
- For each dep that uses internal caching/pooling, verify allocations don't outlive phases:
  - `rayon-core`: Injector blocks, Registry, scope stacks
  - `crossbeam-deque`: Block allocations, garbage collection
  - `crossbeam-epoch`: Epoch-based reclamation (deferred dealloc)
  - `hashbrown`: Raw table allocations (if used in hot path during phase)
- Add canary allocations at phase boundaries (known patterns that detect corruption)

### Phase 3: Better Fix Design

Alternatives to explore (from cheapest to most invasive):

1. **Allocation-size routing** — crossbeam blocks have characteristic size
   (~512 bytes for 64×8-byte slots). Route allocations matching that pattern
   to system allocator during active phase. Risk: false positives.

2. **Scope-aware activation** — only activate arena inside `rayon::scope()` bodies.
   The injector is only used by non-worker threads. If the arena is only active on
   worker threads, injector blocks always go to system allocator. Needs API change.

3. **Thread-ID routing** — detect allocations from rayon's main/external threads
   (where `rayon::current_thread_index()` returns None) and route to system.
   Problem: can't call rayon from inside GlobalAlloc.

4. **Explicit drain (current fix, improved)** — instead of 256 blind joins, query
   crossbeam's actual pending block count and drain exactly that many. May not be
   possible without forking crossbeam-deque.

5. **Arena-aware crossbeam fork** — allocate injector blocks from a separate allocator
   that bypasses the arena. Most correct, most invasive.

## Test Workloads

### Plonky3 (multi-workload, varied patterns)
```bash
cd ~/zk-autoresearch/plonky3

# Poseidon1 BabyBear (multiple phase cycles)
RUSTFLAGS="-C target-cpu=native" cargo run --release --features "zk-alloc,parallel" \
  --example prove_poseidon1_baby_bear_keccak

# Poseidon2 KoalaBear
RUSTFLAGS="-C target-cpu=native" cargo run --release --features "zk-alloc,parallel" \
  --example prove_poseidon2_koala_bear_keccak
```

### leanMultisig (single large workload, deep rayon nesting)
```bash
cd ~/zk-autoresearch/leanMultisig-bench
RUSTFLAGS="-C target-cpu=native" cargo run --release --bin prove_loop
```

### Standalone stress test (rapid phase cycling)
```bash
cd ~/zk-autoresearch/zk-alloc
RUSTFLAGS="-C target-cpu=native" cargo test --release test_rayon_phase_stress
```

## zk-alloc API Surface

```rust
pub fn begin_phase()        // Arena ON; bumps generation, slabs reset lazily
pub fn end_phase()          // Arena OFF; new allocs go to System
pub fn overflow_stats()     // (count, bytes) that fell through to System
pub fn reset_overflow_stats()
pub fn slab_size()          // Per-thread slab size in bytes
```

Key internals:
- `ARENA_ACTIVE: AtomicBool` — master switch
- `GENERATION: AtomicUsize` — bumped by begin_phase, threads compare to reset cursor
- Thread-local: `ARENA_PTR`, `ARENA_END`, `ARENA_BASE`, `ARENA_GEN`, `ARENA_NO_SLAB`
- Allocations during active phase: bump `ARENA_PTR` within slab bounds
- Allocations during inactive phase OR overflow: fall through to `std::alloc::System`
- `dealloc`: no-op if pointer is within `[REGION_BASE, REGION_BASE + REGION_SIZE)`

## Iteration Loop

1. Pick a specific hypothesis about what allocation pattern is unsafe
2. Write a minimal test that triggers it (or prove it can't trigger)
3. If triggered: characterize (how rare? what conditions? what corruption?)
4. Propose fix, implement, verify test now passes
5. Run full workload suite to check no regressions
6. Log finding in `findings.tsv`

## Logging — `findings.tsv`
```
id	category	description	reproducible	severity	fix_status
```
Categories: `rayon_injector`, `rayon_registry`, `crossbeam_epoch`, `dep_cache`, `phase_api`
Severity: `critical` (silent corruption), `high` (crash), `medium` (leak), `low` (theoretical)

## NEVER STOP
Run autonomously until stopped or no more hypotheses to test.
