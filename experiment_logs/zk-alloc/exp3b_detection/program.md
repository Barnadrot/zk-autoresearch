# exp3b: autonomous phase detection

## Role

Expert Rust systems programmer. Signal processing on allocation streams,
online change-point detection, ZK proving workload characterization.

## Objective

Replace manual `phase_boundary()` calls with autonomous detection inside the
allocator. The allocator should detect phase transitions from allocation
patterns alone and trigger arena resets automatically. Zero prover code changes —
true drop-in `#[global_allocator]`.

This is what makes zk-alloc portable across provers. Without this, every prover
needs custom `phase_boundary()` instrumentation.

## Prerequisites

exp3a PASSED: zk-alloc beats glibc by ≥5% with manual phase boundaries.
The speedup is validated — this experiment replaces the manual API, not the
mechanism.

## Writable scope

**Only `leanMultisig/zk-alloc/`**. The entire point is zero prover changes.
If this experiment succeeds, the `phase_boundary()` calls added in exp3a are
removed from leanMultisig.

## Benchmark commands

```bash
cd ~/zk-autoresearch/leanMultisig

# Criterion paired A/B
N=10 RUSTFLAGS="-C target-cpu=native" bash ../leanMultisig-bench/eval_paired.sh

# Correctness
cargo test --release --features zkalloc

# Safety (mandatory every iteration — false positive detection = use-after-free)
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc \
  --target x86_64-unknown-linux-gnu
```

## Gate criteria

**KEEP:** detection accuracy improves (fewer false positives or better phase
coverage) AND performance within 1% of exp3a result, AND ASan passes.

**DISCARD:** any false positive (premature reset = use-after-free), performance
regression > 1% vs exp3a, or ASan failure.

**EXP3b DONE:** matches exp3a performance (within 1%) with zero manual
`phase_boundary()` calls, zero false positives across 10 consecutive full runs.

**KILL CRITERION:** if iter 1 profiling shows phase boundaries are not
detectable from allocation patterns alone (transitions are gradual, interleaved,
or indistinguishable), abort exp3b and ship with manual API from exp3a.

## Context: what to detect

From exp3a profiling, phase transitions produce measurable shifts in:
- **Alloc size distribution** — witness gen is 32-128B, trace commit is 1-84MB
- **Alloc/dealloc ratio** — bump phases have ratio >> 1 (allocs without frees),
  churn phases have ratio ≈ 1
- **Alloc rate** — burst vs steady

The detector must be:
- **O(1) per alloc** — counter increment + comparison, nothing more
- **Conservative** — false negatives (missed boundary) waste memory but are safe;
  false positives (premature reset) cause use-after-free and are catastrophic
- **Configurable** — window size, threshold, cooldown in config.rs for agent tuning

## Experiment loop

1. Read `program.md` and `iters.tsv`.
2. Profile, hypothesize, or implement one change.
3. Correctness: `cargo test --release --features zkalloc`
4. **ASan: mandatory every iteration** (false positive = UB).
5. Benchmark: `N=10 bash ../leanMultisig-bench/eval_paired.sh`
6. Validate: run 10 consecutive full runs, count detected boundaries vs expected.
7. **Log to `iters.tsv` after every iteration.**

## Logging

```
iter	criterion_pct	p	false_positives	boundaries_detected	status	files_changed	rationale
```
Status: `keep`, `discard_wallclock`, `discard_safety`, `profile`, `infra_fail`

## Diagnostic tools

### Phase pattern analysis

```bash
# Alloc pattern log — add temporary logging to alloc_inner:
#   eprintln!("{} {} {}", timestamp_ns, size, "alloc"/"dealloc")
# Run proving, pipe to file, analyze offline

# Custom alloc_counter — already has phase-aware size-class breakdown
cd ~/zk-autoresearch/leanMultisig-bench && cargo run --release --bin alloc_counter
```

### Safety (MANDATORY — run every iteration)

```bash
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc \
  --target x86_64-unknown-linux-gnu
```

### Detection validation

```bash
# Run 10 consecutive full proving runs, log detected boundaries
for i in $(seq 1 10); do
  cargo bench --manifest-path ../leanMultisig-bench/Cargo.toml \
    --bench xmss_leaf --features zkalloc -- --sample-size 1 2>&1
done
# Check logs for consistent boundary detection across runs
```

## What not to do

- Do not modify leanMultisig source code (that defeats the purpose).
- Do not add pressure adaptation (exp4).
- Do not sacrifice safety for detection accuracy — conservative always wins.
- Do not add detection overhead that shows up in perf (must be O(1) per alloc).

## NEVER STOP

Run autonomously until stopped or stop criterion hit.
8 consecutive discards → pause and report.
