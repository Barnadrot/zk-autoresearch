# Phase 4 — P/E core breakdown via `powermetrics`

**Host:** macOS Sequoia 15.6.1, Darwin 24.6.0 arm64 (Apple M2 Pro, 6P + 4E)
**Date:** 2026-05-12
**Tool:** `sudo powermetrics --samplers cpu_power -i 500 -n 20 --hide-cpu-duty-cycle --show-process-coalition --show-process-energy`
**Window:** 20 × 500 ms = 10 s, sampled during a `prove_loop_pr216 5` run (15.74 s real wall).

`--show-process-coalition` / `--show-process-energy` flags require additional samplers (`tasks` or `coalition`) to emit per-process tables; with just `cpu_power` the report stays at cluster granularity. We still get the headline finding from the cluster-level signals.

## Per-sample cluster utilization & frequency

| sample | E_res | E_freq | P0_res | P0_freq | P1_res | P1_freq | CPU power |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 0  | 60.3% | 1027 | 38.0% | 1994 |  4.3% | 2327 |  0.13 W |
| 1  | 53.3% |  998 | 93.1% | 3275 | 14.2% | 2990 |  5.08 W |
| 2  | 67.2% | 1208 |100.0% | 3492 | 11.1% | 3476 |  5.41 W |
| 3  | 59.6% | 1043 |100.0% | 3490 | 26.0% | 3476 |  6.40 W |
| 4  | 53.6% | 1159 |100.0% | 3498 | 36.5% | 3466 |  6.17 W |
| 5  | 53.3% | 1166 | 86.3% | 3476 | 40.6% | 3453 |  5.69 W |
| 6  | 52.6% |  970 | 19.8% | 3389 | 98.2% | 3494 |  4.64 W |
| 7  | 59.4% | 1359 | 38.0% | 3130 | 99.2% | 3447 |  8.33 W |
| 8  | 91.7% | 2424 | 92.4% | 3272 |100.0% | 3285 | 24.46 W |
| 9  | 94.5% | 2423 | 98.5% | 3274 | 97.8% | 3274 | 24.38 W |
| 10 | 97.1% | 2424 | 99.8% | 3266 | 99.2% | 3267 | 28.68 W |
| 11 | 84.8% | 2228 |100.0% | 3306 | 84.4% | 3295 | 25.76 W |
| 12 | 90.4% | 2409 | 99.0% | 3275 | 99.0% | 3273 | 27.04 W |
| 13 | 88.7% | 2333 | 90.0% | 3280 | 99.1% | 3290 | 22.47 W |
| 14 | 99.6% | 2424 |100.0% | 3264 |100.0% | 3264 | 29.16 W |
| 15 | 96.3% | 2424 | 98.3% | 3269 | 99.5% | 3268 | 29.91 W |
| 16 | 94.7% | 2424 |100.0% | 3272 | 97.2% | 3272 | 30.29 W |
| 17 | 92.9% | 2415 | 99.5% | 3275 | 97.2% | 3274 | 29.94 W |
| 18 | 90.5% | 2312 | 99.5% | 3289 | 91.0% | 3276 | 23.65 W |
| 19 | 98.2% | 2424 | 99.8% | 3267 | 98.8% | 3267 | 28.97 W |

Sample 0 is pre-launch; samples 1-7 capture precompute/ramp; samples 8-19 are steady-state proof execution (12 samples × 500 ms = 6 s).

## Steady-state aggregate (samples 8-19, n=12)

| | E-cluster | P0-cluster | P1-cluster |
|---|--:|--:|--:|
| Active residency | 93.3% | 98.1% | 96.9% |
| HW active frequency | 2389 MHz | 3275 MHz | 3275 MHz |
| Effective frequency × residency | 2229 MHz | 3213 MHz | 3174 MHz |
| Per-cluster ÷ peak | 92.0% of 2424 MHz peak | 91.7% of 3504 MHz peak | 90.6% of 3504 MHz peak |
| Mean cluster power | (not reported individually in this sampler set) | | |
| Mean CPU power, steady-state | **27.0 W** | | |
| Peak CPU power | **30.3 W** (sample 16) | | |

## P/E effective performance ratio per core

Using *effective frequency × residency* as a rough per-core throughput proxy (this ignores IPC differences, so it under-states P-core advantage):

- P-core effective: ≈ 3193 MHz × ~98% utilization
- E-core effective: ≈ 2229 MHz × ~93% utilization
- Frequency ratio per core: **3193 / 2229 = 1.43×**

When you fold in the P-core's wider out-of-order width (6-decode Avalanche vs 4-decode Blizzard) and 2× SIMD throughput, the *real* per-core work ratio is closer to 1.8-2.2× — but that's not directly measurable from cpu_power. The xctrace thread-time ratio of 1.22× per core (Phase 3) is the *observed* work-imbalance signal, which is what matters for the heterogeneity tax.

## P/E heterogeneity tax — final reading

| Source | Metric | macOS M2 Pro | Asahi M2 (ref) |
|---|---|--:|--:|
| xctrace (thread-time per core) | Heterogeneity tax | 18.2% | ~13% |
| powermetrics (effective freq per core) | P/E freq ratio | 1.43× | — |

The macOS scheduler does **not** treat the asymmetric cores asymmetrically *for this workload* — it runs all rayon worker threads as "Default" QoS, all three clusters get saturated to >90% active residency, and E-cores deliver work at their full ~92% peak frequency. Rayon spreads work evenly via work-stealing, but without P-affinity it leaves about 18% imbalance on the table (E-cores fall behind, P-cores wait on slower siblings).

## Power & sustainability

Steady-state 27 W CPU package power is at the top of what an M2 Pro chip will sustain. The first 5 s of the proof show power ramping from ~5 W up to 30 W — the M2 Pro thermal headroom is *just enough* for this workload (no down-clocking observed; max P-cluster freq held at 3275-3306 MHz consistently). On a passive-cooled Mac (MacBook Air-class), this workload would likely throttle within seconds.

This is relevant for the 1000 XMSS/s M2 macOS target — production Macs with active cooling (MacBook Pro, Mac mini) will hold the 16 s × 5-iter wall observed here; fanless Macs will not.

## Phase 4 takeaways

1. **All three clusters (E, P0, P1) saturate to >90% residency in steady state.** No idle silicon — the workload fully uses the chip.
2. **P-cores run at 3275 MHz (≈93% of 3504 MHz peak), E-cores at 2389 MHz (≈99% of 2424 MHz peak).** No frequency throttling on this short workload.
3. **CPU power 27 W steady, 30.3 W peak — at the upper edge of M2 Pro sustained envelope.** Longer or warmer runs may throttle.
4. **Heterogeneity tax 18.2%** confirmed by xctrace; powermetrics shows the underlying freq disparity (1.43×) that rayon's work-stealing partially mitigates.
5. **No process-energy breakdown emitted by `cpu_power` sampler alone** — to capture per-process energy on this OS version, add `--samplers tasks` (deferred, not blocking).
