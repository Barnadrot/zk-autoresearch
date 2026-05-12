# Phase 3 — Time Profiler via xctrace

**Host:** macOS Sequoia 15.6.1, Darwin 24.6.0 arm64 (Apple M2 Pro)
**Date:** 2026-05-12
**Tool:** `xcrun xctrace record --template "Time Profiler" --launch /tmp/prove_loop_pr216 -- 5`
**Trace:** `phase_3_time_profiler.trace` (8.8 MB) → XML export `phase_3_time_profiler.xml` (80 MB, 113,768 sample rows).
**Wall:** 16.376 s, including dyld bootstrap + precompute + 5 proofs.
**Parser:** `parse_xctrace.py` resolves xctrace's frame-deduplication (`<frame ref="N"/>` references) before bucketing — this was non-obvious and a first naive read was off by 6× before the fix.

## Sampling weight

Each row = 1 ms of *Running*-state thread time (xctrace's Time Profiler discards waiting threads). Sum of rows ÷ wall = average concurrent threads.

Total: 113,768 ms of thread time over 16.376 s wall ⇒ average 6.95 threads concurrently active (out of 11 = 1 main + 10 rayon workers).

## P-core vs E-core breakdown

| | rows (ms) | per-core | share |
|---|--:|--:|--:|
| P-core (6 × Avalanche) | 73,610 | 12,268 ms | 64.7% |
| E-core (4 × Blizzard)  | 40,158 | 10,040 ms | 35.3% |

**P/E thread-time ratio per core: 1.22× ⇒ heterogeneity tax = 18.2%.**

Reading: each P-core delivered 22% more thread-ms than each E-core over the 16.4 s wall. On a perfectly homogeneous machine, ratio would be 1.00. On Asahi Linux for the same workload the reported tax was ~13% — *macOS leaves ~5 percentage points more work-imbalance on the table* than Linux did on the same silicon, consistent with macOS lacking rayon's affinity hooks. (The E-cores aren't idle — they're just running ~18% slower per unit time, mostly because they're physically half-width Blizzards, not because they're being scheduled out.)

## Inclusive bucket share (any frame in stack matches)

| Bucket | rows | share |
|---|--:|--:|
| poseidon (compress + permute + AIR + trace_gen)  | 59,673 | **52.5%** |
| ↳ `compress_mut` only                            | 34,468 | 30.3% |
| ↳ `permute_mut` only                             |  4,011 |  3.5% |
| sumcheck / eq_mle / quotient_gkr                 | 13,287 | 11.7% |
| rayon scheduling frames anywhere on stack        |109,694 | 96.4% |
| __psynch_cvwait / swtch_pri (kernel wait)        |  2,209 |  1.9% |
| _platform_memmove / memcpy                       |    805 |  0.7% |
| madvise / malloc / RawVec resize                 |    645 |  0.6% |

Note: the rayon bucket is 96.4% because every rayon worker thread's stack has rayon frames somewhere — that's a containment indicator, not a "rayon-bound" indicator. The Poseidon 52.5% is the real attribution and matches sample(1)'s 50.9%-of-active independently — two methods converge.

## Per-thread Poseidon inclusive share

All 10 rayon workers: **53.3 - 53.8%** Poseidon-inclusive. They are essentially identical — rayon is splitting Poseidon work uniformly across workers, both P and E. Main thread: 22.7% Poseidon (it dispatches and waits).

This homogeneity across threads is informative: **rayon is NOT preferentially placing Poseidon on P-cores.** On Asahi the user found rayon affinity could pin work to P-cores; on macOS without those hooks, work spreads uniformly, and the slower per-core E-core delivery is the cost.

## Comparison to Asahi reference (Phase 5 will widen this)

| Metric | Asahi Linux M2 (ref) | macOS Sequoia M2 (this) |
|---|--:|--:|
| Poseidon inclusive share | 57.85% | **52.5%** |
| `compress_mut` inclusive  | (not reported separately) | 30.3% |
| P/E heterogeneity tax    | ~13%   | **18.2%** |
| Avg concurrent threads   | (not reported) | 6.95 / 10 workers |

macOS Poseidon share is slightly lower than Asahi (52.5 vs 57.85). The most likely reasons:
1. xctrace excludes waiting threads → denominator already-narrowed → 52.5% is on the *Running* base, whereas Asahi 57.85% was on a comparable perf base. The gap is small either way.
2. PR #216 itself reduces Poseidon's share (Phase 2 shows main → PR216 drops from 53.4% → 50.9% in sample(1) self). This trace was on PR216.

If anything, the macOS PR216 number (52.5%) is **above** the macOS PR216 sample(1) self (50.9%) by ~1.6 pp — consistent with inclusive being slightly higher than self (helper leaves like memmove that get reattributed up). Cross-tool agreement.

## Data sources

- `phase_3_time_profiler.trace` — Instruments trace (re-openable with `open` to inspect interactively).
- `phase_3_time_profiler.xml` — flat XML export of the time-profile table (80 MB).
- `phase_3_xctrace_summary.txt` — `parse_xctrace.py` output (this report's source data).
- `parse_xctrace.py` — frame-ref-resolving parser; reusable for future runs.

## Phase 3 takeaways

1. **Poseidon inclusive = 52.5% on macOS, confirmed independently via sample(1) (50.9%-of-active).** The user's 35-40% prediction is *not* validated on macOS either — Poseidon is dominant on both OSes.
2. **P/E heterogeneity tax = 18.2% on macOS**, vs ~13% on Asahi. macOS's lack of rayon affinity hooks costs ~5 percentage points of work-imbalance on the same M2 silicon.
3. **All 10 rayon workers carry equal Poseidon load (53.3-53.8%).** No scheduler-side specialization happens by default on macOS.
4. **`compress_mut` alone = 30.3% inclusive.** It is the single largest leaf in the proof. PR #216's compress_mut self-time reduction of −10% (Phase 2) maps cleanly to a wall-clock improvement of −3 pp out of the observed −5.05% delta — the rest comes from less rayon-blocking and less memory churn downstream.
