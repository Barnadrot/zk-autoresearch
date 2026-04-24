# exp5_phase: phase-aware bulk deallocation

## Objective

Exploit the proving pipeline's phase structure for O(1) arena reset between
phases. This is the uniquely-ZK optimization — no general-purpose allocator
can do this because it requires domain knowledge about allocation lifetimes.

## Prerequisites

exp4_pressure PASSED: zk-alloc beats glibc on 16GB, no meaningful regression on 64GB.

## Writable scope

**`leanMultisig/zk-alloc/`** for the allocator. **Exception:** minimal
`phase_boundary()` call sites may be added to leanMultisig proving pipeline
(requires user approval per call site).

## Commit point

**origin/main** initially, then validate on **post-exp6** to measure combined
effect.

## Gate criteria

**KEEP:** ≥1% additional improvement over previous best, p < 0.05.
Phase-aware gains compound on top of exp3/exp4 results.

**DISCARD:** < 1% improvement, correctness regression, or phase reset
causes use-after-free (verified by tests passing).

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

## Experiment loop

1. Read `program.md` and `iters.tsv`.
2. Profile or apply one targeted optimization.
3. Correctness: `cargo test --release --features zkalloc`
4. Benchmark: `N=3 bash ../experiment_logs/leanMultisig/shared/eval_paired.sh`
5. **Log to `iters.tsv` after every iteration.**

## Logging

Append one row per iteration to `iters.tsv`:
```
iter	criterion_pct	p	status	files_changed	rationale
```
Status: `keep`, `discard_wallclock`, `profile`, `infra_fail`

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

## Diagnostic tools

### Phase boundary identification

```bash
# Tracing — find where allocation patterns shift
# Add temporary eprintln! at phase transitions in leanMultisig to log timestamps
# Then correlate with heaptrack timeline

# heaptrack with phase markers
heaptrack ./target/release/deps/xmss_leaf-*
heaptrack_print heaptrack.*.zst | head -200

# Custom alloc_counter — per-phase breakdown (already has phase awareness)
cd ~/zk-autoresearch/leanMultisig-bench && cargo run --release --bin alloc_counter
```

### Safety verification (critical for phase reset)

```bash
# ASan — MUST run after every phase_boundary() placement change
# This is the primary defense against use-after-free from premature reset
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc --target x86_64-unknown-linux-gnu

# TSan — verify no races during phase boundary calls
RUSTFLAGS="-Z sanitizer=thread" cargo +nightly test --features zkalloc --target x86_64-unknown-linux-gnu

# Run full integration tests under ASan (slow but necessary)
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --release --features zkalloc --test test_lean_multisig --target x86_64-unknown-linux-gnu
```

### Arena utilization

```bash
# Verify bump cursor watermark per phase (are we resetting at the right points?)
# Verify slab count stays bounded (no unbounded growth)
# Verify System fallback rate per phase (should be <10% overall, may spike in some phases)
# These require temporary counters in arena.rs — add/remove per iteration
```

## What not to do

- Do not redesign the core arena (exp1-3 already shipped that).
- Do not change pressure policy (exp4 already shipped that).
- Do not generalize to other proving systems yet.
