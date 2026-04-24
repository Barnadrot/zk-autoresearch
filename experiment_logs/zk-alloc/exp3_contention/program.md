# exp3_contention: beat glibc on allocator contention

## Objective

Capture the contention improvement that mimalloc achieves (-24% production on
16GB) through thread-local arenas that eliminate glibc arena lock contention.
This is the core value proposition of zk-alloc.

## Prerequisites

exp2_baseline PASSED: zk-alloc within +5% of glibc with arena active.

## Writable scope

**Only files under `leanMultisig/zk-alloc/`**.

## Commit point

**origin/main** (pre-exp6). Contention sites are still live — maximum surface.

## Benchmark commands

```bash
# Criterion (paired A/B, glibc vs zk-alloc)
cd ~/zk-autoresearch/leanMultisig
N=3 bash ../experiment_logs/leanMultisig/shared/eval_paired.sh

# Production
bash reproduce_prod.sh
```

## Gate criteria

**KEEP:** improves over previous best by ≥2 percentage points, p < 0.05.
Progress toward beating glibc counts — don't discard real improvements just
because they don't hit a fixed threshold.

**DISCARD:** < 2pp improvement, regression, or p > 0.05.

**EXP3 DONE:** zk-alloc faster than glibc by ≥5% on 16GB (cgroup), p < 0.01.

Target: -10% or better (half of mimalloc's -24%).

## Known contention sites (from exp6 profiling)

These are the sites where glibc arena locks cause measurable slowdown:

1. **eq_mle par_iter chunks** — 9.09M Vec allocs from WHIR STIR queries.
   All Rayon threads allocating simultaneously. exp6 fixed this at the source
   level; zk-alloc should handle it at the allocator level.

2. **Trace column reallocation** — 210K realloc cascades across 1399 Rayon
   segments. Each realloc may require a new arena lock acquisition.

3. **Matrix row slices** — 1.62M allocs in Merkle tree construction, all
   parallel.

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

1. **Optimize bump allocator hot path.** The bump pointer increment is the
   innermost operation — it must be as fast as possible. Minimize TLS lookup,
   alignment padding, bounds checking. Target: < 5ns per small alloc.

2. **Size-class pool tuning.** The polynomial buffer sizes from exp6 profiling:
   - 32B, 64B, 128B (field element Vecs) — most frequent
   - 4KB, 8KB (trace columns)
   - 320KB (eq_mle tile buffers)
   - 84MB (full polynomial buffers)
   Tune pool boundaries to match. Avoid splitting a hot size class across
   the small/medium boundary.

3. **Cross-thread dealloc optimization.** Rayon work-stealing means ~10-20%
   of deallocs happen on a different thread than the alloc. The MPSC queue
   must be fast. Consider: batched drain (process N deferred frees per alloc),
   or epoch-based reclamation.

4. **Arena slab sizing.** Profile total allocation volume per thread per proof.
   Size arenas so < 5% of allocs fall through to the System allocator.

5. **Reduce mmap syscalls.** Large allocs (>2MB) currently mmap every time.
   Add a page cache: retain recently-freed large regions, hand them back on
   next large alloc of similar size. This directly competes with mimalloc's
   segment retention.

Expected iterations: 5–10.

## Comparison targets

| Allocator | Criterion (16GB) | Production (16GB) |
|-----------|-----------------|-------------------|
| glibc | baseline | 50.89s |
| mimalloc | -33% | -24% |
| zk-alloc target | -15% | -10% |

## What not to do

- Do not add pressure adaptation (exp4).
- Do not add phase detection (exp5).
- Do not optimize for 64GB headroom. Only 16GB (cgroup) this experiment.
- Do not modify leanMultisig source code.
