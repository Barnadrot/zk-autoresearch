# zk-alloc: Status & Revised Plan (v2)

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
arena metadata on every dealloc. The per-dealloc ownership check + TLS access
is the overhead — not the alloc path.

## What the original plan got wrong

1. **Waterfall was wrong.** exp2→3→4→5 assumed each was independent. Reality:
   the arena can't match glibc without phase-aware design. The +11% gap from
   per-dealloc overhead proves generic patterns can't beat glibc's 30 years.

2. **Contention was the wrong target.** glibc already uses per-thread arenas.
   Our overhead isn't lock contention — it's the cost of a second allocator
   sitting on top of glibc.

3. **Manual phase_boundary() is the wrong API.** Requiring provers to add
   explicit calls makes zk-alloc non-portable. Every prover would need custom
   instrumentation. The allocator should detect phases itself.

## The design: autonomous phase detection

ZK proving has a distinctive allocation fingerprint:

| Phase | Dominant alloc pattern |
|-------|----------------------|
| Witness generation | Many small (32-128B field elements), sustained burst |
| Trace commitment | Few large (polynomial buffers 1-84MB), Merkle trees |
| Logup/sumcheck | Medium churn (scratch buffers), rapid alloc/dealloc |
| WHIR/FRI queries | Medium + large, systematic pattern, eq_mle sweeps |
| Serialization | Small, postcard encoding, negligible |

These patterns are **structurally different** — you can distinguish them by
monitoring a rolling window of (alloc_size, alloc_rate, dealloc_rate). When
the distribution shifts, a phase boundary has occurred.

**Detection mechanism:**
- Track rolling average of alloc sizes (exponential moving average, ~zero cost)
- Track alloc/dealloc ratio in a window (bump phases have ratio >> 1, churn
  phases have ratio ≈ 1)
- When the size distribution shifts by more than a threshold → phase transition
- On transition: reset bump cursor, return extra slabs (under pressure), resize
  arena for the new phase's expected volume

**Why this is better than manual API:**
- Zero code changes to the prover — true drop-in `#[global_allocator]`
- Works on any ZK prover (leanMultisig, Jolt, Plonky3, SP1) without per-prover tuning
- The allocator learns the workload, not the other way around
- Config parameters (window size, shift threshold, slab retention policy) are
  agent-tunable via config.rs

**Why this is safe:**
- Only reset slabs that are fully within the previous phase (bump cursor tracking)
- Large allocs (>2MB) always go through System — never touched by phase reset
- Conservative: if uncertain whether a phase transition occurred, don't reset
- Debug mode: epoch tracking on allocations, assert no stale references

## Revised experiments

### exp3: Phase detection + no-op dealloc

**The core experiment.** Build the autonomous phase detector and make dealloc
a true no-op for bump-allocated memory.

**Iteration plan:**
1. **Profile** — instrument alloc/dealloc with size+timestamp logging, run
   full proving pipeline, visualize the phase pattern. Confirm phases are
   detectable from allocation patterns alone.
2. **Build detector** — rolling window of alloc sizes + alloc/dealloc ratio.
   Add to arena.rs. Triggered check is O(1) — increment counter, compare
   moving average. No branches on hot path unless threshold crossed.
3. **No-op dealloc** — once detector is validated, make dealloc_small and
   dealloc_medium true no-ops (not even an ownership check). All reclamation
   happens at detected phase boundaries.
4. **Tune detection parameters** — window size, shift threshold, cooldown
   period. These go in config.rs for agent tuning.
5. **Validate safety** — ASan on every change, full integration test suite,
   verify no use-after-free from premature resets.

**Gate:** monotonic ≥2pp per keep. Done at -5% vs glibc.

**Key risk:** false positive phase detection → premature reset → use-after-free.
Mitigation: conservative thresholds, large allocs exempt, ASan mandatory.

### exp4: Pressure adaptation + config tuning

Once phase detection works, pressure adaptation becomes simple:
- **Under pressure (16GB):** return slabs to OS at phase boundaries via
  `madvise(MADV_DONTNEED)`. Detected phases tell us when memory is reclaimable.
- **With headroom (64GB):** retain slabs across phases, pre-faulted. Skip
  the madvise call. Zero syscall overhead.

Also tune all config.rs parameters:
- `arena_slab_size` per detected phase type
- `small_threshold` / `medium_threshold` aligned to field element sizes
- Detection window size and shift threshold
- Slab retention policy per memory condition

**Gate:** ≥2pp on either 16GB or 64GB without regressing the other.
Done when: -10% on 16GB AND ±2% on 64GB.

### exp5: Cross-prover validation

Test zk-alloc on Jolt and Plonky3 benchmarks. The autonomous phase detector
should work without any prover-specific tuning — if it doesn't, the design
is wrong.

**Questions to answer:**
- Does the detector find phase boundaries in Jolt's execution trace?
- Does Plonky3's DFT/NTT workload have detectable phases?
- Do the same config.rs parameters work across provers, or do they need
  per-prover tuning?

**Gate:** no regression on any prover. Improvement on ≥2 of 3.

## Timeline

| Experiment | Scope | Est. iterations |
|-----------|-------|----------------|
| exp2 (finish) | Close to +5% with struct layout | 1-3 |
| exp3 (phase detection) | Autonomous detector + no-op dealloc | 8-12 |
| exp4 (pressure) | 16GB/64GB tuning | 3-5 |
| exp5 (cross-prover) | Jolt/Plonky3 validation | 5-8 |

Total: ~20-30 iterations.

## The thesis

General allocators track every free individually: O(n) overhead for n frees.
They must — they don't know when memory dies.

zk-alloc detects when memory dies by reading the allocation pattern. Phase
transitions are visible in the size distribution. At each transition, one
pointer reset reclaims everything: O(1) per phase.

For proving workloads with 50M allocs and 4-5 phases, that's:
- glibc: 50M × ~10ns = **500ms** of free-tracking overhead
- zk-alloc: 5 × ~1μs = **5μs** of phase-boundary overhead

This advantage grows with proof size. No general allocator can match it
because the information (phase structure) doesn't exist at the allocator
interface — you have to infer it from behavior.

No one has built this before. Not because it's impossible, but because no
one looked at allocators from the proving workload's perspective.
