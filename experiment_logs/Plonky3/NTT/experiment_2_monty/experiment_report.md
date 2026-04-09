# Experiment Report — experiment_2_monty

**Target:** `coset_lde_batch` on BabyBear, 2^20 × 256 columns, `Radix2DitParallel`
**Model:** Claude Sonnet 4.6
**Writable scope:** `monty-31/src/x86_64_avx512/` only
**Iterations:** 11
**Total cost:** ~$72.57
**Result:** 1 kept improvement

---

## Introduction

### Experiment 1 — DFT Butterfly Optimizations

The first autoresearch run (74 iterations, Sonnet 4.6) targeted `dft/src/butterflies.rs` and
`dft/src/radix_2_dit_parallel.rs`. Starting from vanilla Plonky3, it found 5 improvements for
a cumulative **3.00% speedup** (2724.4 ms → 2642.8 ms). The dominant theme was packed-field
broadcast amortization: pre-broadcasting scalar twiddle factors into `F::Packing` once per
row-pair eliminated 16 redundant scalar→vector broadcasts per row-pair at 256 cols / AVX512
width 16. A follow-up round (Round 2, discarded) explored the same scope further but all
candidates regressed on the updated codebase. Results were shared publicly. All improvements
were submitted upstream.

This experiment (experiment_2_monty) opened a new scope: the underlying Montgomery field
arithmetic in `monty-31/src/x86_64_avx512/`. Every butterfly in every NTT layer calls
`add`, `sub`, and `mul` from this file — gains here multiply across the entire transform.

### Agent Infrastructure Improvements

Key additions between experiment 1 and this run that changed agent behavior:

- **`eliminated_ideas.md`** — A persistent cross-iteration memory file listing all analytically
  dismissed and benchmark-confirmed dead ends. Injected into every agent prompt. Prevents
  agents re-deriving the same ideas across iterations. By end of this run: 31 entries.

- **`get_assembly` tool** — Agents can retrieve actual x86-64 assembly for any function
  directly from the server. Eliminates guesswork about LLVM codegen — agents verify what
  instructions are actually emitted before and after changes, rather than reasoning about
  what the compiler *should* produce.

- **`edit_file` tool** — Surgical string-replacement edits instead of full-file rewrites.
  Reduces diff noise, makes agent changes easier to review, and avoids accidental overwrites
  of surrounding code.

- **Dual benchmark gate** — Changes must pass both p < 0.05 (Criterion t-test) and ≥ 0.20%
  practical significance. Filters statistical noise without discarding real small gains.

- **CLAUDE.md modular split** — Global agent behavior rules (`AGENT.md`) separated from
  per-experiment instructions (`CLAUDE.md`). `loop.py` concatenates both. Prevents behavioral
  rules from being overwritten when experiment context changes.

---

## Part 1 — Single-Size Validation

The kept improvement (`vpcmpgeud`/`vpcmpltud` replacing `vpminud` in AVX512 Add/Sub) targets port 0
pressure in the Montgomery field arithmetic layer. Because this change is below the butterfly level
— every packed add and sub in every butterfly layer goes through it — the gain should hold across
input sizes.

**Single-size validation** (60s measurement, `ncols=256`, 2^20 rows):

| Branch | Time CI [low, median, high] | Change CI | p-value |
|--------|----------------------------|-----------|---------|
| `origin/main` | [2.7191 s, **2.7272 s**, 2.7360 s] | — | — |
| `perf/monty31-addsub-port-pressure` | [2.6763 s, **2.6838 s**, 2.6916 s] | [−2.01%, **−1.59%**, −1.14%] | 0.00 |

The CI is tight (0.87% wide), the entire interval is negative, and p=0.00 leaves no doubt.
The cross-session result is stronger than the in-session signal (+0.86%, p=0.02), which is
expected: cross-session uses a clean baseline unaffected by session variance (~1.4%).

**Multi-size validation:** Multiple approaches were attempted (sequential multisize and per-size isolated pairs with CPU cool-down); all were inconclusive — the improvement magnitude (~1.6%) is too close to session-to-session variance (~1.4%) to yield clean per-size p-values. Table will be updated in a later post if the methodology is refined.

---

## Part 2 — The One Kept Improvement

### Iter 1: AVX512 Add/Sub Port 0 Pressure Relief (+0.86%, p=0.02)

**Idea:** Intel AVX-512 has two relevant execution ports for integer vector operations: port 0
and port 5. The original `Add` and `Sub` implementations in `PackedMontyField31AVX512` used
`vpminud` (port 0 only) for the modular correction step. In the DIT butterfly hot loop, `mul`
already saturates port 0 (underflow correction uses a masked `vpaddd`, also port 0). Replacing
`vpminud` in `Add`/`Sub` with a compare (`vpcmpgeud`/`vpcmpltud`, port 5) + masked add/sub
(port 0) splits the pressure across both ports, reducing total stall time.

**Change:** 34 insertions, 9 deletions in `monty-31/src/x86_64_avx512/packing.rs`.
- Removed `mm512_mod_sub` import (replaced with explicit intrinsics).
- `Add::add`: `vpminud(sum, P)` → `vpcmpgeud(sum, P)` mask + `vpsubd_mask`.
- `Sub::sub`: `vpminud` correction → `vpcmpltud(diff, P_HALF_sentinel)` mask + `vpaddd_mask`.

**Why it works:** `mul` runs at 6.5 cyc/vec throughput with 21 cyc latency and already
occupies port 0 for its underflow check. Each butterfly does one `mul` + one `add` + one `sub`.
Moving the add/sub corrections to port 5 removes the port 0 bottleneck on `add` and `sub`,
which previously competed with `mul`'s correction step.

