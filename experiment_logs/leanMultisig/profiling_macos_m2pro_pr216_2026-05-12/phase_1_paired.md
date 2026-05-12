# Phase 1 — Paired N=5 main vs PR #216 on macOS M2 Pro

**Host:** Scaleway M2-L (Apple M2 Pro), macOS Sequoia 15.6.1, Darwin 24.6.0 arm64
**Date:** 2026-05-12
**Methodology:** 5 rounds, alternating order, ITERS=5 per binary call, `/usr/bin/time -p`, single `sudo purge` at start.
**Binaries:** `/tmp/prove_loop_main` (d080f3e2) and `/tmp/prove_loop_pr216` (3441e3a9), `RUSTFLAGS=-C target-cpu=native`, `--features zkalloc_global`.

## Raw wall-clocks (N=5 each call)

| Round | Order | main (s) | pr216 (s) | Δ = (pr216 − main)/main |
|:-:|:--|--:|--:|--:|
| 1 | main first  | 16.54 | 15.51 | **−6.23%** |
| 2 | pr216 first | 16.48 | 15.70 | −4.73% |
| 3 | main first  | 16.58 | 15.78 | −4.83% |
| 4 | pr216 first | 16.55 | 15.63 | −5.56% |
| 5 | main first  | 16.50 | 15.86 | −3.88% |

## Aggregates

| Metric | main | pr216 |
|---|--:|--:|
| Mean wall (s)   | 16.530 | 15.696 |
| Stddev (s)      |  0.040 |  0.135 |
| CV              |  0.24% |  0.86% |

**Mean Δ = −5.05% ± 0.89% (sample stddev, n=5).**
Per-round range: −3.88% to −6.23%.

## Comparison to Asahi reference

| | macOS Sequoia M2 Pro (this) | M2 Asahi Linux (ref) |
|---|--:|--:|
| Mean Δ | **−5.05%** | −6.64% |
| Range | −3.88 to −6.23 | −5.59 to −8.81 |
| main wall (5 iters) | 16.53 s | 2.65 s |

Two surprising observations:

1. **macOS Δ is materially smaller (−5.05 vs −6.64%, ≈1.6 pp shallower).** Distributions overlap, but the macOS mean sits below the lower end of the Asahi range. PR #216's leverage is real on macOS, just attenuated.
2. **macOS main wall is ~6.2× slower than Asahi (16.53 s vs 2.65 s for the same N=5 workload).** This is huge and matches no obvious "macOS overhead" model. The most likely explanation is that the Asahi reference number is from a different binary configuration (e.g., the harness's bench crate vs `prove_loop --bin`, or signature-cache pre-warmed) — to be reconciled in Phase 5. If real, it would mean macOS pays an enormous absolute tax on this workload that needs a separate investigation.

## Stop gate

Mean Δ = −5.05% sits **inside** [−12%, −2%]. The Asahi-similarity hypothesis is supported. Proceeding to Phase 2.
