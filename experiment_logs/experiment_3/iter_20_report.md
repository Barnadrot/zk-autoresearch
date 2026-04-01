# Experiment 3 — Iter 20 Report

## Results Summary

| Iter | Outcome | Δ% | Score | Idea |
|------|---------|----|-------|------|
| 01 | REVERT | -1.36% | 2701.80ms | Pre-broadcast apply_to_rows to DifButterfly (non-hot-path) |
| 02 | REVERT | -0.22% | 2655.30ms | apply_to_rows override to TwiddleFreeButterfly |
| 03 | REVERT | -0.17% | 2654.00ms | Load *x_1 into local before *x_2 * twiddle |
| 04 | REVERT | -0.02% | 2650.00ms | apply_to_rows_oop to ScaledDitButterfly |
| 05 | REVERT | -3.23% | 2735.10ms | apply_to_rows_oop to TwiddleFreeButterfly |
| 06 | REVERT | -0.22% | 2698.90ms | chunks(2) → chunks_exact(2) |
| 07 | REVERT | -0.10% | 2695.70ms | dit_layer_oop_uniform_twiddle |
| **08** | **KEPT** | **+0.56%** | **2677.90ms** | chunks(2) → step_by(2) zip iterators |
| 09 | FORBIDDEN | — | — | First-two-layers fusion (debug_assert gate) |
| 10 | REVERT | -0.74% | 2697.60ms | ALU instruction reordering in dit_layer_rev_last2* |
| 11 | THRESHOLD | +0.11% | 2662.80ms | (no IDEA line — hit max_tokens) |
| 12 | REVERT | -0.15% | 2669.80ms | First-two-layers fusion (clean retry, cache pressure) |
| 13 | REVERT | -0.18% | 2670.60ms | Slice twiddles1[..n_blocks] in dit_layer_rev_last2* |
| 14 | REVERT | -0.78% | 2686.70ms | Replace step_by(2) with raw pointer iterators |
| 15 | TESTS_FAILED | — | — | Replace outer loop in dit_layer_rev_last2 with parallel |
| **16** | **KEPT** | **+1.40%** | **2628.40ms** | Remove backwards flag from second_half_general |
| 17 | REVERT | -1.64% | 2671.50ms | Extend backwards flag removal to second_half + first_half_general |
| 18 | REVERT | -1.87% | 2677.60ms | Backwards flag removal from second_half general layers loop |
| 19 | REVERT | -1.54% | 2668.80ms | Peel first iteration (layer==mid) from second_half_general |
| 20 | REVERT | -0.90% | 2652.00ms | Backwards flag removal from first_half_general |

**Baseline:** 2665.60ms | **Best:** 2628.40ms | **Exp 3 gain: +1.40%**

---

## Cost & Token Stats

| Metric | Value |
|--------|-------|
| Total cost | $44.80 |
| Avg cost/iter | $2.24 |
| Avg input tokens | 552,475 |
| Avg output tokens | 38,835 |
| Avg agent time | 601s (~10 min/iter) |

Token usage is high — avg 552k input tokens. Trimming CLAUDE.md and removing agent_thinking (implemented mid-run) should reduce this for the next run.

---

## Key Observations

### 1. Two genuine improvements, both from unexpected directions
- **Iter 8** (+0.56%): step_by(2) zip — compiler codegen difference vs chunks(2) confirmed via assembly tool
- **Iter 16** (+1.40%): backwards flag removal — largest single gain, found after exhausting the promising ideas list without any CLAUDE.md hint

Iter 16 is notable: the backwards flag was considered a structural feature, not a performance knob. The agent found it independently through fresh exploration.

### 2. Extension fixation after iter 16
Iters 17-20 all attempt to extend the backwards flag removal to other code paths. All regressed. The agent spent 4 consecutive iters on one dead idea family after a success. The prompt's extension nudge ("look for symmetric paths, adjacent layers") is actively causing this.

**Action required:** Remove extension nudge. Add cooldown rule: max 1 extension attempt per idea before moving on.

### 3. Promising ideas list exhausted
- ALU dependency reordering (iter 10): flat — LLVM already handles scheduling
- First-two-layers fusion (iters 9 + 12): cache pressure killed it on clean retry
- step_by(2) direct pointer (iter 14): regression vs the kept step_by(2) zip

Only baby-bear field specialization remains genuinely unexplored. CLAUDE.md promising ideas section needs pruning.

### 4. Infrastructure working correctly
- Forbidden pattern gate caught debug_assert (iter 9) — clean retry confirmed the gate was right
- Assembly tool used every run — no longer reasoning blind about compiler behavior
- Recovery prompt continued in-progress ideas (iters 10-11)
- Overload retry (status=200 mid-stream) caught correctly after fix
- Iter 15 tests failed cleanly — parallel outer loop broke correctness, correctly rejected