**PR branch:** `perf/monty31-addsub-port-pressure` (on `Barnadrot/Plonky3` fork)

---

## Part 3 — Why the Experiment Was Stopped

After iter 1, the experiment ran 10 more iterations with 0 additional kept improvements.

### Stopping criteria met

**Primary: exhausted search space.** By the end of the run, `eliminated_ideas.md` contained
31 documented dead ends — analytically eliminated ideas, confirmed regressions, and ideas that
hit forbidden-pattern gates before benchmarking. When agents were given this list and asked to
produce a new candidate, they defaulted to re-exploring ideas already on it. Iters 8–9 both
targeted the `backwards` bool removal in adjacent functions; iter 10 targeted `reserve_exact`,
which had been analyzed and dismissed earlier. Fresh ideas became increasingly rare and all regressed: iters 2 and 3 produced novel
approaches (sign-bit underflow detection for Sub, `scale_applied` branch peel in `second_half`),
and iter 10 found a genuinely new angle (`reserve_exact` pre-allocation + IDFT write-order swap).
All three regressed. By iters 8–9, agents had stopped finding new ground and were circling back
to structurally identical ideas (backwards bool removal) applied to adjacent functions.
This is the clearest stopping signal: when the eliminated list covers the reachable space and
the remaining fresh ideas consistently regress, the search is done.

Circulation (agents re-deriving already-analyzed ideas) is a symptom of the same cause — not
a failure of the agent behavior per se, but a consequence of the search space being fully mapped.
The `eliminated_ideas.md` file is injected into every prompt; agents saw the list but could not
find an entry point outside it.

**Secondary: API instability.** Iters 5–7 and iter 12 were lost to Anthropic 529 overload
errors, burning $20+ with no benchmark signal. Logs for iter 12 confirm no viable candidate
had been produced before the crash, so the lost signal cost was minimal — but the pattern
accelerated the decision to stop.

### Only non-exhausted avenue: model scaling

Within the current search space and writable scope, the only remaining lever is model scaling.
Sonnet 4.6 explored the accessible surface thoroughly. Opus 4.6 reasons more carefully at the
assembly level and may find ideas Sonnet dismissed or missed.

An Opus run on this target is planned — but execution will be careful: live monitoring with an
early stop if the model circles on the same eliminated list. At ~3× the cost of Sonnet, an
unmonitored run risks $100+ with no signal. The primary goal is not to extract further
improvements (though that would be a bonus) but to establish a concrete Sonnet vs Opus
comparison: does Opus navigate the eliminated list better, find genuinely fresh ideas, or
reach the same dead ends faster?

---

## Part 4 — What's Next

### 1. New prover target

The natural next autoresearch target is a different ZK proving system where the same
loop-based optimization approach applies. Candidates include systems using:
- NTT/DFT as a core bottleneck (same techniques apply directly)
- Poseidon2 / hash-based operations (AVX512 S-box, round constant folding)
- Sumcheck evaluation hot loops (packed field arithmetic, same profiling methodology)

The infrastructure (loop.py, Criterion gate, eliminated_ideas.md) ports cleanly to any
Rust codebase with a tight benchmark target. Main prerequisite: a Criterion benchmark on
the hot function before the loop starts.

### 2. Other Plonky3 crates

The current improvements target `coset_lde_batch` via `Radix2DitParallel` on BabyBear.
Plonky3 contains other potentially optimizable paths:
- **Poseidon2 AVX512** — `poseidon2/src/` — hash rate multiplies across the entire proof
- **Mersenne-31 NTT** — different field, different twiddle structure, unexplored
- **FRI folding** — query phase is compute-bound on large instances

A scoped experiment on any of these would follow the same structure: writable scope to one
crate, correctness gate via existing tests, Criterion baseline from upstream `main`.

### 3. Opus vs Sonnet racing

All experiments to date used Sonnet 4.6. Opus 4.6 reasons more carefully about assembly-level
tradeoffs and is less likely to circle on ideas it has already analyzed. A direct comparison:
- Run both models on the same fresh target (same CLAUDE.md, same scope)
- Track kept improvements, cost-per-kept, and circling frequency
- Hypothesis: Opus finds more per-iter but costs ~3× more — net efficiency unclear

The racing format (two parallel loops, shared eliminated_ideas.md) would give a clean signal
within one experiment without doubling the total iteration budget.

---

## Appendix I — Iteration Log

| Iter | Result | Change | Idea |
|------|--------|--------|------|
| 1 | **kept** | +0.86% | vpcmpgeud/vpcmpltud in Add/Sub |
| 2 | rejected | −1.45% | Sign-bit approach for Sub underflow detection |
| 3 | rejected | −0.56% | Peel first `scale_applied` iteration in `second_half` |
| 4 | gate | — | Forbidden pattern (`debug_assert!`) — rejected before bench |
| 5 | gate | — | API overload — no idea produced |
| 6 | gate | — | API overload — no idea produced |
| 7 | gate | — | API overload — no idea produced |
| 8 | rejected | −3.88% | Remove `backwards` from `dit_layer_rev`/`dit_layer_rev_scaled` |
| 9 | rejected | −1.72% | Remove `backwards` from `dit_layer`/`dit_layer_twiddle_free` |
| 10 | rejected | −1.57% | `reserve_exact` before IDFT to avoid realloc |
| 11 | gate | — | Clone-based twiddle iterator replacement — gate rejection |
| 12 | gate | — | API overload — no viable candidate produced |

---

## Appendix II — Eliminated Ideas

*Full contents of `eliminated_ideas.md` at experiment close — 31 entries.*

See [eliminated_ideas.md](sonnet/eliminated_ideas.md).
