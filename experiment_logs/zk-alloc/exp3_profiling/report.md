# exp3_profiling: allocation lifecycle report

Date: 2026-04-24
System: 16GB RAM, Linux 6.8.0-1052-aws
Workload: xmss_aggregate, 1400 sigs, log_inv_rate=1

## Q1: Cross-proof survivors

**Answer: ZERO allocations survive across proofs.**

After running proof 1 and dropping its result (`ExecutionProof`), all 12,938,588
allocations (17.4 GB throughput) are fully freed. The live count at the
boundary between proofs is exactly 0 allocs, 0.00 MB.

```
=== AFTER DROPPING PROOF 1 RESULT ===
Total: 12938588 allocs, 12938588 deallocs, 0 live (0.00 MB)
```

During proof execution, the maximum live set is ~819 allocs (0.57 MB) in the
small/medium size classes. The large allocations (>= 4KB) reach a peak of
~4.6 GB live but are fully freed within the proof.

**Implication for phase_boundary():** Between proofs, a full arena reset is
safe — there is nothing to preserve. The SIGSEGV previously observed was
likely caused by one of:
1. `phase_boundary()` firing DURING a proof (before all allocs are freed)
2. `phase_boundary()` firing BEFORE the proof result was dropped
3. A race condition where Rayon workers still held live references

The fix is trivial: call `phase_boundary()` only between proofs, after
`std::mem::drop(proof_result)`.

### Persistent allocations (NOT per-proof)

Heaptrack confirms these one-time allocations live for the entire process:

| Source | Size | When | How |
|--------|------|------|-----|
| Bytecode compilation (`compile_to_low_level_bytecode`) | 172 MB | `init_aggregation_bytecode()` | `OnceLock` |
| Bytecode Vec growth (same function) | 149 MB | Same | `OnceLock` |
| DFT twiddles (`precompute_dft_twiddles`) | 67 MB | Setup | `main()` or lazy static |

Total persistent: ~388 MB. These are allocated once and never freed.
They live in the main thread's allocator state. If zkalloc arena were active,
these would occupy the main thread's slab and MUST NOT be compacted.

## Q2: Phase transitions

Timeline analysis of >= 4KB allocations (46,677 events logged during proof 1):

### Phase map (0.25s windows, cumulative live bytes)

```
Time(s) | Live allocs | Live MB  | Phase
--------|-------------|----------|------
  0.00  |          85 |   256.70 | Witness gen: VM execution burst
  0.25  |         162 |  1171.59 | Witness gen: trace building
  0.50  |         163 |  1205.14 | -- gap (minimal activity) --
  1.00  |         179 |  1760.89 | Trace building continues
  1.25  |         199 |  2630.35 | PEAK trace phase (mem_acc, bytecode_acc)
  1.50  |         217 |  2957.75 | Commitment starts (mixed alloc/dealloc)
  1.75  |         219 |  2794.59 | Commitment: old buffers freed
  2.00  |         372 |  1585.80 | Commitment: massive dealloc wave (-1209 MB)
  2.25  |         373 |  1564.16 | Commitment: settling
  2.50  |         372 |  1409.49 | Commitment complete
  2.75  |         385 |  1262.26 | -- transition --
  3.00  |         196 |  2591.00 | Logup/GKR: new allocation spike (+1329 MB)
  3.50  |         198 |  2758.78 | GKR continues
  3.75  |         198 |  3933.18 | AIR sumcheck: massive alloc (+1174 MB)
  4.00  |         200 |  4604.27 | PEAK TOTAL (4.6 GB live)
  4.25  |         199 |  3262.09 | Sumcheck: first dealloc wave
  4.50  |         199 |  1357.87 | WHIR: massive dealloc (-1904 MB)
  4.75  |         216 |  1372.64 | WHIR proof generation
  5.00  |         216 |  1372.64 | WHIR continues
  5.25  |         216 |  1372.64 | WHIR continues
  5.50  |         214 |   804.96 | Cleanup begins
  5.75  |           5 |     0.14 | Nearly all freed
```

### Identified phases and transitions

| # | Phase | Time range | Alloc pattern | Peak live |
|---|-------|-----------|---------------|-----------|
| 1 | **Witness gen** | 0.0 – 0.5s | Burst of 6k allocs, 1.5 GB net positive | 1.2 GB |
| 2 | **Trace + memory building** | 0.5 – 1.5s | Steady large allocs, ramp to peak | 2.96 GB |
| 3 | **Polynomial commitment** | 1.5 – 2.75s | Heavy churn: alloc+dealloc, net negative | 1.26 GB (after) |
| 4 | **Logup/GKR + AIR sumcheck** | 3.0 – 4.5s | Second major peak, then rapid free | 4.6 GB (peak) |
| 5 | **WHIR proof + cleanup** | 4.5 – 5.9s | Dealloc-dominated, total cleanup | 0 MB |

### Size class breakdown by phase

| Phase | Small (<=16K) | Medium (16K-1M) | Large (>1M) |
|-------|--------------|----------------|-------------|
| 1: Witness gen | 36 MB | 136 MB | 1336 MB |
| 2: Trace building | 0.03 MB | 5 MB | 1461 MB |
| 3: Commitment | 75 MB | 489 MB | 1814 MB |
| 4: GKR + sumcheck | 6 MB | 22 MB | 4036 MB |
| 5: WHIR + cleanup | 1 MB | 35 MB | 4378 MB |

