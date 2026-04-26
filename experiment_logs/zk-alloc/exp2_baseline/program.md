# exp2_baseline: match glibc performance

## Objective

Achieve parity with glibc system allocator on leanMultisig (origin/main).
The allocator must not regress — this validates that the architecture works
under real proving load before we optimize.

## Prerequisites

exp1_scaffold PASSED: all 56 workspace tests + 3 e2e proofs correct with zkalloc.

## Writable scope

**Only files under `leanMultisig/zk-alloc/`**.

## Benchmark commands

```bash
# Criterion (paired A/B)
cd ~/zk-autoresearch/leanMultisig
# baseline: glibc (no feature)
# candidate: zk-alloc (--features zkalloc)
N=3 bash ../experiment_logs/leanMultisig/shared/eval_paired.sh

# Production
bash reproduce_prod.sh  # runs with and without --features zkalloc
```

## Commit point

**origin/main** (pre-exp6). This is where glibc has maximum contention overhead
and the allocator has the most surface to capture.

## Gate criteria

**KEEP:** improves over previous best by ≥2 percentage points (e.g. +13% → +11%),
with arena handling small/medium allocs (System passthrough is not a valid keep).

**DISCARD:** < 2pp improvement, regression, or arena bypassed.

**EXP2 DONE:** within +5% of glibc, with arena active for small/medium allocs
(System fallback < 10% of total allocs).

**Constraint:** the allocator must actually allocate. Routing all sizes to System
is not a solution — it passes trivially but provides no foundation for exp3.

## Experiment loop

1. Read `program.md` and `iters.tsv`.
2. Profile or apply one targeted fix.
3. Run correctness tests: `cd ~/zk-autoresearch/leanMultisig && cargo test --release --features zkalloc`
4. Run benchmark: `N=3 bash ../experiment_logs/leanMultisig/shared/eval_paired.sh`
5. **Log to `iters.tsv` after every iteration.**

## Logging

Append one row per iteration to `iters.tsv`:
```
iter	criterion_pct	p	status	files_changed	rationale
```
Status: `keep`, `discard_wallclock`, `profile`, `infra_fail`

## Iteration strategy

Profile with heaptrack to find where zk-alloc is slower than glibc:

1. **TLS lookup overhead.** `thread_local!` + `UnsafeCell` has overhead on first
   access per thread. If Rayon creates many short-lived threads, this compounds.
   Fix: cache the arena pointer, or use `#[thread_local]` (nightly).

2. **mmap syscall overhead for large allocs.** glibc uses a slab allocator for
   all sizes; we mmap directly for >2MB. If there are many borderline-large
   allocs, the syscall overhead dominates.
   Fix: raise the large threshold, or use a page cache.

3. **Bump region waste.** Small allocs that are logically freed but bump doesn't
   reclaim space. If total small alloc volume exceeds arena capacity, we fall
   through to System more than glibc would.
   Fix: increase arena slab size, or add a small-object free list.

4. **Free-list overhead in pools.** Pointer chasing in the medium pool free list
   may be slower than glibc's optimized tcache.
   Fix: batch free-list operations, or use a bitmap allocator.

Expected iterations: 3–5.

## Diagnostic tools

### Performance profiling

```bash
# perf stat — parallelism ratio is the key metric (target: match glibc's 9.5x)
perf stat -e instructions,cycles,cache-misses,cache-references,L1-dcache-load-misses \
  cargo bench --manifest-path ../leanMultisig-bench/Cargo.toml --bench xmss_leaf --features zkalloc -- --sample-size 3

# Compare wall time vs CPU time to measure effective parallelism
perf stat cargo bench ... --features zkalloc 2>&1 | grep -E "task-clock|wall"
perf stat cargo bench ... 2>&1 | grep -E "task-clock|wall"  # glibc baseline

# Cache line contention (false sharing)
perf c2c record cargo bench ...
perf c2c report
```

### Allocation profiling

```bash
# heaptrack — call-site attribution
heaptrack ./target/release/deps/xmss_leaf-*

# Custom alloc_counter — size-class distribution
cd ~/zk-autoresearch/leanMultisig-bench && cargo run --release --bin alloc_counter
```

### Memory safety

```bash
# ASan — catch use-after-free, buffer overflow
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc --target x86_64-unknown-linux-gnu

# TSan — catch data races in cross-thread dealloc
RUSTFLAGS="-Z sanitizer=thread" cargo +nightly test --features zkalloc --target x86_64-unknown-linux-gnu
```

## What not to do

- Do not target specific contention sites. That's exp3.
- Do not add pressure adaptation. That's exp4.
- Do not tune for 16GB vs 64GB. Only measure on one config (64GB native).
- Do not optimize beyond +5% gate. Exp3 is where we beat glibc.
