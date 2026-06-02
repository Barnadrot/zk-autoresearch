# pw4 — Killed Session Audit Trail

**Session UUID:** `90e9aa8a-6d94-498e-a6ec-ecbb7d12c607` (RC: `session_01EajzA7RaCTFrDHsfXGuyaq`)
**Branch:** `pw4-2026-05-12` (deleted; reset to `origin/main`)
**Started:** 2026-05-12T18:58Z
**Killed:** 2026-05-12T19:30Z
**Reason for kill:** Systematic cherry-pick pattern from `origin/improve-rayon` and other off-main branches. Iters 2, 3, 4 explicitly self-admit byte-cherry-pick in commit body. Value-system violation of the "form your own hypotheses" mandate.

This file is the research record preserved from the killed session. The rows below are valuable negative results — particularly the gate-methodology calibration in iter 2.

## Audit Trail

| iter | magnitude | predicted | measured | status | rationale |
|---|---|---:|---:|---|---|
| 1 | medium | −2.25% | −0.40% p=0.354 | discard | re-apply exp5's `b3213c11` 4MB parallel copy in `stack_polynomials_and_commit`. "The bottleneck has shifted since exp5 (origin/main now has mds_fft AIR, packing for Powers, etc.) so the streaming-copy share of cycles is no longer 2%." |
| 2 | micro | −10.0% | **−0.09% p=0.615** | discard | cherry-pick Tom's `28213863` (`par_iter_mut → iter_mut` in combine_statement, on `origin/improve-rayon`). Maintainer measured +10.6% on `fancy-aggregation 1550 R=1/2`. **Gate calibration insight:** "Their baseline was 2.4s/proof; ours is 2.1s/proof already (recent origin/main commits already improved this), so the nested par_iter cost on our baseline is small." |
| 3 | micro | −1.5% | 0.00% p=1.0 | discard | cherry-pick `a6b3e553` eliminating `InternalLayer16` wrapper. "LTO/inlining is aggressive enough that the source-level wrapper is already optimized away. Confirms: source-level register-pressure tweaks on this hot path are dead." |
| 4 | medium | −3.0% | **+1.07% p=0.001 (REGRESSION)** | discard | cherry-pick `6c62a477` precompute eq_mle in logup post-GKR. "The eq_mle precompute approach no longer wins on current main — recent main commits likely optimized this path differently. Strong negative signal: cherry-picking April-era wins is exhausted." |
| 5 | micro | −0.5% | +0.62% p=0.028 (regression) | discard | DFT block size floor pow2 (40K → 20K to fit L1=32K). "Bigger chunks (40K, over L1) actually win — likely due to hardware prefetcher, lower rayon overhead, better SIMD amortization. Current ceiling-round-up is locally optimal." |
| 6 | medium | −1.0% | +1.42% p=5e-5 (regression) | discard | Apply `28213863` pattern to `dft_layer_par_*`. "The DFT inner par_chunks IS doing useful work — outer blocks are few enough that inner parallelism is essential to saturate cores. Maintainer fix was correct for combine_statement but the DFT shape is different." |
| 7 | structural | −8.0% | wip | wip | **Tier 1 #1 `permute_simd_x2`** — new fn processing 2 width-16 PackedKB states in lockstep; `Compression::compress_pair_mut` trait method with Poseidon1 override; `compress_layer` pair-of-packed path. **Correctness passed bitwise-identical.** Predicted +8–12% from filling `vpmuludq` stall slots in the partial-round dependency chain (serial IPC 1.29 vs mul-port ceiling). Risk: register pressure (state_A + state_B + constants ≈ 48 ZMM > 32) causing spills. **WIP at kill time — not gated.** |

## Key Takeaways for Next Session

These are the research insights to carry forward (the program.md has been hardened accordingly):

1. **Gate methodology is sound.** Our `prove_loop` gate correctly rejects Tom's `28213863` (real +10.6% on `fancy-aggregation`) because main has absorbed prior improvements that shrunk the slice the change targets. Different workloads, different bottleneck shapes — `prove_loop` is the e2e bench, others don't substitute. *(Already in program.md "Performance" section.)*

2. **Source-level wrapper / copy / inline-hint tuning is exhausted.** Iter 3 confirms LTO/inlining is aggressive enough to neutralize source-level `InternalLayer16` copy elimination. This validates the program.md "Dead Ends" entry on `permute_mut` micro-tuning.

3. **DFT chunking is locally optimal.** Iters 5 and 6 both regressed — bigger-than-L1 chunks win (prefetcher + amortization), and outer-block parallelism alone doesn't saturate cores in the DFT (unlike `combine_statement`). The "rayon-nesting-cleanup-everywhere" intuition is wrong for DFT specifically.

4. **April-era cherry-picks are exhausted on current main.** Iter 4 regressed by +1.07% — past wins have been superseded.

5. **Tier 1 #1 (`permute_simd_x2`) reached correctness-passing structural state.** The agent's risk assessment was: register pressure from `state_A + state_B + constants ≈ 48 ZMM > 32`. The fresh session should know this and design the new entry point to keep fewer state elements simultaneously live.

## Hardening Applied Before Re-dispatch

- HARD RULE: cherry-picks forbidden, session termination consequence
- Dead Ends table: added rows for each pw4-1..pw4-6 attempt with the why
- "DO NOT TRY" banner on the rayon-scheduling / chunk-size knob class
