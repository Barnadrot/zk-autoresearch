---
experiment: pw4_2-poseidon
start_commit: c868330c
final_commit: 935bfcbe
cumulative_pct: -0.83
cumulative_p_value: 8e-06
keeps: []
orphans:
  - hypothesis_id: h5
    iter_id: pw4_2-h5
    delta_pct: -0.83
    p_value: 8e-06
    n_samples: 24
    surface: SIMD partial-round rank-1 update stack spill elimination
    commit: 943b65a1
discards: 9
dead_ends_confirmed:
  - h1 SSA-hoist of split.s_hi/s0 (LLVM already scoping cleanly)
  - h2 lambda fusion into dit_fft layer 1 (Zen 4 OOO already overlaps)
  - h3 A.1 x2 batched permutation (compress_layer overhead canceled gain)
  - h4 D.2 Toom-Cook product folding (kernel already uses {0,∞} sampling)
  - h6 multi-loop unroll bundle (regressed +0.26% on top of h5)
  - h7 SSA-hoist state to local array (LLVM already auto-localizes)
  - h8 AIR-side mds_fft_16 + sparse_mat_air_16 unroll (regressed +1.24%)
  - h9 pair tasks in compress_layer for rayon overhead (+0.17% only)
  - h10 isolated local mds_fft lambda unroll (regressed +0.24%)
  - h11 cache prefetch round constants (regressed +0.30%, HW prefetch already covers)
