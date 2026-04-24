# zk-alloc: Status & Revised Plan

## Where we are (after exp1 + exp2)

**exp1 (scaffold):** DONE. 12 unit tests + 3 integration tests pass. Fixed:
pointer ownership, cross-thread dealloc, arena growth, phase reset safety,
pool_class edge cases. ~1 hour.

**exp2 (baseline):** 7 iterations, current best +11.3% vs glibc (4.28s vs 3.84s).

Key findings from exp2:
- **mmap/munmap per large alloc = +42% overhead.** Fixed by routing >2MB to System.
- **36KB WorkerArena struct = cache pollution.** Shrunk to 592B, gained 1.7pp.
- **Parallelism is the bottleneck, not compute.** Total CPU time is identical;
  glibc achieves 9.5x parallelism vs our 8.1x on 16 cores.
- **Atomic contention is NOT the cause** (batching didn't help — iters 4, 7).
- **System passthrough matches glibc trivially** (-0.38%) but is not an allocator.

The remaining 11% gap is from thread serialization when accessing thread-local
arena metadata. The arena hot path (cursor/base/capacity = 24 bytes) shares
cache lines with cold metadata, and `thread_local!` uses the slow general-dynamic
TLS model vs glibc's `__thread` (initial-exec, single `fs:` offset).

## What the original plan got wrong

The waterfall (exp2 → exp3 → exp4 → exp5) assumed each experiment was independent.
Reality: **the arena can't match glibc without phase-aware design.** Trying to
out-engineer glibc's 30-year-polished tcache using the same generic patterns
(bump + free list + size classes) is a losing game. The +11% gap proves it.

The original exp3 (contention) assumed thread-local arenas automatically beat
glibc's locked arenas. They don't — glibc's arena locks are rarely contended
in practice because glibc already uses per-thread arenas (one per core). Our
overhead isn't lock contention; it's the metadata overhead of a second allocator
sitting on top of glibc.

**The novel value of zk-alloc is phase awareness (exp5), not contention
elimination (exp3).** Reorder accordingly.

## Revised plan

### exp2 (finish): Close the gap to +5%

**Remaining work:** 1-2 iterations.
- Cache-line-align the hot alloc struct (cursor/base/capacity in its own
  64-byte padded struct, cold metadata separate)
- If still >+5%: try `#[thread_local]` (nightly) for the arena pointer to
  eliminate `__tls_get_addr` overhead

**Exit at:** +5% or better with arena active for small/medium allocs.

### exp3 (revised): Phase-aware arena reset

**Was:** Beat glibc via contention elimination.
**Now:** Implement phase-aware bulk deallocation — the core novelty.

This is the most important experiment. No existing allocator can do this.
The proving pipeline has clear phase boundaries where all allocations from
the previous phase are dead. Instead of tracking individual frees (which
adds overhead that makes us slower than glibc), we reset the bump pointer
at phase boundaries and reclaim everything at once.

**Mechanism:**
1. `phase_boundary()` call between proving phases resets bump cursor to 0
2. Small/medium allocs within a phase are bump-only (no free tracking)
3. `dealloc` for bump-allocated memory is a **true no-op** (not even an
   ownership check)
4. Large allocs (>2MB) route to System (survive phase boundaries)
5. First slab is persistent (twiddle caches allocated during warmup)

**Why this beats glibc:** glibc must track every individual free because it
doesn't know allocation lifetimes. We know that proving phases are scoped —
everything allocated in witness generation dies before trace commitment.
Zero per-dealloc overhead × 50M deallocs = the entire 11% gap eliminated.

**Gate:** monotonic, ≥2pp per keep. Done at -5% vs glibc (faster, not just
matching). Requires `phase_boundary()` calls in leanMultisig (user approves
each site).

**Risk:** Objects that survive phase boundaries (cross-phase references) will
be use-after-freed. Mitigations: large allocs exempt (System-backed), epoch
tracking in debug mode, conservative placement of boundaries.

### exp4 (revised): Pressure + sizing

**Was:** Solve 16GB/64GB tradeoff with `/proc/meminfo` polling.
**Now:** Tune arena sizing and retention for both memory conditions.

Once phase reset works, the pressure question simplifies: under pressure,
return slabs to OS at phase boundaries via `madvise(MADV_DONTNEED)`.
With headroom, retain slabs across phases (pre-faulted, zero syscall overhead).

Also tune config parameters that the agent can now iterate on:
- `arena_slab_size` (initial slab per thread)
- `small_threshold` / `medium_threshold` boundaries
- Number and timing of phase boundary calls

**Gate:** ≥2pp on either 16GB or 64GB without regressing the other.
Done when: -10% on 16GB AND ±2% on 64GB.

### exp5 (revised): Generalize + polish

**Was:** Phase-aware bulk deallocation.
**Now:** Cross-prover validation + passive phase detection.

Test on Jolt and Plonky3 benchmarks. If phase boundary placement is
manual and prover-specific, explore passive detection (allocation pattern
shift → automatic reset). Polish the API for external consumption.

## Revised timeline

| Experiment | Scope | Est. iterations |
|-----------|-------|----------------|
| exp2 (finish) | Cache-line align + TLS fix | 1-3 |
| exp3 (phase) | Phase-aware arena reset | 5-10 |
| exp4 (pressure) | 16GB/64GB tuning | 3-5 |
| exp5 (generalize) | Jolt/Plonky3 + passive detection | 5-8 |

Total: ~15-25 iterations. Weekend with autoresearch agent.

## The thesis

glibc is a better *general-purpose* allocator than zk-alloc will ever be.
We don't compete on general-purpose. We compete on **knowing when memory dies.**

Every general allocator pays O(n) overhead tracking n individual frees.
zk-alloc pays O(1) per phase boundary — one pointer reset reclaims everything.
For proving workloads with 50M allocs per proof and 4-5 phase boundaries,
that's 50M × ~10ns = 500ms of overhead eliminated vs O(5) × ~1μs = 5μs.
The asymptotic advantage is real and unbounded as proof sizes grow.