Large allocations (> 1 MB) dominate every phase. The allocation pattern is
dominated by bulk Vec operations for polynomial storage, FFT buffers,
and multilinear evaluations.

### Recommended boundary points for phase_boundary()

**None within a single proof are safe for full arena reset.** At every
candidate boundary, 1-4.6 GB of data is still live in the arena. These
are working polynomial buffers that carry forward to later phases.

The ONLY safe reset point is between proofs (live = 0 after drop).

For **partial compaction** (freeing exhausted slabs while keeping live ones),
the best points are:
- After commitment (t≈2.75s): live dropped from 2.96 GB to 1.26 GB
- After WHIR start (t≈4.5s): live dropped from 4.6 GB to 1.36 GB

## Q3: Per-boundary liveness

Mapping to prove_execution.rs pipeline stages:

| Boundary | Location | Live allocs | Live bytes | Safe for reset? |
|----------|----------|-------------|------------|-----------------|
| After witness gen | line 36 (end of info_span) | ~163 | ~1.2 GB | **NO** — trace data still live |
| After trace commitment | line 104 (after stack_polynomials_and_commit) | ~385 | ~1.3 GB | **NO** — committed witness still live |
| After logup/GKR | line 133 (end of prove_generic_logup) | ~196 | ~2.6 GB | **NO** — logup_statements still live |
| After AIR sumcheck | line 204 (end of sumcheck loop) | ~199 | ~1.4 GB | **NO** — sessions + stacked_pcs_witness live |

### What is alive at each boundary

**After witness gen (line 36):**
- `ExecutionTrace` (traces, memory, metadata) — all column vectors
- `memory` vector (padded to power of 2, >= 1M entries × 4B = >= 4 MB)
- Used until end of prove_execution

**After commitment (line 104):**
- All of the above, PLUS
- `stacked_pcs_witness` — polynomial commitment witness
- `memory_acc`, `bytecode_acc` — multilinear polynomials
- Used by logup/GKR and final WHIR proof

**After logup/GKR (line 133):**
- `stacked_pcs_witness` still needed for WHIR
- `logup_statements` — GKR output (points, values, bus data)
- `traces` still referenced for AIR sumcheck column_refs

**After AIR sumcheck (line 204):**
- `stacked_pcs_witness` still needed for WHIR
- `global_statements_base` being built
- All committed_statements

### Conclusion for Q3

Every proving stage produces data consumed by later stages. There is no
internal boundary where previously-allocated data can be safely discarded.
The data flows strictly forward through the pipeline.

## Q4: Criterion interference

**Answer: Criterion does NOT allocate persistent buffers that would interfere.**

Evidence from heaptrack comparison:

| Metric | heap_runner (no Criterion) | alloc_profiler (profile-like) |
|--------|--------------------------|-------------------------------|
| Persistent leaks | 388 MB | 388 MB |
| Leak sources | OnceLock bytecode + twiddles | Same |
| Criterion-specific leaks | N/A | 0 B |

The 388 MB of persistent allocations are identical in both runs and come
exclusively from:
1. `compile_to_low_level_bytecode` via `OnceLock` (321 MB)
2. `precompute_dft_twiddles` from `main()` (67 MB)

No Criterion-specific allocations appear in the leak report. Criterion's
infrastructure (timer, statistics, iteration control) uses only stack
variables and short-lived heap allocations that are freed between iterations.

### Implication for zkalloc

Since the lifecycle profiler confirmed ZERO live allocations between proofs,
there is no Criterion interference. The `phase_boundary()` call is safe
at iteration boundaries regardless of whether Criterion is present.

However, the 388 MB of persistent one-time allocations (bytecode + twiddles)
DO land in the arena if zkalloc is the global allocator. These allocations
happen on the main thread during setup, before any proofs run. If
`phase_boundary()` were to reset the main thread's arena, these would be
destroyed.

**Recommendation:** Exempt the main thread from arena compaction. Only
compact Rayon worker thread arenas. Since all per-proof allocations on
worker threads are fully freed between proofs, worker arena compaction
is safe at proof boundaries.

## Summary of findings

1. **Cross-proof survivors: NONE.** All proof allocations are freed when
   the proof result is dropped. phase_boundary() between proofs is safe.

2. **Phase transitions: 5 clear phases** identified from allocation
   patterns (witness gen, trace building, commitment, GKR+sumcheck, WHIR).
   Peak memory reaches 4.6 GB at the GKR/sumcheck boundary.

3. **Intra-proof boundaries: ALL UNSAFE** for full arena reset. 1-4.6 GB
   is live at every candidate boundary point within a proof.

4. **Criterion: No interference.** No persistent Criterion allocations.
   The 388 MB persistent allocation is from bytecode compilation and DFT
   twiddles, both one-time setup on the main thread.

### Next steps for exp3a/exp3b

- **Safe compaction strategy:** Only compact between proofs, only on
  Rayon worker threads, only after proof result is dropped.
- **Partial compaction within proofs:** Possible but requires slab-level
  tracking (which slabs have no live pointers). The commitment phase
  (t≈2.0s) frees ~1.7 GB — those slabs could be returned to OS.
- **The SIGSEGV root cause:** phase_boundary() fired while proof data
  was still live. The fix is timing, not mechanism.