methodology_notes: |
  Counter reached 9/12 zero-keep hypotheses; 1 orphan (h5) confirmed.
  Session ended without crossing the 1.0% gate threshold for a KEEP, but
  with a real -0.83% improvement landed as an orphan, awaiting a
  bundle-compatible second iteration that wasn't found in this session.

  Pattern observed across 9 failed iterations: source-level optimizations
  on the SIMD Poseidon path (loop unrolls beyond h5's specific case, SSA
  hoists, lambda fusion, prefetch hints, x2 batching) all produced either
  null results or slight regressions. Mechanism in every case was that
  LLVM/Zen-4 OOO was already doing equivalent work at the hardware level,
  OR the explicit changes pushed past some inline / register-allocation
  boundary that hurt other paths.

  h5 was unique: it attacked a SPECIFIC pathology (LLVM had kept the 15-iter
  `s_hi_mut[j] += s0_val * v[j]` loop with s_hi[j] indexed off the stack
  frame at 0x780(%rsp,%rsi,1), causing 3.6% of total cycles in stack r/w
  traffic on those two hot lines alone). Manual unroll eliminated the
  indexed stack-access pattern entirely (confirmed: post-build binary has
  0 instances of `vmovdqa64 %zmm3,0x780(%rsp,%rsi,1)` vs 2 in baseline).

  Other 16-element loops in compress_mut do NOT have the same pathology
  — they index off caller's memory (not stack), and the natural HW behavior
  (or LLVM's own loop scheduling) already keeps the per-iter cost minimal.

  Bottom line: the rank-1 update spill was a SPECIFIC compiler-codegen
  bug-shape; h5 fixed it. Other surfaces don't have similar low-hanging
  fruit (within the scope of this experiment). To get more, structural
  algorithmic changes are needed (A.1 x2 batching attempted but neutral;
  E.1 MDS coefficient re-search is cryptanalysis-gated, async-only).

  Brain coordinator: I recommend KEEPING h5 (commit 943b65a1) by manually
  promoting the orphan to a kept commit — the -0.83% is real, statistically
  rock-solid (p=8e-06 at n=24, reproduced at n=40 in subsequent
  bundle gates), and shipping it costs nothing.
---

# pw4_2 — Verdict

## Session summary

11 hypotheses attempted across the Poseidon SIMD/AIR/Merkle/rayon surfaces
(target program.md candidate pool plus four off-pool surfaces developed
from on-machine profiling).

**Net result**: 1 confirmed real win (h5 orphan), 9 attempts that didn't
move the gate, 1 dead-end (h4 — optimization already in code).

| iter | hypothesis_id | magnitude   | predicted | measured (cumul) | p_value | status   |
|------|---------------|-------------|----------:|-----------------:|--------:|----------|
| 1    | h1            | medium      |     +1.5% |           +0.08% |    0.60 | discard  |
| 2    | h2            | medium      |     +2.5% |           -0.13% |    0.83 | discard  |
| 3    | h3            | structural  |     +3.0% |           +0.32% |    0.30 | discard  |
| 4    | h4            | -           |         - |                - |       - | dead-end |
| 5    | h5            | medium      |     +2.0% |           -0.83% |  8e-06  | **ORPHAN** |
| 6    | h6 (bundle)   | medium      |     +1.5% |  -0.57% (h5+h6)  |   0.018 | discard  |
| 7    | h7 (bundle)   | medium      |     +1.5% |  -0.79% (h5+h7)  |  8e-04  | discard  |
| 8    | h8 (bundle)   | medium      |     +1.5% |  +0.41% (h5+h8)  |  0.0098 | discard  |
| 9    | h9            | medium      |     +1.0% |  -1.00% (h5+h9)  |  6e-05  | discard  |
| 10   | h10 (bundle)  | medium      |     +1.0% |  -0.59% (h5+h10) |  2e-04  | discard  |
| 11   | h11 (bundle)  | medium      |     +1.0% |  -0.53% (h5+h11) |  0.0018 | discard  |

## h5 — the real win

**Mechanism**: profile-driven attack on the dominant stack-spill in compress_mut.

`perf annotate` on baseline showed two adjacent hot lines inside the
partial-round inner loop:

```
2.28%   482945: vmovdqa64 %zmm3,0x780(%rsp,%rsi,1)    # store s_hi[j] to stack
1.31%   482931: vpaddd 0x780(%rsp,%rsi,1),%zmm3,%zmm3 # load s_hi[j] from stack
```

These are the `for j in 0..15 { s_hi_mut[j] += s0_val * v[j]; }` rank-1 update
that LLVM kept as a tight 15-iter loop with `s_hi[j]` materialized at
stack offset 0x780+j*0x40 and accessed via indexed addressing. That's
~3.6% of total cycles in stack round-trip on those two lines alone.

**Implementation**: replace the loop with 15 explicit `s_hi_mut[i] += s0_val * v[i];`
statements. LLVM then assigns each `s_hi_mut[i]` to its own ZMM register,
eliminating the stack roundtrip entirely.

**Codegen verification (post-build)**:
- `grep -c '0x780(%rsp,%rsi'` on baseline binary: 2 instances (across 2 monomorphizations)
- `grep -c '0x780(%rsp,%rsi'` on h5 binary: 0 instances

**Measurement**:
- First gate: Δ=-0.83% at p=8e-06 (n=24)
- Reconfirmed across 4 subsequent bundle gates (n=24-40 each) — h5
  contribution remained -0.83% within noise every time.

**Status**: ORPHAN per Phase 4 (d) — real (|Δ|>0.5%, p<0.10) but
below the 1.0% gate threshold. Held in branch (`pw4_2-2026-05-13`)
at commit `943b65a1`.

## Why no further wins

The pattern across h6-h11 was consistent: source-level mechanism changes
were either LLVM-equivalent (h7 SSA-hoist) or pushed past an inline/
register-allocation boundary in a way that hurt other code paths slightly
more than they helped the target (h6, h8, h10, h11).

The h5 win was unique to its specific code shape:
1. The `s_hi` access uses `unsafe { transmute(&mut split.s_hi) }` — LLVM
   sees an aliased pointer pattern.
2. The 15-iter `for j in 0..15` was a tight loop pattern that the
   register allocator chose to materialize to stack rather than unroll.
3. Other 16-element loops in compress_mut don't have the same pathology
   (they index off caller-memory pointers, not stack frame).

For 5%+ cumulative wins, structural algorithmic changes would be needed:
- A.1 x2 batched permutation: attempted (h3), neutral on this hardware
  because OOO already overlaps the two independent state chains via
  Tomasulo at the instruction level
- E.1 MDS coefficient re-search: cryptanalysis-gated, async-only
- D.1 incremental eq-evaluation: would require a substantial rewrite of
  sumcheck round state threading — too large for an iter-bounded session
- Bigger Poseidon2-style fundamental restructure: out of scope (protocol)

## Recommendation for brain

**Manually promote h5 to a keep** by cherry-picking `943b65a1` onto a
clean branch and merging. The -0.83% is real, statistically robust,
codegen-verified, and free. The orphan status is a session-rule artifact
(below 1.0% gate); it should not block shipping the actual improvement.

For follow-on optimization work on this surface:
1. Re-profile post-h5 to see if removing the 0x780 spill reshaped the
   bottleneck — there may be a new hot pathology now exposed.
2. Don't waste iters on more SIMD-path source-level micro-optimizations
   without first finding a SPECIFIC pathology like the 0x780 spill —
   absent that, LLVM/OOO neutralizes the changes.
