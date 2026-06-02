# Phase 5 — Cross-machine comparison

**Date:** 2026-05-12
**Three hosts compared:** Hetzner AX42-U (AMD Zen 4 + AVX-512), Scaleway M2 Asahi Linux, Scaleway M2-L macOS Sequoia (this run).

## Reference sources

| Host | Source doc | What it measured |
|---|---|---|
| Hetzner Zen 4 | `experiment_logs/leanMultisig/experiment_pw_minmax/program.md` (baseline §); `benchmark_pw3_pr/profiling_main.md` (deep) | prove_loop warm-proof avg, IPC, Poseidon inclusive |
| M2 Asahi Linux | `experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/program.md` (baseline §) | prove_loop warm-proof avg + planned 7-phase profiling stack |
| M2 macOS Sequoia | This experiment, phases 1-4 | prove_loop N=5 paired, sample(1), xctrace, powermetrics |

*Note:* the canonical `profiling_baseline_*_report.md` files referenced in the program prompt do not yet exist in the repo — the experiments produced data but the cross-host synthesis was deferred to this Phase 5. Reference numbers below were pulled from the corresponding baseline `program.md`s, deep-dive doc, and other audit-trail files that contain measured values.

## Headline cross-machine table

| Metric | Hetzner (Zen 4, 8c/16t, AVX-512) | M2 Asahi Linux (6P+4E) | M2 macOS Sequoia (6P+4E) |
|---|--:|--:|--:|
| PR #216 paired Δ (prove_loop) | −5.58% | −6.64% | **−5.05% ± 0.89%** |
| prove_loop warm-proof avg (main) | 2.002 s | 2.5581 s | **2.50 s** (this run) |
| prove_loop warm-proof avg (PR #216) | ≈1.890 s¹ | ≈2.388 s¹ | **2.38 s** |
| Poseidon inclusive cycle share | ≈42% (perf children) | 57.85% (perf children) | **52.5%** (xctrace) / 50.9% (sample(1) self-of-active) |
| `compress_mut` inclusive share | (not isolated) | (not isolated) | **30.3%** |
| IPC (proc-weighted) | 0.91² | 2.93³ weighted (P 3.72 / E 1.87) | not measurable from CLI⁴ |
| P/E heterogeneity tax | n/a (homogeneous SMT) | ~13% | **18.2%** |
| Concurrency (avg active threads) | 8.39 / 16 (52%) | not reported here | **6.95 / 11** (63%) |
| Steady-state CPU power | not reported here | not reported here | **27 W, peak 30.3 W** |

¹ Derived as `main × (1 + Δ)` for ranking purposes; not directly measured per-row.
² Hetzner IPC=0.91 is *low for general code, normal for AVX-512-heavy SIMD* (each instruction does 16× scalar work). The "weighted total" framing differs across PMUs; comparing raw IPC across architectures requires care.
³ Asahi 2.93 weighted IPC is the Apple Avalanche+Blizzard PMU readout reported in the baseline `program.md`.
⁴ macOS does **not** expose Apple-silicon PMU counters from CLI (no `apple_avalanche_pmu` access, no `perf`). Phase 6 explicitly notes this gap.

## Wall-clock reconciliation (the key sanity check)

A naive read of "macOS N=5 = 16.53 s vs Asahi 2.65 s" suggested a 6.2× macOS tax. **That reading was wrong** — 2.65 s was the *per-warm-proof avg* (the same quantity as my N=5/4-incremental calculation). Reconciling on the same metric:

| | Hetzner | Asahi | macOS |
|---|--:|--:|--:|
| warm proof, main | 2.002 s | 2.558 s | **2.50 s** |
| warm proof, PR #216 | 1.890 s | 2.388 s | **2.38 s** |
| relative speed vs Hetzner | 1.00× | 1.28× slower | **1.25× slower** |
| relative speed vs Asahi | 0.78× faster | 1.00× | **0.98× — essentially identical** |

**macOS Sequoia on M2 Pro is effectively the same speed as bare-metal Linux on M2 Asahi for prove_loop** (within 2% — well inside noise). There is *no significant macOS-layer tax*. The Scaleway M2-L (mac-mini-virtualized?) inherits M2 silicon performance cleanly. This is a meaningful finding: the M1 12x regression cited in memory `project_zk_alloc_macos_bug` does **not** reproduce on M2 Pro Sequoia at this scale.

Zen 4 AVX-512 is ~25% faster wall than M2 NEON. The Hetzner-vs-M2 delta is much smaller than the SIMD-width ratio (512/128 = 4×) would predict — strongly suggests **Poseidon is memory-latency bound, not SIMD-throughput bound**, on both platforms.

## Per-machine architecture notes

### Hetzner Zen 4 (AMD Ryzen 7 PRO 8700GE)
- 8 physical cores × 2 SMT = 16 threads, AVX-512 (1× 512-bit FMA per cycle per core)
- DDR5 ECC, 51.2 GB/s peak; this workload hits ~3.98 GB/s LLC-miss bandwidth (~8% of ceiling)
- `perf stat`: 0.91 IPC × 4.04 GHz, 3.57% cache-miss rate
- Memory pressure ≈ 25% of cycles (mid-band assumption)
- Poseidon family ~42% inclusive; remaining is sumcheck ~12%, GKR/MLE ~10%, plumbing

### M2 Asahi Linux (kernel 6.14.2-401.asahi 16k pages)
- 6P (Avalanche, 8-wide decode) + 4E (Blizzard, 3-wide decode); no AVX-512, NEON only
- Apple PMU exposes cycles/instructions/branches per cluster — `apple_avalanche_pmu` / `apple_blizzard_pmu`. No L2/LLC/TLB counters from CLI.
- Cycles per warm proof ≈ 2.56 s × ~3 GHz × 6P × IPC 3.72 = ~170 G P-instructions (rough)
- IPC 2.93 weighted is **3× higher than Zen 4's** because Apple's wide decoders + faster front-end mask memory latency that Zen 4 stalls on
- rayon affinity hooks let workers pin to P-cores → P/E tax ~13%

### M2 macOS Sequoia (this run, Scaleway M2-L)
- Same M2 Pro chip as Asahi target above (Mac14,12), but macOS Sequoia 15.6.1 instead of Linux
- 16 KiB native page (same as Asahi)
- mach-vm syscalls — no MAP_NORESERVE — no problem for zk-alloc at this scale (Phase 0 finding)
- **No CLI PMU access**, profiling via `sample(1)`, `xctrace`, `powermetrics`
- Steady-state 27 W package, all clusters >90% residency
- rayon spreads work uniformly across P/E without affinity (xctrace shows 53.3-53.8% Poseidon-inclusive on every worker) → P/E tax 18.2%, ~5 pp worse than Asahi

## Cross-cutting observations

1. **Poseidon share grows on Apple Silicon.** 42% (Zen 4, AVX-512) → 52% (M2 macOS) → 58% (M2 Asahi). Reason: NEON 128-bit gives the Poseidon round less SIMD parallelism per instruction than AVX-512, so the AIR/sumcheck overhead becomes a *smaller* relative fraction. Same arithmetic, different denominator.
2. **PR #216 delta is portable across all three machines (−5 to −7%).** The RATE 8→12 sponge rebalance is architecture-agnostic, as predicted in this experiment's hypothesis. macOS −5.05% confirms the lower end of the range — the leverage holds.
3. **macOS vs Asahi wall is statistically identical (within 2%) on the same M2 hardware.** No mach-vm penalty, no zk-alloc regression, no allocator-stall hot symbols.
4. **Asahi's rayon affinity advantage shows up as ~5 pp lower P/E heterogeneity tax than macOS.** This is the single largest gap between the two M2 OSes and the most actionable: a macOS `pthread_set_qos_class` or `dispatch_queue_set_target_queue` call to bind rayon workers to the P-cluster would likely recover 3-5% wall on macOS. (Out of scope for this read-only experiment.)
5. **No M1 12x slowdown.** The historical memory `project_zk_alloc_macos_bug` is stale on M2 Pro Sequoia at this scale. The bug was either M1-specific (page-size, TLB-shootdown, smaller arenas) or fixed by intermediate zk-alloc commits.

## Phase 5 takeaways

1. **The macOS path is healthy.** PR #216 delivers −5.05% on production target OS; warm-proof wall is within 2% of bare-metal Asahi Linux on the same silicon.
2. **PR #216 is portable: −5.58% Hetzner / −6.64% Asahi / −5.05% macOS — all in family.** The optimization survives architecture and OS changes.
3. **The macOS-specific opportunity: P-cluster affinity for rayon.** ~5 pp wall recovery on the table, gated only by surfacing a macOS-equivalent of rayon's Linux affinity hooks.
4. **CLI PMU access is the macOS profiling gap.** Future macOS perf work needs `xctrace --template "CPU Counters"` for IPC equivalents, or a small custom kperf wrapper. Worth a separate experiment.
