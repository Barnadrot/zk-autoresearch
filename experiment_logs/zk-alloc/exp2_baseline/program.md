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
N=3 bash ../leanMultisig-bench/eval_paired.sh

# Production
bash reproduce_prod.sh  # runs with and without --features zkalloc
```

## Commit point

**origin/main** (pre-exp6). This is where glibc has maximum contention overhead
and the allocator has the most surface to capture.

## Gate criteria

**PASS:** eval_paired.sh delta within **±1%** of glibc (p > 0.05 = no significant
difference). Acceptable to be slightly slower — the goal is no regression, not
improvement.

**FAIL:** > 1% regression with p < 0.05.

## Experiment loop

1. Read `program.md` and `iters.tsv`.
2. Profile or apply one targeted fix.
3. Run correctness tests: `cd ~/zk-autoresearch/leanMultisig && cargo test --release --features zkalloc`
4. Run benchmark: `N=3 bash ../leanMultisig-bench/eval_paired.sh`
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

## What not to do

- Do not target specific contention sites. That's exp3.
- Do not add pressure adaptation. That's exp4.
- Do not tune for 16GB vs 64GB. Only measure on one config (64GB native).
- Do not optimize beyond parity. Stop when within ±1%.