### 5. What points in a different direction
- **Biggest gain came from outside the curated list** — suggests less guidance may enable more novel discovery
- **Baby-bear = 0 of 20 iters** — CLAUDE.md nudge added too late; needs to be a mandatory first target next run
- **Extension rate post-improvement: 80%** (4/5 iters after iter 16) — critical waste for long unsupervised runs

---

## Total Performance Across All Experiments

| Round | Iters | Kept | Baseline | Best | Gain | Cumulative | Cost |
|-------|-------|------|----------|------|------|------------|------|
| Round 1 | 74 | 5 | 2724.4ms | 2642.8ms | −3.00% | −3.00% | ~$0 (old API) |
| Round 2 | 20 | 4 | 2667.8ms | 2638.0ms | −1.12% | −4.10% | ~$0 (old API) |
| Round 3 (Exp 3) | 20 | 2 | 2665.6ms | 2628.4ms | −1.40% | ~−3.52% at 2^20 | $44.80 |
| **Total** | **114** | **11** | **2724.4ms** | **2628.4ms** | **−3.52% at 2^20** | | **~$45** |

**Absolute cumulative gain: 2724.4ms → 2628.4ms = −3.52% at 2^20**

Note: per-round gains (−3.00%, −1.12%, −1.40%) cannot be summed to 5.52%. Two reasons: (1) baselines drifted +25ms between sessions due to server thermal/memory state, so each round's gain is measured against a slightly worse starting point; (2) percentage gains compound, not add. The 3.52% absolute is the only honest cross-round number.

### Multi-size validation (after Round 2)

| Size | Change | Significant? |
|------|--------|-------------|
| 2^16 × 256 | −3.78% | Yes (p=0.00) |
| 2^18 × 256 | −2.21% | Borderline (p=0.02) |
| 2^20 × 256 | −1.06% | Borderline (p=0.03) |
| **2^22 × 256** | **−8.57%** | **Yes (p=0.00)** |

Gains amplify at larger sizes where working sets exceed L3 cache. Round 3 improvements not yet validated multi-size.

Notes:
- Round 3 gain (−1.40%) is within-session relative. Cumulative −3.52% is cross-round, not head-to-head validated.
- Rounds 1+2 used old API pricing (pre-Sonnet 4.6 rates); Round 3 = $44.80 at current rates
- Win rate: Round 1 = 5/74 = 6.8%, Round 2 = 4/20 = 20%, Round 3 = 2/20 = 10%
- Overall: 11/114 = **9.6% win rate**

### Efficiency trend
Round 1: 5/74 = 6.8% — richest search space, lower-hanging fruit
Round 2: 4/20 = 20% — structured first-half/second-half fusion opportunities, targeted approach
Round 3: 2/20 = 10% — harder frontier, better infrastructure (assembly tool, forbidden gate, recovery prompt)

Win rate holding despite harder search space. Infrastructure improvements appear to offset the harder optimization frontier.

---

---

## Terminal Log Behavioral Analysis (Haiku summary)

### Agent behavior patterns observed

**Assembly tool underused in early iters (1-7):** Agent read files extensively but did not call `get_assembly` proactively before submitting changes. This led to submitting ideas that relied on unverified compiler assumptions. Assembly tool adoption improved in later iters.

**Deadlock self-recognition (iter ~8):** Agent explicitly stated "I genuinely think all the major hot-path optimizations are either already implemented or explicitly listed as dead ends" and acknowledged being in analytical circles. Shifted strategy to grepping for missed patterns rather than structural changes. This is a healthy signal — agent aware of its own dead ends.

**Symmetry assumption without verification (iter 20):** The backwards flag removal was applied to `first_half_general` using pure symmetry reasoning ("if it worked for second_half_general, it should work here") without assembly comparison. Regressed -0.90%. Confirms: symmetry arguments need assembly verification before submission.

**Theory-driven reasoning strength:** Agent performed detailed algebraic analysis (butterfly operations, memory bandwidth estimates: ~20 GiB inverse DFT, ~80 GiB forward DFTs) and correctly concluded bandwidth is the bottleneck. Correctness reasoning was strong throughout.

**No infrastructure events in later iters:** No overload retries, no forbidden pattern triggers, no recovery prompts in iters 13-20. Clean run after the overload period.

### Behavioral recommendation for next run
- Make `get_assembly` mandatory before any structural change (add to prompt: "call get_assembly before write_file")
- Symmetry arguments explicitly require assembly evidence in the diff reasoning
- Agent's deadlock self-recognition is a feature — consider surfacing it as an explicit "no improvement" output that triggers a prompt refresh

*Report complete.*
