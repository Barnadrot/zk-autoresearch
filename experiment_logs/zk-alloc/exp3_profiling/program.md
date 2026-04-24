# exp3_profiling: map allocation lifecycles for phase boundary placement

## Role

Expert Rust systems programmer. Allocation profiling, lifetime analysis,
ZK proving workload characterization.

## Objective

Profile the leanMultisig proving pipeline to answer three questions:
1. Which allocations survive across proof iterations (Criterion runs)?
2. Where exactly do allocation phase transitions occur in the pipeline?
3. What is alive at each candidate phase boundary point?

This is a profiling-only experiment. No performance gate. No benchmark.
Output is a report that tells the next coding iteration exactly where
phase boundaries are safe.

## Writable scope

- **`leanMultisig/zk-alloc/`** — temporary instrumentation only (revert after)
- **`leanMultisig-bench/`** — temporary profiling harnesses
- **`experiment_logs/zk-alloc/exp3_profiling/`** — reports and data

Do NOT commit instrumentation to the exp3a branch. Work on a throwaway
branch or stash changes after profiling.

## Questions to answer

### Q1: What survives across proof iterations?

The between-proof `phase_boundary()` causes SIGSEGV. Something allocated
during proof N is still alive when proof N+1 starts. Find out what.

Method: Add a temporary debug `HashMap<*mut u8, (usize, &'static str)>`
to the arena that tracks (size, call_site_hint) for every live allocation.
At the point where `phase_boundary()` would fire (start of prove_execution),
dump all live allocations. Run 2 proof iterations, compare the dumps.
Allocations present in both dumps are the survivors.

Key question: is it Criterion infrastructure, or actual proving data?

### Q2: Allocation timeline within a single proof

Instrument `alloc_inner` and `dealloc_inner` with a lightweight log:

```rust
eprintln!("{}\t{}\t{}\t{}", thread_id, size, "A"/"D", timestamp_ns);
```

Run ONE proof (not the full benchmark — use `--sample-size 1`).
Pipe stderr to a file. Analyze offline:

- Plot alloc rate over time — where are the bursts?
- Plot size distribution over time — where does it shift?
- Plot alloc/dealloc ratio in rolling windows — where are bump phases vs churn?
- Identify the 4-5 phase transitions from the allocation pattern alone

This directly feeds exp3b (autonomous detection) later.

### Q3: What is alive at each candidate boundary point?

The proving pipeline has these sequential join points (from prove_execution.rs):
1. After witness gen / trace building (~line 36)
2. After trace commitment (~line 110)
3. After logup/GKR (~line 133)
4. After AIR sumcheck (~line 225)

For each point, log the arena state:
- Number of live allocations per slab
- Total live bytes per slab
- Which size classes dominate
- RSS at that point

This tells us which boundaries are safe (few/no live allocs in old slabs)
vs dangerous (many live allocs spread across slabs).

### Q4: Criterion's own allocations

Run the benchmark without zkalloc (glibc), instrument with heaptrack.
Check if Criterion allocates persistent buffers between iterations that
would land in the arena under zkalloc.

If yes: the fix is to exempt the main/Criterion thread from compaction,
only compact Rayon worker threads.

## Tools

```bash
# heaptrack — full allocation profiling with call stacks
heaptrack ./target/release/deps/xmss_leaf-*
heaptrack_print heaptrack.*.zst | head -500

# Custom alloc_counter — already exists
cd ~/zk-autoresearch/leanMultisig-bench && cargo run --release --bin alloc_counter

# perf + flamegraph for allocation hotspots
perf record -g --call-graph dwarf cargo bench ...
perf script | stackcollapse-perf.pl | flamegraph.pl > alloc_flame.svg

# RSS monitoring during proof
watch -n0.5 'grep -E "VmRSS|VmHWM" /proc/$(pgrep -f xmss_leaf)/status'
```

## Output

Write findings to `experiment_logs/zk-alloc/exp3_profiling/report.md`:

```markdown
## Q1: Cross-proof survivors
- N allocations survive across proofs
- Sizes: [list]
- Sources: [call sites if available]
- Are they from Criterion or the prover?

## Q2: Phase transitions
- Timestamp ranges for each phase
- Allocation rate / size shifts at each transition
- Recommended boundary points

## Q3: Per-boundary liveness
| Boundary | Live allocs | Live bytes | Safe? |
|----------|------------|------------|-------|
| After witness gen | ? | ? | ? |
| After commitment | ? | ? | ? |
| After logup | ? | ? | ? |
| After sumcheck | ? | ? | ? |

## Q4: Criterion interference
- Does Criterion allocate persistent buffers? Y/N
- If Y: sizes and count
```

## What not to do

- Do not benchmark or measure performance — this is profiling only
- Do not commit instrumentation to exp3a branch
- Do not try to fix the SIGSEGV — just diagnose it
- Do not spend more than ~30 minutes on this — it's a focused profiling pass

## NEVER STOP

Complete all 4 questions, write the report, then stop.
