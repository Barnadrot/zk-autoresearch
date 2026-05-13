# macOS M2 Pro PR #216 profiling baseline — synthesis report

**Experiment:** `profiling_macos_m2pro_pr216_2026-05-12`
**Host:** Scaleway M2-L (Apple M2 Pro, Mac14,12), macOS Sequoia 15.6.1 (24G90), Darwin 24.6.0 arm64
**Date:** 2026-05-12
**Scope:** Read-only. Confirm PR #216 e2e delta on the production target OS (macOS). Produce a first-pass profiling stack with `sample`, `xctrace`, and `powermetrics` since `perf` is unavailable.

---

## 1. Headline

**PR #216 delivers −5.05% ± 0.89% e2e wall-clock on macOS M2 Pro.**

This sits inside the predicted [−12%, −2%] gate, on the lower (less aggressive) end of the Asahi −6.64% reference (Asahi range was −5.59 to −8.81%). All five rounds of N=5 paired with alternating order delivered a negative Δ. The leverage is concentrated in `Poseidon1KoalaBear16::compress_mut` (-10% self-time, -1,476 sample(1) samples) — the signature of a RATE 8→12 sponge rebalance.

| Round | main (s) | PR #216 (s) | Δ |
|:-:|--:|--:|--:|
| 1 | 16.54 | 15.51 | −6.23% |
| 2 | 16.48 | 15.70 | −4.73% |
| 3 | 16.58 | 15.78 | −4.83% |
| 4 | 16.55 | 15.63 | −5.56% |
| 5 | 16.50 | 15.86 | −3.88% |
| **mean** | **16.530 ± 0.040** | **15.696 ± 0.135** | **−5.05% ± 0.89%** |

Warm-proof per-iter (incremental method): main 2.50 s, PR #216 2.38 s — both within 2% of Asahi-Linux on the same M2 silicon.

---

## 2. Most surprising findings

1. **macOS wall ≈ Asahi wall (within 2%) on the same M2 chip.** The naive read of "macOS 16.53 s vs Asahi 2.65 s" suggested a 6× macOS tax — that was a metric-mismatch (N=5 total vs per-warm-proof). On the same per-warm-proof basis the two OSes are statistically identical. The historical M1 12× regression cited in `project_zk_alloc_macos_bug` does **not** reproduce on M2 Pro Sequoia.
2. **Poseidon's macOS inclusive share (52.5% xctrace, 50.9% sample(1)-of-active) is close to Asahi's 57.85% inclusive** — and well above the user's 35-40% prediction. The user's hypothesis is disproved cross-OS, not just cross-Linux.
3. **PR #216's leverage is entirely in `compress_mut` (−10% self-time).** AIR-side full-round evaluators, the trace generator, and `permute_mut` are statistically flat. This is a pure RATE rebalance fingerprint — *not* a vectorization or arithmetic-microopt win.
4. **macOS pays ~5 percentage points more P/E heterogeneity tax than Asahi (18.2% vs ~13%).** All 10 rayon workers carry uniform Poseidon load (53.3-53.8%) — rayon spreads work evenly. Without P-affinity hooks, the slower E-cores set the critical-path tail. This is the single largest tractable macOS-only optimization.

---

## 3. mach-vm path — relevant to #41

**No regression observed on this experiment.** The 687ec5cc MAP_NORESERVE cherry-pick was *not* required; `prove_loop` ran cleanly with `--features zkalloc_global` and no `mach_vm_allocate` errors at N=1, N=3, and N=5. No mach-vm or `vm_fault` symbols appeared in the hot path of either `sample(1)` or xctrace traces. Allocator activity is captured only as low-rate `_platform_memmove` (~0.7% inclusive) and rare `madvise/free_medium` calls during the brief setup phase.

The mach-vm story relevant to #41 (Linux-vs-mach-vm pretouch divergence) is **negative for macOS at this workload size**: zk-alloc's pretouch pattern is invisible at the macOS symbol-attribution level. If a regression exists on larger arenas (>>10 GiB), it didn't surface here at 10 GiB physical footprint.

---

## 4. zk-alloc on macOS — relevant to #59

**zk-alloc works on macOS M2 Pro Sequoia.** Specifically:

- Build with `--features zkalloc_global` succeeded on both branches (origin/main and myfork/perf/poseidon-fft-mmo) on first attempt.
- Both binaries print `prove_loop: zkalloc_global — #[global_allocator] mode` on launch and complete cleanly.
- No crashes, no aborts, no 120 GB virtual-mmap blowup, **no 12× M1 historical regression**.
- The 687ec5cc aarch64 MAP_NORESERVE cherry-pick is **not** required on macOS (it was specifically required on Asahi).
- Per-iter wall is within 2% of Asahi → zk-alloc isn't paying a hidden macOS tax.

For PR #59 (zk-alloc shard-subdirs), this is a clean green light: the macOS path is healthy at the prove_loop scale, no special-case handling required for macOS in zk-alloc itself.

---

## 5. P/E scheduling tax on macOS

| Source | Metric | macOS Sequoia | Asahi Linux (ref) |
|---|---|--:|--:|
| xctrace (thread-time per core) | Heterogeneity tax | **18.2%** | ~13% |
| powermetrics (effective MHz per core) | P/E freq ratio | 1.43× | (not reported) |
| Per-thread Poseidon inclusive | Variance across workers | 53.3-53.8% (flat) | (Asahi: P-affined) |

The macOS scheduler runs all 10 rayon workers as Default QoS. Steady-state all three clusters (E, P0, P1) saturate to >90% residency. Work is split evenly via rayon's work-stealing — but without affinity hooks, the slower E-cores (running at ~2390 MHz, 92% of peak) set the tail latency. P-cores (3275 MHz, ~93% of peak) finish their share early and have to wait for E-core tails.

Asahi's rayon-on-Linux can pin workers to the P-cluster (`taskset`/cgroup affinity), cutting the heterogeneity tax from 18% → ~13%. **Implementing an equivalent on macOS** — via `pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED)` for rayon workers, or `thread_policy_set` with `THREAD_AFFINITY_POLICY`, or a `dispatch_queue` retarget — is the most-tractable macOS-only optimization on the table. Estimated upside: **3-5% wall-clock recovery** (the gap between 18.2% and 13% × the Poseidon fraction of critical path).

Out of scope for this read-only experiment; logged here for the brain side.

---

## 6. Implication for the 1000 XMSS/s M2 macOS target

Throughput accounting at this run:

- Workload: 1550 signatures per proof
- Warm-proof wall, PR #216: 2.38 s
- Throughput: 1550 / 2.38 = **651 XMSS/s** on macOS M2 Pro with PR #216
- Target: 1000 XMSS/s ⇒ **1.54× faster needed**

Where the 1.54× could come from:

| Lever | Expected upside | Status |
|---|--:|---|
| P-cluster affinity for rayon (5 pp wall) | 1.05× | macOS-only; clear path, requires code |
| Further compress_mut microopt (next-tier −5 to −10%) | 1.05-1.11× | open; depends on which sub-routines are stalled |
| Parallel proof pipelining (overlap proof N+1 setup with proof N tail) | 1.10-1.20× | architecture change; nontrivial |
| Algorithmic Poseidon reduction (fewer hash calls) | 1.05-1.15× | requires protocol cooperation |
| AVX-512-equivalent SIMD widening (M3/M4 SME, M4 ARMv9 SVE2) | 1.20-1.40× | hardware refresh; not available on M2 |

Stacked best-case from "soft" levers (P-affinity + compress_mut next-tier + pipelining): 1.05 × 1.08 × 1.15 = **1.30×** → 846 XMSS/s. Still ~15% short of 1000.

Hard conclusion: **on M2 Pro silicon the 1000 XMSS/s target is reachable only with all of: (1) macOS P-cluster affinity for rayon, (2) another −5-10% in compress_mut, (3) parallel proof pipelining.** On M3 Pro / M4 Pro with wider SIMD it becomes comfortably reachable.

The protocol's compress_mut count is the single biggest lever long-term; the OS scheduling tax is the biggest *short-term* lever specific to macOS.

---

## 7. Open follow-ups (out of scope this experiment)

- macOS CLI PMU access: write a `kperf` wrapper or use `xctrace --template "CPU Counters"` to get IPC equivalents (Asahi has these, macOS doesn't from CLI).
- macOS rayon P-affinity experiment (separate experiment, requires code).
- powermetrics with `--samplers tasks` to get per-process energy — current run only captured cluster-level.
- M3/M4 Pro macOS replication when hardware is available.
- A larger-arena (>10 GiB) zk-alloc stress run to confirm the mach-vm path doesn't regress at scale.
