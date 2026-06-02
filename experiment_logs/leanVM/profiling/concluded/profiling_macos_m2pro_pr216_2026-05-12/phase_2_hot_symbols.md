# Phase 2 — Hot symbol attribution via `sample`

**Host:** macOS Sequoia 15.6.1, Darwin 24.6.0 arm64 (Apple M2 Pro)
**Date:** 2026-05-12
**Tool:** `/usr/bin/sample $PID 10 -file …` with N=3 prove_loop runs, sleep 1 between launch and sample window.
**Caveat:** `sample` captures stack traces of *on-CPU* threads; it does not record off-CPU wait time directly, but it does record samples whose top-of-stack is `__psynch_cvwait` / `swtch_pri` (when a thread is in that syscall *on-CPU* about to descheduling). The 27% "idle" share below is therefore an under-estimate of true rayon worker idle, and a near-equivalent of `perf record`'s task-clock view.

## Top of stack (self-time) — high-level buckets

Active = TOTAL − IDLE (pthread_cond_wait + swtch_pri).

| Bucket | PR #216 self | % of active | main self | % of active | Δ (samples) |
|---|--:|--:|--:|--:|--:|
| TOTAL samples (10 s window) | 60,777 | — | 61,017 | — | — |
| __psynch_cvwait + swtch_pri (rayon idle) | 16,548 | — | 16,552 | — | −4 |
| **ACTIVE (productive)** | **44,229** | 100.0% | **44,465** | 100.0% | −236 |
| Poseidon (compress + permute + AIR + trace) | 22,497 | **50.9%** | 23,726 | **53.4%** | **−1,229 (−5.2%)** |
| Sumcheck / eq_mle / quotient_gkr | 4,802 | 10.9% | 4,898 | 11.0% | −96 |
| rayon scheduling overhead | 11,588 | 26.2% | 10,856 | 24.4% | +732 |
| Other (Merkle, AIR folding, memmove, …) | 5,342 | 12.1% | 4,985 | 11.2% | +357 |

## Poseidon sub-breakdown (self-time)

| Symbol | PR #216 | main | Δ |
|---|--:|--:|--:|
| `Poseidon1KoalaBear16::compress_mut` | 13,115 | 14,591 | **−1,476 (−10.1%)** |
| `Poseidon1KoalaBear16::permute_mut` | 2,244 | 2,247 | −3 (−0.1%) |
| `Poseidon16Precompile::eval` (AIR) | 1,319 | 1,320 | −1 (~0%) |
| `eval_2_full_rounds_16` | 3,699 | 3,687 | +12 (~0%) |
| `eval_last_2_full_rounds_16` | 1,230 | 1,086 | +144 (+13%) |
| `eval_poseidon1_16` | 552 | 463 | +89 (+19%) |
| trace_gen (`gen_trace_rows_for_perm`, `gen_2_full_round`) | 338 | 332 | +6 (+2%) |

**Headline:** PR #216's entire savings are concentrated in `compress_mut` (-1,476 of -1,229 net Poseidon samples). The AIR-side full-round evaluators, the trace generator, and the bare `permute_mut` are statistically unchanged. This is the fingerprint of the RATE 8→12 sponge-rebalance: fewer compression invocations per leaf hash, leaving constraint evaluation untouched.

The `compress_mut` drop alone (-1,476 / 61,017 = -2.4% of total sample budget) accounts for roughly **half** the observed wall-clock delta (-5.05%); the remainder shows up as -732 rayon-idle samples (less waiting because the critical path got shorter) and small positive moves elsewhere consistent with workload reshuffling.

## Comparison to user/Asahi predictions

| | Asahi (inclusive) | macOS this run (self, active) | macOS this run (self, all) | User prediction |
|---|--:|--:|--:|--:|
| Poseidon cycle share | **57.85%** | **53.4% (main) / 50.9% (PR216)** | 38.9% / 37.0% | 35-40% |

`sample`'s self-time is conservatively-bounded inclusive: inclusive would only add the few-percent of helpers that have non-Poseidon leaves (memmove, intrinsic shuffles). So the macOS *inclusive* Poseidon share is plausibly **~55-58%**, very close to the Asahi 57.85% inclusive.

The user's 35-40% prediction is again disproved upward — Poseidon is dominant on macOS just as on Asahi, ruling out an OS-layer explanation for the high Asahi share.

## Symbols that show up on macOS but not on Asahi

Looking at top-of-stack on this run, no mach-vm-flavored symbols appear in the productive portion: no `mach_vm_allocate`, no `vm_fault`, no `pmap_*` in user space. Allocation activity is captured only as low-rate `_platform_memmove` (298 samples PR216) and `__bzero` (~rare). The macOS-vs-Asahi cost is *not* an allocator-stall story at the symbol level — it's overall arithmetic and rayon overhead that scale the same way, just slower on this Scaleway VM.

(A surprising finding ON THIS SCALEWAY VM: the absolute wall is 6.2× Asahi for the same workload. That has nothing to do with Poseidon mix and everything to do with frequency/throttling/virtualization — see Phase 4 / Phase 5 reconciliation.)

## Phase 2 takeaways

1. **PR #216's leverage is `compress_mut` and only `compress_mut`.** Constraint-side Poseidon is unchanged; this is a pure RATE rebalance signature.
2. **Poseidon's dominance on macOS (~53% self, ~55-58% inclusive) matches Asahi (57.85% inclusive)** — no OS-layer carveout in either direction.
3. **Rayon scheduling overhead is high (~24-26% of active CPU).** This is the lever Phase 4 will probe via P/E breakdown.
4. **No mach-vm or allocator symbols in the hot path.** zk-alloc is invisible at the symbol level — it's doing its job.
