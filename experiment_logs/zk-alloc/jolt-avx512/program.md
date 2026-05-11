# Jolt AVX-512 deep profile — cross-prover compute-bound validation

## Role

You are a systems performance engineer profiling the [Jolt](https://github.com/a16z/jolt)
zkVM under AVX-512 on a Linux x86_64 host. You understand: `perf stat` counter
selection on Zen 4 PMU, `perf record` + `perf report` cycle attribution,
flamegraph reading, IPC interpretation, distinguishing compute-bound from
memory-bound regimes from counter ratios.

You work autonomously. Real measurement, no analytical deferral. **This is a
single-shot profiling run, not an iterative experiment.** You produce one report
and stop.

## Hardware

Hetzner AX42-U: AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, AVX-512, 64 GiB DDR5,
Linux 4 KiB pages. `perf_event_paranoid=-1` is set (perf works without sudo).
Idle.

## Goal — corroborate that ZK provers on this machine are compute-bound

We have a deep profile of leanMultisig post-PR-216 on this same machine. Headline:

- **IPC = 0.91**
- **Cache-miss rate = 3.57%**
- **LLC bandwidth ~7.8% of DDR5 ceiling** → not memory-bound
- **75% of cycles in `compress_mut` (Poseidon Merkle hash, AVX-512 SIMD body)**
- Verdict: **compute-bound**, latency-dominated by Montgomery multiply chains
  (22-cycle latency × 2 dependent multiplies per S-box).

The question this run answers: **does Jolt on the same machine show a similar
compute-bound regime (IPC ~0.9, low cache miss, single dominant SIMD kernel) on
AVX-512?**

- **If Jolt looks similar** (IPC 0.7-1.1, cache miss <5%, one dominant SIMD
  hot kernel) → cross-prover confirmation that ZK provers on Zen 4 + AVX-512
  hit the same compute-bound regime. Independent corroboration of the
  leanMultisig finding.
- **If Jolt differs** (e.g., IPC > 2 with low cache miss, or IPC < 0.5 with high
  cache miss) → the regime is workload-specific, and our leanMultisig analysis
  doesn't generalize directly to Jolt-style sumcheck/Dory provers.

Either result is shippable evidence. **Allocator is NOT the variable here** —
Jolt's default allocator is fine for this run. Do NOT wire zk-alloc, do NOT
A/B against glibc, that question is already answered for Jolt (~-1-2% regression
on Hetzner, irrelevant for this run).

## Repo

| Repo | Path | HEAD |
|------|------|------|
| Jolt | `~/zk-autoresearch/jolt` | record current HEAD SHA in the report |

## Pre-flight

1. Confirm Jolt builds:
   ```bash
   cd ~/zk-autoresearch/jolt
   git rev-parse HEAD
   RUSTFLAGS="-C target-cpu=native" cargo build --release 2>&1 | tail -3
   ```
   Build failure → log to `build_failure.md`, stop.

2. Identify a representative Jolt prove benchmark — something that:
   - Runs for at least ~5 seconds (so per-prove counters are above noise).
   - Uses Jolt's standard prove path (not a microbench of one component).
   - Has stable wall-clock under repeated runs.

   Use `cargo bench --list` and pick the one the maintainers designate as the
   "prove a real program end-to-end" bench. **`prove` benchmarks in `jolt-core`
   are the canonical target.** If multiple candidates, pick the smallest one
   that still runs ≥5 seconds (faster iteration, same compute-bound regime
   should appear).

   Document your choice + reasoning in §1 of the report.

## Profile method (single-shot, ~3-run median for stability)

For the chosen benchmark, **default allocator only**, run:

### A. `perf stat` for IPC + counter ratios

```bash
cd ~/zk-autoresearch/jolt
perf stat -e task-clock,cycles,instructions,cache-references,cache-misses,branches,branch-misses,page-faults,context-switches,cpu-migrations \
    cargo bench --bench <chosen> -- --profile-time 30 2>&1 | tee /tmp/jolt_perf_stat.log
```

If `cargo bench` doesn't take `--profile-time`, use whatever the bench supports
to get ~30s of measured runtime, OR run the resulting binary directly. The point
is to get clean counter coverage over many seconds of prove work, not warmup.

Compute and report:

- IPC (instructions / cycles)
- Cache-miss rate (cache-misses / cache-references, as %)
- Branch-miss rate
- Estimated DRAM bandwidth via cache-misses × 64 B / wall-time, as % of
  ~50 GB/s DDR5 ceiling
- User vs sys time ratio

### B. `perf record` for cycle attribution

```bash
perf record -F 999 --call-graph dwarf -o /tmp/jolt_perf.data \
    -- cargo bench --bench <chosen> -- --profile-time 30
perf report --stdio --no-children --max-stack=20 -i /tmp/jolt_perf.data \
    | head -100 > /tmp/jolt_perf_report.txt
```

Extract:
- Top 15 hot functions with their %.
- Identify the dominant kernel (analog to `compress_mut`'s 75% in leanMultisig).
- For each hot function: is it pure SIMD compute, or does it touch memory heavily?

### C. (Optional) Flamegraph if `cargo install flamegraph` is available

```bash
cargo flamegraph --bench <chosen> -- --profile-time 30
# produces flamegraph.svg
```

If installed, generate one and reference its location in the report. If not
available, skip — perf report text is enough.

## Output

Write **one** report at:
`experiment_logs/zk-alloc/jolt-avx512/jolt_avx512_profile.md`

### Required sections

1. **Environment + bench choice.** Hardware (record `cat /proc/cpuinfo | head -25`,
   `perf list | head` to confirm PMU events available), Jolt commit SHA,
   benchmark chosen, why.

2. **Compute-vs-memory verdict (mirroring leanMultisig Q1).** IPC + cache-miss
   rate + estimated DRAM bandwidth utilization + verdict. Direct one-line
   comparison: "Jolt: IPC=X, cache-miss=Y%, BW=Z% of ceiling. leanMultisig:
   IPC=0.91, cache-miss=3.57%, BW=7.8%."

3. **Cycle attribution top-15.** Functions and their %. Identify the dominant
   kernel.

4. **Cross-prover comparison table.**

   | Metric | leanMultisig (post-PR-216, this machine) | Jolt (this run) |
   |---|---:|---:|
   | Wall per prove | ~2.06 s | ? |
   | IPC | 0.91 | ? |
   | Cache-miss rate | 3.57% | ? |
   | DRAM BW utilization | 7.8% | ? |
   | Top function (cycle %) | `compress_mut` (75.1%) | ? |

5. **Verdict: corroborated or not?** One paragraph. Explicit answer to "is Jolt
   on Zen 4 + AVX-512 in the same compute-bound regime as leanMultisig?" If yes,
   what mechanism (Montgomery multiply chains? SIMD primitive saturation? other)?
   If no, where does it differ and what does that imply?

6. **One-paragraph TL;DR** at the top of the report (above §1) — the
   too-busy-to-read summary.

## Out of scope

- Allocator A/B against glibc (already done for Jolt, -1-2% regression, not the
  question here).
- M2 portion (different machine, different program).
- Optimizing Jolt code.
- Multiple benchmarks (one is enough; corroboration doesn't need a sweep).
- Iteration. Single-shot. Write the report and stop.

## Stop criterion

Single-shot: write `jolt_avx512_profile.md`, stop.

## Discipline

- `RUSTFLAGS="-C target-cpu=native"` for all builds.
- Don't push to upstream Jolt.
- If a perf counter reports `<not supported>`, omit that row and document.
- Trust measurement over priors. If IPC comes out 4.0 instead of 0.9, report it
  honestly and reason about why — don't fudge the number toward expectation.
