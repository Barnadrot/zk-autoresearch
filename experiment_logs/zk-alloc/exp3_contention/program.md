# exp3a: beat glibc with phase-aware allocation

## Role

Expert Rust systems programmer. Memory allocator design, ZK proving workload
profiling, phase-aware memory management.

## Objective

Make zk-alloc faster than glibc on leanMultisig by exploiting the phase structure
of ZK proving. The hypothesis: proving has 4-5 distinct phases with different
allocation patterns. If dealloc becomes a no-op and memory is reclaimed in bulk
at phase boundaries, we eliminate the RSS blowup and TLB pressure that costs +8.6% vs glibc.

No existing allocator does this. This is what makes zk-alloc novel.

## Prerequisites

exp2 findings (carry forward — do not re-discover):
- **Starting point: +8.6% vs glibc** (4.15s vs 3.82s approx)
- RSS blowup: 38.5GB vs glibc's 5.7GB — bump never frees, TLB pressure
  kills parallelism (8.1x vs glibc's 9.5x on 16 cores)
- Large allocs (>2MB) must route to System (mmap/munmap per alloc = +42%)
- WorkerArena struct must stay small (<1 cache line hot path)
- Per-dealloc ownership checks destroy parallelism
- Atomic contention batching does not help (exp2 iters 4, 7)
- System passthrough proves the plumbing works but is not an allocator
- Routing medium to System: reduces RSS but worse perf (fragmentation)

## Writable scope

- **`leanMultisig/zk-alloc/`** — the allocator crate
- **`leanMultisig/src/`** and **`leanMultisig/crates/`** — `phase_boundary()`
  call sites. Place them wherever the profiling suggests, no approval needed.
  The gate (benchmark + ASan) catches bad placements.

## Benchmark commands

```bash
cd ~/zk-autoresearch/leanMultisig

# Criterion paired A/B
N=10 RUSTFLAGS="-C target-cpu=native" bash ../experiment_logs/leanMultisig/shared/eval_paired.sh

# Correctness
cargo test --release --features zkalloc

# Safety (run after any phase reset change)
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc --target x86_64-unknown-linux-gnu
```

## Gate criteria

**KEEP:** zkalloc ≥2% faster than previous KEEP's zkalloc time, p < 0.05.
The paired glibc run provides variance control — use its p-value, but
gate on absolute zkalloc improvement, not the glibc delta.

**DISCARD:** < 2% improvement, regression, or p > 0.05.

**EXP3a DONE:** zk-alloc faster than glibc by ≥5%, p < 0.01. Majority of
small/medium allocs must be served from bump/pool, not System fallback.

**STOP:** 12 consecutive discards → pause and report.

## Context: proving phases

The proving pipeline has distinct allocation phases. From exp6 profiling:

| Phase | Pattern | Volume |
|-------|---------|--------|
| Witness generation | Many small allocs (32-128B field elements) | ~500MB |
| Trace commitment | Few large allocs (polynomial buffers, Merkle) | ~2GB |
| Logup/sumcheck | Medium churn (scratch buffers), rapid alloc/dealloc | ~200MB |
| WHIR/FRI queries | Medium + large, eq_mle sweeps | ~1GB |
| Serialization | Small, postcard encoding | negligible |

Allocation profile: 70% ≤128B, 20% 128B–64KB, 9% 64KB–4MB, 1% >4MB.
~50M allocs per proof on origin/main.

## Git workflow

- **Never commit to `main`** in any repo. All work on branches.
- zk-alloc repo: work on branch `exp3a`. Create if needed: `git checkout -b exp3a`.
- leanMultisig repo: work on branch `exp3a`. Create if needed: `git checkout -b exp3a`.
  This is where `phase_boundary()` call sites go.
- zk-autoresearch repo: work on branch `zk-alloc-exp` (already exists).

## Experiment loop

1. Read `program.md` and `iters.tsv`.
2. Profile, hypothesize, or implement one change.
3. Correctness: `cargo test --release --features zkalloc`
4. If touching phase reset logic: run ASan.
5. Commit: `git add` changed files, `git commit` with iter number and rationale.
6. Benchmark: `N=10 bash ../experiment_logs/leanMultisig/shared/eval_paired.sh`
7. **Log to `iters.tsv` after every iteration.**
8. If KEEP: commit iters.tsv update.
9. If DISCARD: `git revert HEAD` to undo the change. Commit iters.tsv update separately.

## Logging

```
iter	criterion_pct	p	status	files_changed	rationale
```
Status: `keep`, `discard_wallclock`, `profile`, `infra_fail`

## Diagnostic tools

### Performance

```bash
# Parallelism ratio (key metric — target: match or beat glibc's 9.5x)
perf stat cargo bench --manifest-path ../leanMultisig-bench/Cargo.toml \
  --bench xmss_leaf --features zkalloc -- --sample-size 3

# Hot functions
perf record -g cargo bench ... && perf report --no-children

# Cache line contention (false sharing)
perf c2c record cargo bench ... && perf c2c report
```

### Allocation profiling

```bash
# heaptrack — call-site attribution, preserves threading
heaptrack ./target/release/deps/xmss_leaf-*

# Custom alloc_counter — size-class + phase distribution
cd ~/zk-autoresearch/leanMultisig-bench && cargo run --release --bin alloc_counter
```

### Safety (mandatory after phase reset changes)

```bash
# ASan — use-after-free detection
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --features zkalloc \
  --target x86_64-unknown-linux-gnu

# TSan — data races
RUSTFLAGS="-Z sanitizer=thread" cargo +nightly test --features zkalloc \
  --target x86_64-unknown-linux-gnu
```

### System

```bash
# RSS monitoring (verify memory stays bounded with no-op dealloc)
watch -n1 'grep -E "VmRSS|VmHWM" /proc/$(pgrep -f xmss_leaf)/status'

# Memory pressure (16GB cgroup)
sudo cgexec -g memory:bench16g bash ../experiment_logs/leanMultisig/shared/eval_paired.sh
```

## Phase boundary placement rules

- **Never place `phase_boundary()` inside a parallel section** — only at
  sequential join points between pipeline stages (after Rayon joins, between
  top-level pipeline calls).
- Start coarse: first boundary between witness gen and trace commitment.
  Add more only after validating each placement with ASan.
- Large allocs (>2MB) are exempt — they go through mmap/munmap (System),
  never touch the arena, survive resets naturally. Cross-phase objects like
  committed polynomials and Merkle trees are large.
- The benchmark (`xmss_leaf`) runs the full proving pipeline — if ASan
  passes on it, every cross-phase reference was safe.

## What not to do

- Do not retry exp2 dead ends (atomic batching, System passthrough).
- Do not add pressure adaptation (exp4).
- Do not build autonomous phase detection (exp3b).
- Do not optimize for 64GB. Only 64GB native this experiment.
- Do not add complexity that grows the crate beyond ~1500 lines.

## Alternative approaches (if current path stalls)

If mid-proof phase boundaries keep hitting cross-thread reference issues,
consider these alternatives in order of feasibility:

### E. Between-proof compaction (safest first step)
Compact arenas at the START of each proof, reclaiming memory from the
previous proof iteration. Everything from proof N is dead before N+1.
Pros: trivially safe, zero intra-proof overhead, RSS drops from ~54GB to ~5GB.
Cons: RSS still peaks at 54GB during each proof, no intra-proof reclamation.

### F. Slab age tracking
Track when each slab last had a new allocation. At phase boundary,
MADV_DONTNEED slabs that haven't been touched since the previous phase.
Pros: O(1) per boundary, no per-alloc overhead, conservative.
Cons: age is heuristic not guarantee, needs tuning per workload.

### A. Shared arena with atomic bump
One arena for all threads, bump via fetch_add. No cross-thread problem.
Pros: eliminates ownership issue, ~5ns per alloc, simple implementation.
Cons: false sharing on cursor cache line, destroys per-thread locality,
scales badly at high core counts. exp2 showed atomics didn't help but
that was contention batching, not simple bump — worth retesting.

### D. Generation-based arenas
Each phase gets a new arena generation. Old generations become read-only.
Compact a generation when refcount hits zero.
Pros: architecturally clean, provably safe, natural fit for ZK phases.
Cons: per-alloc refcounting has overhead (exp2 showed +4.8% from counting),
complexity grows fast, risk of becoming a mini GC.

### B. Copy-on-collect
When Rayon collects worker results, deep-copy into main thread's arena.
Workers become safely compactable after each parallel section.
Pros: multiple compaction points per proof, clean lifetime separation.
Cons: requires modifying leanMultisig code (breaks drop-in goal), fragile
across codebase changes, must instrument all collect sites.

### C. Escape-aware routing (research-grade)
Route phase-local allocs to bump, escaping allocs to System. Impossible to
know at alloc time whether a pointer escapes — would need compiler
integration or manual annotation. Not feasible for a weekend.

## NEVER STOP

Run autonomously until stopped or stop criterion hit.
