# Sonnet 4.6 vs Opus 4.6 — Performance Comparison

**Experiment:** Plonky3 NTT `coset_lde_batch`, BabyBear 2^20 × 256, `Radix2DitParallel`  
**Scope:** `monty-31/src/x86_64_avx512/` (Sonnet) / `dft/src/` primary (Opus)

---

## Run Summary

| Metric | Sonnet 4.6 | Opus 4.6 |
|---|---|---|
| Iterations | 11 | 12 |
| Keeps | 1 | 1 |
| In-session improvement | +0.86%, p=0.02 (iter 1) | +0.94%, p=0.01 (iter 1) |
| Cross-session validation | −1.59% [−2.01%, −1.14%], p=0.00 | not yet run |
| PR status | **Changes requested** — not merged | not submitted |
| Total cost (real) | ~$72.57 | ~$262.13 (at $5/$25/MTok) |
| Avg cost/iter | ~$6.60 | ~$21.84 |

---

## Sonnet Finding — Port Pressure (Status: Under Review, Contested)

### What was found

Sonnet iter 1 replaced `vpminud` (port 0 only) with `vpcmpgeud`/`vpcmpltud` (port 5) + masked
add/sub in `PackedMontyField31AVX512` Add and Sub. Hypothesis: `mul`'s underflow correction
occupies port 0; moving Add/Sub corrections to port 5 reduces contention.

- In-session: +0.86%, p=0.02
- Cross-session: −1.59% [−2.01%, −1.14%], p=0.00

### Plonky3 team review — key objections (nbgl)

**1. Wrong microarchitecture.** The benchmark ran on AMD EPYC (Hetzner CCX33). AMD does not
have Intel's port 0/port 5 execution unit layout. The port pressure argument is Intel-specific
and does not apply to the machine the benchmarks were run on.

**2. Latency regression.** `vpcmpud` has latency 3 vs `vpminud` latency 1:
- Add: 3 → 5 cycles latency
- Sub: 3 → 4 cycles latency

The PR increases latency without a clear throughput benefit on the target hardware.

**3. Port 0 may not be the bottleneck.** Per nbgl's analysis, the butterfly loop has enough
"port 0 or 5" flexible instructions to keep both ports busy regardless. Port 0 saturation is
at best plausible, not demonstrated.

**4. No empirical support across workloads.** SyxtonPrime's independent testing showed a mix
of tiny improvements, no change, and occasional small slowdowns — consistent with noise.
nbgl requested benchmarks across wider workloads and microarchitectures before reconsideration.

### Conclusion on Sonnet finding

The cross-session −1.59% result is likely an AMD-specific effect unrelated to port pressure,
or noise. The theoretical mechanism was incorrect for the hardware used. The PR is not merged
and the finding should not be treated as a confirmed improvement until re-benchmarked on Intel
hardware with a valid port pressure analysis.

---

## Opus Finding — 2-Layer Butterfly Fusion (Status: Not submitted)

Opus iter 1 fused butterfly layers 0 and 1 in `first_half_general` and `first_half_general_oop`
into a single memory pass, processing 4 consecutive rows in registers before writing back.
Eliminates one full-matrix read+write pass per coset DFT invocation.

- In-session: +0.94%, p=0.01
- Not cross-session validated, not submitted to Plonky3

---

## What Each Model Explored After Iter 1

### Sonnet (iters 2–11)
All regressions: sign-bit Sub detection (−1.45%), `scale_applied` branch peel (−0.56%),
`backwards` bool removal (−3.88%, −1.72%), `reserve_exact` reordering (−1.57%).
Several iterations lost to API errors or forbidden-pattern gates.

### Opus (iters 2–12)
All regressions: 3-layer fusion (−0.38%), second_half fusion (−1.89%), inverse DFT fusion
(−1.84%), batched OOP cosets (−2.84%), `vpminud → vpcmpud` port pressure (−2.00%),
`chunks_exact` (−1.36%), `backwards` removal (−1.26%), twiddle precompute (−1.81%, −1.92%).

---

## Reasoning Quality: What the Eliminated Ideas File Shows

Opus's `eliminated_ideas.md` entries across 12 iterations show hardware-level reasoning
Sonnet did not produce:

- Cycle-count arithmetic: "per-group compute (416 cyc) comparable to memory time (492 cyc);
  adding a 5th mul (520 cyc) would regress" (Exp 6)
- Register pressure: "16 rows = 28 ZMM registers of 32 available" (Exp 7)
- Port assignment: "`movehdup_epi32` on broadcast constant runs on port 5, not bottleneck
  port 0" (Exp 5)
- Self-correction: caught mathematical error on bit-reversal decomposition, corrected next iter

**Critical gap:** Opus analyzed arithmetic *count* in monty (can we do fewer muls?) but never
analyzed port *competition* (are existing instructions competing for the same port?). The
`vpminud` port pressure idea — the one Sonnet found — is absent from Opus's eliminated_ideas
entirely. When Opus did attempt it in iter 6, it used `vpcmpud` (a different variant) and
regressed −2.00%.

---

## Why Similar Outcomes

1. **Different search directions from iter 1.** Sonnet targeted monty arithmetic, Opus targeted
   DFT layer structure. Both found 1 improvement. Neither effectively explored the other's
   direction afterward.

2. **Both findings are uncertain.** Sonnet's port pressure result is contested by the Plonky3
   team (wrong µarch, latency regression). Opus's layer fusion has not been cross-session
   validated. Neither is a confirmed shipped improvement.

3. **Cost efficiency favors Sonnet** at 3.3× lower cost/iter with comparable hit rate for
   this experiment.

---

## Proposed Next Step: Opus on Monty-31 Scope Only

Given the above, the most productive next experiment is a **short, targeted Opus run** on
`monty-31/src/x86_64_avx512/` exclusively, with two explicit changes to the setup:

**1. Correct the µarch framing.** CLAUDE.md must state that the benchmark machine is AMD EPYC
(not Intel). Port pressure arguments must be validated for AMD's execution unit layout, not
Intel's. The `get_assembly` tool should be used to verify actual instruction selection, and any
port analysis must reference AMD's µarch documentation.

**2. Focus on what Opus missed.** The eliminated_ideas file shows Opus never considered:
- AMD-specific execution unit pressure in Add/Sub
- Alternative reduction sequences in `partial_monty_red_*`
- `mul_neg_2exp_neg_n_avx512` / `halve_avx512` substitutions where mul is overkill

**Suggested run parameters:**
- `--max-iter 10 --dry-spell 5`
- Cost cap: ~$100-150 (5-7 iters at ~$20/iter)
- Stop early if iter 1-2 show no monty engagement

This is the cleanest remaining experiment: same infra, targeted scope, model that has
demonstrated deeper hardware reasoning, and a search space that has not been properly explored.

---

## Cost Summary

| Run | Model | Iters | Keeps | Cost (real) | PR status |
|---|---|---|---|---|---|
| experiment_2_monty | Sonnet 4.6 | 11 | 1 | $72.57 | Changes requested, not merged |
| Opus run | Opus 4.6 | 12 | 1 | $262.13 | Not submitted |
| **Combined** | | **23** | **2** | **$334.70** | |

> Note: Opus `cost_usd` in `experiments_opus.jsonl` is 3× overstated — used $15/$75/MTok
> (Opus 4.1 pricing) instead of $5/$25/MTok (Opus 4.6). Costs above recomputed from tokens.

Jonathan's budget used: $262.13. Remaining: ~$237.87.
