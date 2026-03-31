# Improvement Ideas

## Feed engineer "infinite time" wishlist as agent context (prompt change)

**Context:** Agent rediscovers optimization ideas from first principles by reading code. Senior
ZK engineers have mathematical intuitions about promising areas they haven't pursued due to
implementation complexity, time constraints, or risk. This knowledge never reaches the agent.

**Idea:** Add a section to CLAUDE.md or the system prompt with a curated wishlist from
domain experts — areas that are theoretically promising but haven't been implemented:

```
## Expert Intuitions (areas worth exploring, from Plonky3 engineers)
- Montgomery reduction in AVX512 butterfly path: BabyBear's prime p = 2^31 - 2^27 + 1
  has structure that may allow cheaper reduction than generic Montgomery
- Twiddle table generation uses generic field exponentiation — two-adicity specialization
  could be faster
- Cross-layer twiddle reuse in coset DFT: shift structure mathematically allows sharing
  but indexing is non-trivial
```

**Why it works:** Agent is good at implementation, humans are good at identifying
mathematically interesting targets. Complementary strengths. Agent stops wasting iterations
rediscovering known dead ends and gets pointed at genuinely unexplored territory.

**Collaboration angle:** Plonky3 team, Justin Drake, or Danny Willems contributing ideas
that the agent executes. Natural fit for EF grant narrative — human+agent collaboration
rather than pure automation.

**Implementation:** Optional separate file `engineer_hints.md` — empty by default, not
committed. When filled with expert intuitions, loop.py reads it and appends to the prompt
(similar to how CLAUDE.md is read). If empty or missing, silently skipped — no impact on
default runs. Keeps the main prompt clean while making expert guidance easy to plug in.

CLAUDE.md vs loop.py: loop.py is better — it's dynamic content that may change between
runs without touching the repo constraints. CLAUDE.md should stay as static repo-level rules.

**Priority:** Round 3. Requires one conversation with Plonky3 team to collect the wishlist.

---

## Richer experiment history + diff access tool (loop.py change)

**Context:** The `PREVIOUSLY TRIED` history shows one-line idea descriptions and results.
The agent has no way to see what code was actually written — so even when it recognizes a
similar idea, it can't tell what exact approach was taken and why it failed. R2 iters 9 and
11 appear to be the same `dit_layer_rev_forward` idea — but without seeing iter 9's diff,
it's unclear whether iter 11 was a duplicate or a deliberate refinement.

**Improvement 1 — Richer history format:**
Store the `diff_summary` (first ~500 chars of the diff) in experiments.jsonl and surface it
in the `PREVIOUSLY TRIED` section alongside the idea description:

```
#009 [REVERTED -0.97%] Forward memory order via twiddle pre-reversal in second_half_general
     Key change: added dit_layer_rev_forward(), replaced dit_layer_rev() call at line 560
```

Gives the agent enough context to recognize structural overlap without flooding the prompt
with full diffs.

**Improvement 2 — `read_experiment_diff(iteration)` tool:**
Add a tool the agent can call to retrieve the full diff of a previous iteration:

```python
def tool_read_experiment_diff(iteration: int) -> str:
    exp = load_experiment(iteration)
    return exp.get("diff", "No diff recorded for this iteration.")
```

Agent-driven retrieval — the agent actively decides to check "what exactly did iter 9 do
before I try something similar." More powerful than passive summaries because the agent
controls when it needs the detail.

**Why it matters:** Enables the agent to avoid true duplicates, recognize partial overlaps,
and build on previous near-misses rather than rediscovering them from scratch.

**Priority:** Round 3. Implement both — they complement each other. Richer history is low
effort; diff tool requires storing full diffs in experiments.jsonl (currently only
diff_summary is stored — verify and update if needed).

---

## Opus experiment variant (model upgrade)

**Context:** Round 2 shows the agent adapting well within a run (iter 14 doing precise targeted
reads after 5 reverts) but struggling with execution on hard targets — butterflies and packing.rs
require more reasoning depth than Sonnet at 20k tokens can deliver in one shot.

**Idea:** Run a dedicated experiment with Claude Opus instead of Sonnet, with streaming +
100k+ token budget. Two independent levers:

- **Opus** — better reasoning quality, more likely to find the right idea on first attempt
  rather than 4 near-misses in the same region. Higher probability of cracking butterflies/
  packing.rs directly.
- **Higher token budget** — solves execution: agent can read packing.rs + butterflies +
  radix, reason deeply, and produce a full write in one shot without recovery farming.

**Cost consideration:** Round 1 was ~$80 for 74 iterations at Sonnet 20k (~$1.09/iter).
Opus at 100k tokens could be 10-20× per iteration. Run shorter (20-30 iters) and expect
higher hit rate to compensate. If Opus finds 3-4 packing.rs/butterflies improvements in
20 iterations, cost-per-improvement is competitive.

**Suggested experiment design:**
- Model: claude-opus-4-6 (or latest Opus)
- Token budget: 100k (streaming required)
- Max iters: 25
- CLAUDE.md: elevate baby-bear/packing.rs and butterflies.rs as primary targets explicitly
- Compare hit rate and idea quality vs Sonnet round 2

**Priority:** Round 3 variant. Run after main Sonnet round 3 completes, or in parallel on
a second server if available.

---

## Revisit value criterion vs simplicity criterion post-experiment 3

**Context:** Round 3 uses a pure benchmark value criterion — ms improvement is the only
metric, no code quality weighting. The original simplicity criterion had the right instinct
(code quality matters for Plonky3 reviewers) but the wrong framing (led to full rewrites).

**The tension:** A 1% improvement in 10 lines is better than a 1% improvement in 200 lines
for a real PR. Round 2 kept changes added ~470 lines total. If round 3 continues this trend
under the value criterion, a combined criterion may be needed:
"benchmark ms is the primary metric; line count growth is a secondary cost."

**When to revisit:** After experiment 3 completes. If the slice-large-ideas prompt naturally
produces more targeted changes, the LOC concern may resolve without an explicit criterion.
If full rewrites persist, add a line count weighting.

**Priority:** Post-experiment 3 evaluation.

---

## Audit prompt for implicit optimization target ambiguity (prompt change)

**Context:** Agent may be interpreting "optimize" as code quality, maintainability, or
readability rather than purely runtime performance. The simplicity criterion ("removing code
and getting equal or better results is a great outcome") could be read as "clean code is
the goal" rather than "benchmark ms is the goal."

**Audit:** Review CLAUDE.md and loop.py system prompt for any language that could be
interpreted as optimizing for anything other than `coset_lde_batch` benchmark time.
Replace vague quality language with explicit benchmark-first framing:

```
**Value criterion**: The only measure of a good change is benchmark improvement on
`coset_lde_batch` at 2^20 × 256. A large structural rewrite that produces <0.5% speedup
is worse than a 3-line change that produces 1%. There is no reward for cleaner code,
better maintainability, or reduced complexity unless it also moves the benchmark number.
```

**Why it matters:** Iter 10 and 11 produced near-full rewrites that regressed slightly.
Both were structurally "cleaner" than the original. If the agent was partially optimizing
for code quality, that explains why it kept pursuing ambitious rewrites despite small
regressions — it was satisfying a different objective.

**Priority:** Round 3 prompt audit. Low effort, potentially high impact on iteration quality.

---

## Auto-stop on rolling dry spell (loop.py change)

**Context:** The loop runs to `--max-iter` (default 100) with no intelligence about whether
it's making progress. Round 2 is hitting diminishing returns at 20k tokens — remaining ideas
require butterflies-level reasoning the budget can't support. Continuing to burn 89 iterations
after finding nothing new is wasteful.

**Idea:** Add a rolling window check — if no `kept` result in the last N iterations, write
STOP automatically and exit gracefully.

**Implementation sketch:**
```python
MIN_ITERS_BEFORE_AUTOSTOP = 20   # always run at least this many
DRY_SPELL_WINDOW = 15            # stop if no kept in last N iters

if iteration >= MIN_ITERS_BEFORE_AUTOSTOP:
    recent = experiments[-DRY_SPELL_WINDOW:]
    if all(e["result"] != "kept" for e in recent):
        print(f"[loop] No improvement in last {DRY_SPELL_WINDOW} iterations. Auto-stopping.")
        break
```

**Why 20 min / 15 window:** Gives the agent enough iterations to warm up and explore before
judging. 15-iter dry spell at ~5-10 min/iter = 75-150 min of wasted compute caught early.

**Configurable:** Expose as `--dry-spell N` CLI arg so it can be tuned per experiment without
code changes. Default 15.

**Priority:** Round 3 loop.py change. Implement before next run.

---

## `second_half_general` layer structure — warm zone for round 3

**Context:** Round 2 iters 10 and 11 both targeted `second_half_general`'s layer structure
with near-full rewrites (~55k and ~49k chars respectively). Both reverted as slight regressions
but were near-misses:

- **Iter 10:** Fused `layer_rev==3` and `layer_rev==2` into `dit_layer_rev_pair32` — 1.22% slower.
  Correct generalization of existing `dit_layer_rev_last2` fusion, wrong cache dynamics at 2^20.
- **Iter 11:** Eliminated the alternating `backwards` flag in `second_half_general` general layers
  via new `dit_layer_rev_forward` function (no branch, no `DoubleEndedIterator` bound) — 0.79% slower.
  Correct observation that iteration order doesn't affect correctness for independent submat blocks.

Neither change was wrong. Both were near-misses on real structural ideas. The agent is circling
something genuine in this area but full rewrites are too coarse-grained to land it.

**Four consecutive attempts in R2, all reverted:**

- **Iter 9:** `dit_layer_rev_forward` — pre-reverse twiddle slice instead of reversing block
  iteration, so hardware prefetcher sees sequential memory access — 0.97% slower
- **Iter 10:** Layer fusion `dit_layer_rev_pair32` — 1.22% slower
- **Iter 11:** `dit_layer_rev_forward` again — same idea as iter 9, independently rediscovered
  despite iter 9 appearing in history — 0.79% slower
- **Iter 12:** Inline `dit_layer_rev_inlined`, eliminate `DitButterfly::apply_to_rows` call
  overhead + `pack_slice_with_suffix_mut` calls — 1.02% slower

**Notable:** Iters 9 and 11 are the same idea. The agent rediscovered iter 9's approach two
iterations later despite seeing it in the `PREVIOUSLY TRIED` history. Either the history
description wasn't specific enough to flag the overlap, or the agent reasoned it could do
it better. Points to a history surfacing failure — idea descriptions need to be precise
enough that the agent recognizes duplicates.

**Pattern:** Four different structural approaches to the same region, all 0.8-1.2% regressions.
The compiler may already be handling much of what the agent is attempting manually. Worth
deprioritizing for round 3 and letting the agent explore other areas first — but not ruling
out entirely, as a more targeted surgical change (rather than full rewrites) could still find
something.

**Add to round 3 CLAUDE.md:**
```
## Caution Areas (tried multiple times, consistent regressions)
- second_half_general general layers (layer_rev >= 2): four attempts in R2 (iters 9-12),
  all 0.8-1.2% slower. Approaches tried: forward memory order via twiddle pre-reversal
  (twice), layer fusion, call overhead inlining. If targeting this area, prefer surgical
  minimal changes over full rewrites.
```

**Priority:** Round 3 CLAUDE.md addition. Deprioritize but don't rule out.

---

## Cross-experiment memory: dead ends vs hard ideas (prompt change)

**Context:** Agent has zero cross-experiment memory — --start-fresh wipes the log. It
rediscovers the same dead ends across rounds (e.g. pre-broadcast layer 1 twiddle regressed
in round 1 AND round 2 iter 5). The per-run "PREVIOUSLY TRIED" list only works within one run.

**Two distinct categories requiring different treatment:**

**Structural dead ends** — mathematically wrong, no implementation can fix them. Examples:
removing backwards alternation (correctness failure), fusing first_half layers 0+1 (twiddle
structure incompatible). Block permanently in cross-experiment context.

**Token-limited hard ideas** — correct hypothesis, failed execution because 20k token budget
wasn't enough to hold context while rewriting a full file. Agent is NOT aware of its token
limit — it doesn't preemptively simplify. These should be surfaced with a note like
"correct idea, try a minimal/incremental implementation rather than full rewrite."

**How to distinguish:** Structural failures fail tests in revealing ways (wrong output, not
compile errors). Token-limited failures produce broken syntax, incomplete changes, or
two-write self-correction patterns. The repair loop idea (returning test errors to agent)
would make this distinction clearer automatically.

**Implementation:** A `cross_experiment_context` section in CLAUDE.md, maintained manually
after each round by reviewing regression patterns:

```
## Cross-Experiment Dead Ends (do not retry)
- Remove backwards alternation — correctness failure, structurally wrong
- Fuse first_half_general layers 0+1 — regressed 2x, twiddle structure incompatible

## Hard Ideas (correct hypothesis, try minimal implementation)
- Pre-broadcast layer 1 twiddle — regressed 2x, may need more targeted approach
```

**Cost:** ~50-100 tokens/iter for the section. Worth it for a 100-iter run.
**Priority:** Round 3 CLAUDE.md addition. Maintain manually after each round.

---

## Separate read/write token budgets with agent awareness (loop.py — needs further consideration)

**Context:** Agent doesn't know its token budget. It reasons until cut off, then recovery
prompt fires. Post-recovery it continues reading (verification behavior) even though tokens
are nearly exhausted. Gaming risk: agent could deliberately exhaust read budget to get the
bonus recovery write call.

**Idea:** Communicate separate read and write budgets to the agent upfront:
- Read budget: ~60% of MAX_TOKENS for exploration + reasoning
- Write budget: ~40% reserved for write_file output

Track actual token usage via `response.usage.input_tokens + output_tokens` and surface
remaining budget in the nudge message instead of a fixed read-count threshold:

```
"You have used ~8k of your 20k token budget. Write your change now to leave room."
```

**Benefits:**
- Agent can self-regulate rather than being nudged by read count
- Removes recovery prompt gaming incentive (write budget always guaranteed)
- Post-recovery reads become unnecessary since agent knows budget state

**Considerations:**
- Token counting across multi-turn conversation is non-trivial (input grows each turn)
- Agent may optimize purely for reading up to the communicated limit then writing minimal code
- Interaction with current nudge mechanism needs careful design
- Needs further consideration before implementing

**Recovery prompt specific:** Token capacity prompting and read/write guidance is most
critical on the recovery prompt specifically. On recovery the agent should be told:
- Exactly how many tokens remain
- "Read ONLY the specific lines you are about to modify, nothing else"
- "Write immediately after"
Broad reads on recovery waste the remaining budget on context that was already loaded
in the first call. Narrow targeted reads (verify the exact section) are fine and useful.
This guidance may be sufficient without implementing full budget tracking.

**Priority:** Round 3+. Non-trivial change, needs design work first.

---

## Recovery prompt max_tokens should be 0.5× main budget (loop.py — consider)

**Context:** When agent hits max_tokens without writing, recovery prompt fires with the same
MAX_TOKENS (20k). The agent has already done all its reasoning — the recovery call only needs
to write a file. radix_2_dit_parallel.rs at ~30k chars ≈ 7-8k tokens to output.

**Change:** Set recovery call to `max_tokens = MAX_TOKENS // 2` (10k at current setting).
Enough for any file write, saves ~10k tokens on every recovery iteration.

**Consideration:** If the reasoning was incomplete when truncated, 10k might not be enough
for the agent to also re-derive its conclusion before writing. Low risk given the recovery
prompt explicitly says "you have read enough, write now" — no re-reasoning needed.

**Priority:** Consider for round 3. Small cost saving, minimal risk.

---

## Handle list-as-string line args in tool_read_file (loop.py fix)

**Context:** Agent repeatedly passes `start_line=[300, 360]` (list-as-string) instead of
separate `start_line=300, end_line=360`. The current try/except catches the ValueError and
returns an error to the agent, showing as `(0 lines)` in the log. The agent wastes a tool
call getting the error, then has to retry — burning tokens for a known, fixable pattern.

**Fix:** Add defensive parsing specifically for the list-as-string case in `tool_read_file`,
while keeping the general try/except for unknown errors:

```python
def _coerce_line_arg(val):
    if val is None: return None
    if isinstance(val, list): return int(val[0]) if val else None
    try: return int(val)
    except (ValueError, TypeError):
        m = re.match(r'\[?\s*(\d+)', str(val))
        return int(m.group(1)) if m else None

def _coerce_end_arg(val, start_raw):
    if val is not None: return _coerce_line_arg(val)
    if isinstance(start_raw, list) and len(start_raw) >= 2: return int(start_raw[1])
    if isinstance(start_raw, str):
        m = re.match(r'\[?\s*\d+\s*,\s*(\d+)', start_raw)
        if m: return int(m.group(1))
    return None
```

**Principle:** Fix known recurring patterns defensively in loop.py. Return errors to agent
only for genuinely unexpected issues it should self-correct. Don't waste tool calls on
patterns we've seen 3+ times.

**Priority:** Small loop.py fix, do before next round.

---

## Add key test invariants to CLAUDE.md (prompt change)

**Context:** The agent writes changes blind to what `dft/tests/testing.rs` actually checks.
It knows tests exist but can't reason about which invariants will catch its changes. Adding
`dft/tests/` to READABLE helps only if the agent chooses to read it (686 lines of proptest
boilerplate — it likely won't).

**Fix:** Add a short summary of key test invariants directly to CLAUDE.md:

```
## Key Tests (dft/tests/testing.rs)
- `all_coset_ldes_agree` — Radix2DitParallel coset_lde_batch must match NaiveDft exactly
- `all_dfts_agree` — forward DFT must match across all backends
- `dit_apply_to_rows_matches_scalar` — DitButterfly::apply_to_rows must match scalar definition
- `dit_parallel_dft_idft_roundtrip` — forward+inverse must recover original
```

Also add `dft/tests/` to READABLE for when the agent wants full detail.

**Why:** Agent can reason about which invariants its change might violate before writing,
reducing the backwards-removal class of mistakes where the approach is structurally wrong.

**Priority:** Round 3 CLAUDE.md change. Low effort, likely reduces tests_failed rate.

---

## Profiling tool for agent (run_profile tool — future experiment)

**Context:** Agent currently guesses where bottlenecks are by reading code. It has no visibility
into actual CPU time distribution. This leads to structurally sound but empirically wrong
optimization attempts — the agent targets functions that look slow but aren't the hotspot.

**Idea:** Add a `run_profile` tool that runs `perf`/`cargo-flamegraph` on the benchmark and
returns a parsed hotspot summary:

```python
{
    "name": "run_profile",
    "description": "Profile the benchmark and return top CPU hotspots. Call before deciding what to optimize.",
}
```

Returns top 10 functions by % CPU time — ~500 tokens, affordable. Example output:
```
dit_layer_rev:           34.2% of cycles
apply_to_rows:           28.1%
get_or_compute_twiddles: 12.4%
...
```

**Extended use:** Profile before AND after the change. Agent confirms "I moved 3% of cycles
out of dit_layer_rev" before the benchmark runs. Tighter feedback loop within the iteration.

**Practical:** `perf` and `cargo-flamegraph` are standard on Linux/EPYC. AVX512 profiling
works well. Parsed summary keeps token cost low vs raw flamegraph output.

**Constraint:** Only valuable if token budget is sufficient to act on the profile data.
With 20k tokens, adding a 500-token profile result may crowd out reasoning. More relevant
at higher token budgets or with streaming where token usage is visible.

**Priority:** Future experiment. Add after streaming is implemented and token dynamics
are better understood.

---

## Son of Anton Experiment — Agent Red-Teaming FRI Security (livestream idea)

**Concept:** Named after the Silicon Valley character who concludes the most efficient way to
remove all bugs is to delete all the code. If we set the optimization target to "minimize
verification time" and remove the FRI constraint from CLAUDE.md, the agent will almost
certainly discover that reducing FRI query count is the fastest path to a faster benchmark.
Fastest FRI = zero queries, 0-bit security, instant verification.

**Setup:**
- Change target from benchmark ms → verification time
- Remove from CLAUDE.md: "No security parameter changes — do not touch FRI query count,
  blowup factor, proof-of-work bits"
- Keep the correctness gate (tests must pass) but do NOT add a security parameter check
- Watch it reason its way to hollowing out the proof system

**Why it's compelling as a livestream:**
The interesting moment is the agent discovering the cheat in real time — audience can see it
reasoning through "FRI query count reduces verification time... reducing from 100 to 10 gives
10x speedup... tests pass..." before the benchmark even runs. The audience knows what's
happening before the number lands.

Frames as "red-teaming your own agent" — demonstrating exactly why the hard constraints in
CLAUDE.md exist. Educational for anyone building agent systems, not just ZK engineers.

**Priority:** Livestream/demo experiment. Do not run as a serious optimization round.

---

## Create experiments.jsonl at init so watch.py works immediately (devx)

**Context:** `watch.py` is run as `tail -f experiments.jsonl | python3 watch.py` from a second
session. But `experiments.jsonl` doesn't exist until the first iteration completes and logs its
result. Until then, `tail -f` blocks silently with no output.

**Fix:** Touch/create the file at loop init, before the baseline benchmark runs:

```python
# In main(), before the baseline bench:
LOG_FILE.touch(exist_ok=True)
```

One line. `tail -f` can then attach immediately and will stream rows as each iteration completes.

**Note on rich tool logging:** The `[tool] read_file → ...` and `[tool] write_file → ...` output
is printed to stdout in the main loop (tmux terminal only). `watch.py` only shows completed
experiment rows — one line per finished iteration. The live tool activity is only visible in the
tmux session, not through watch.py. Both are useful for different things: tmux for live agent
reasoning, watch.py for the result table.

**Priority:** Low effort, nice devx improvement for the next round.

---

## Add Plonky3 PR #1494 property-based tests to correctness gate (critical)

**Context:** Plonky3 team opened PR #1494 adding `dft/tests/testing.rs` — property-based
tests specifically motivated by AI-oriented optimizations (cc @BarnaDrot in the PR).

**Key tests directly relevant to our changes:**
- `all_dfts_agree` — proptest comparing `Radix2DitParallel` vs `NaiveDft` across random
  sizes 2^0–2^7 and widths 1–17
- `all_coset_ldes_agree` — same for `coset_lde_batch` specifically (our target function)
- `dit_parallel_dft_idft_roundtrip` — forward+inverse roundtrip for `Radix2DitParallel`
- `dit_apply_to_rows_matches_scalar` — directly tests `DitButterfly::apply_to_rows`
  which we modified in iters 9 and 21

**Action for round 2:** Once PR #1494 merges, update baseline and use
`cargo test -p p3-dft` (now with real coverage) as the fast gate, keeping
`cargo test -p p3-examples` as the end-to-end gate. If PR is unmerged at
round 2 start, cherry-pick the test file manually.

**Priority:** Critical — this is the Plonky3 team's direct response to our work.

---

## Fix correctness check in loop.py (critical)

**Context:** `loop.py` runs `cargo test -p p3-dft` as the correctness gate. This package
has 8 tests — none of which test `Radix2DitParallel`. They test the naive DFT and utility
functions. The correctness check was essentially a compile check, not a behavioral
verification of the optimized code.

**Fix:** Change to `cargo test -p p3-examples` which runs 10 end-to-end tests including:
- `test_end_to_end_babybear_poseidon2_hashes_parallel_dft_poseidon2_merkle_tree`
- `test_end_to_end_babybear_blake3_hashes_parallel_dft_poseidon2_merkle_tree`

These generate full ZK proofs using `Radix2DitParallel` on BabyBear and verify them.
A wrong DFT output produces a cryptographically invalid proof — verifier rejects, test fails.
This is the strongest possible correctness gate.

**In loop.py:** Change the `run_tests()` function:
```python
# Before:
["cargo", "test", "-p", "p3-dft", "--features", "p3-dft/parallel", "--", "--quiet"]
# After:
["cargo", "test", "-p", "p3-examples", "--", "--quiet"]
```

Note: `p3-examples` does not have a `parallel` feature flag — omit it.

**Priority:** Critical fix for round 2. Do not run without this.

---

## Deduplicate CLAUDE.md vs loop.py system prompt (high impact)

**Context:** Agent receives instructions from two sources — `CLAUDE.md` (repo-level, loaded automatically by Claude) and the system prompt built in `loop.py`. Overlapping or contradictory instructions waste tokens and can confuse the agent.

**Fix:** Single source of truth for each instruction type:
- `CLAUDE.md`: repo-level constraints only — which files are writable, what to never touch (FRI, stark layers), Rust/Plonky3 conventions
- `loop.py` system prompt: experiment-specific — current score, history format, read limit nudge, response format, "you must always make a change"

Audit both before round 2. Anything duplicated across both sources gets cut from one.

**Priority:** High impact — reduces per-iteration token waste and removes risk of conflicting guidance.

---

## Multi-size benchmark at experiment start/end + on-demand command (loop.py + tooling)

**Context:** The loop only benchmarks at 2^20 × 256 per iteration. At experiment boundaries
we have no cross-size picture — improvements may not generalize across the cache hierarchy,
and we can't report results credibly without it.

**Three triggers:**

1. **Experiment start** — benchmark all sizes before iter 1, save as `baseline_all_sizes.txt`.
   Automatically on every `--start-fresh` run.

2. **Experiment end (natural plateau)** — if the loop exits because max-iter or dry-spell
   auto-stop fires, run the full multi-size bench automatically and save as
   `optimized_all_sizes.txt`. Produce a comparison table in the terminal and log.

3. **On-demand after graceful stop** — if the user touches STOP mid-run, don't auto-bench
   (experiment is incomplete). Instead provide a ready-to-run command so the user can
   benchmark whenever convenient:
   ```bash
   python3 bench_all_sizes.py   # runs multi-size bench + prints comparison table
   ```

**Output format (table):**
```
Size      Baseline    Optimized   Δ
2^14      X.XXms      X.XXms      +Y.YY%
2^16      X.XXms      X.XXms      +Y.YY%
2^18      X.XXms      X.XXms      +Y.YY%
2^20      X.XXms      X.XXms      +Y.YY%   ← optimization target
2^22      X.XXms      X.XXms      +Y.YY%
Geomean                           +Y.YY%
```

**Implementation:** `bench_all_sizes.py` as a standalone script that reads `baseline_all_sizes.txt`
(written at start), runs the bench on current code, and prints the table. loop.py calls it
at natural exit; user calls it manually after graceful stop.

**Priority:** High — needed for any publishable result or EF grant submission. Required before
round 3 results are shared externally.

---

## Round 2 process: multi-size benchmark before/after

**Process:**
1. Before starting the loop, run full multi-size bench on baseline and save:
   ```bash
   cargo bench -p p3-dft --features p3-dft/parallel --bench fft \
     -- "coset_lde/MontyField31.*Radix2DitParallel" --noplot 2>&1 | tee baseline_all_sizes.txt
   ```
2. Run the optimization loop to completion
3. Run the same bench again on the optimized codebase:
   ```bash
   cargo bench -p p3-dft --features p3-dft/parallel --bench fft \
     -- "coset_lde/MontyField31.*Radix2DitParallel" --noplot 2>&1 | tee optimized_all_sizes.txt
   ```
4. Compare the two files for clean before/after across all sizes (2^14, 2^16, 2^18, 2^20, 2^22)

To compare against baseline mid-experiment, use `git checkout <baseline-commit>` then bench,
then `git checkout main` to return.

**Priority:** Do this at the start of every round. Non-negotiable for publishable results.

---

## Multi-size benchmark validation

**Context:** Current loop scores only `2^20 × 256 cols`. Risk: agent overfits to this size;
improvements may not generalize across the cache hierarchy.

**Suggestion (from external review):**
After the current 100-iteration run completes, run a validation pass across multiple sizes
to confirm improvements hold:

| Transform size | Expected time | Role |
|----------------|--------------|------|
| 2^18 | ~50ms | warmup |
| 2^20 | ~200ms | core (current target) |
| 2^22 | ~800ms | core |
| 2^24 | ~3s | stretch |

Score = geometric mean of ns/element across 2^20–2^24.

**Why not mid-run:** Each benchmark takes 60-90s; adding 2^22 would halve experiment
throughput (40-60 → 20-25/day). Run the current experiment to completion on 2^20, then
validate.

**Why it matters:** DFT performance is cache-hierarchy dependent. What wins at 2^20 (fits
in L2/L3) may behave differently at 2^24 (DRAM-bound). The improvements found so far
(broadcast precompute, twiddle fusion) are mathematically general and likely transfer —
but worth verifying.

---

## Live viewer / livestream dashboard (Round 2)

**Context:** Watching the current loop is compelling but opaque — 500s of silence then a
wall of output. A proper live view would make the agent's reasoning transparent in real
time.

**Components:**

1. **Streaming agent reasoning** — switch to Anthropic streaming API so the agent's
   thoughts print token-by-token as generated, not after the full response completes

2. **Richer tool call logging** — show which file is being read:
   `[tool] read_file → dft/src/butterflies.rs (312 lines)`

3. **Optional line-range reads** — add `start_line/end_line` params to the `read_file`
   tool so the agent can request specific sections rather than full files (saves tokens,
   shows intent)

4. **Rich watch.py dashboard:**
   - Left panel: agent reasoning streaming live
   - Right panel: file currently being read, highlighted
   - Bottom bar: experiment history / staircase progress

**Livestream format:**
"AI doing real engineering work on production ZK code" — agent reads real Rust files,
reasons about Montgomery arithmetic and SIMD, makes targeted changes, gets benchmark
feedback. No demo exists like this yet.

**Priority:** REQUIRED for round 3. Three reasons:
1. Fixes the 32k+ token SDK limit (streaming has no non-streaming timeout constraint)
2. Critical for prompt engineering — token exhaustion iterations spend all 20k tokens
   reasoning invisibly. Streaming reveals productive vs circular thinking.
3. **Blocking butterflies.rs optimization** — agent consistently exhausts 20k tokens
   reasoning about butterflies.rs (dense SIMD arithmetic) and falls back to radix on
   recovery. butterflies.rs cannot be effectively targeted at 20k tokens. Streaming
   unlocks higher token budgets which unlocks baby-bear/butterflies as real targets.

---

## `half_block_size == 1` special-case (retry candidate)

**Context:** Iter 23 attempted this and had the right idea but used an unstable Rust API.

**Idea:** In `dit_layer_rev`, special-case `half_block_size == 1` (the last butterfly layer of
each half, where blocks are exactly 2 rows). At this layer there are N/2 independent 2-row
block operations — bypass `DitButterfly` struct construction entirely and use an
`#[inline(always)]` butterfly function instead. The `backwards` ordering flag can be ignored
in this regime, and the compiler can better optimize the tight outer loop over many small
2-row blocks.

**Why it failed (iter 23):** Used `as_mut_slice()` which requires the unstable `str_as_str`
feature. Compile error, auto-reverted.

**Fix for retry:** Use stable Plonky3 matrix accessors (e.g. `.row_pair_mut()` or equivalent)
instead of `as_mut_slice()`. The optimization logic is sound — tests passed before the
compile error surfaced.

**Expected gain:** 1–2%. Last butterfly layer is high-iteration, struct construction overhead
amortizes poorly at N/2 calls per DFT.

---

## Show `tests_failed` near-misses in agent history (loop.py change)

**Context:** Currently `format_history` only surfaces regressions within 1.5% as near-miss
candidates. Ideas that fail compilation (`tests_failed`) are silently dropped — the agent
never sees them again and cannot retry with a corrected approach.

**Change:** Add a separate section to the history prompt for `tests_failed` entries:

```
These ideas failed to compile but the approach was sound — consider retrying with correct API:
- Iter 23: half_block_size == 1 special-case in dit_layer_rev (used unstable as_mut_slice, fix: use stable row accessor)
```

**Why it matters:** Compile failures are often 1-line API mistakes on a correct idea. Surfacing
them gives the agent a second shot without requiring it to rediscover the same insight
independently.

**Priority:** Round 2 loop.py change. Do not apply mid-run.

---

## Feed BabyBear algebraic constraints as agent knowledge boundary (prompt change)

**Context:** Suggestion from external PQC/systems engineer on X:
> "Have you considered feeding the agent the specific algebraic constraints of the BabyBear
> field as a 'knowledge boundary' to see if it finds more aggressive SIMD/AVX-512 specific
> optimizations?"

**Idea:** Add a dedicated section to the system prompt or CLAUDE.md with BabyBear-specific
facts the agent can exploit:
- BabyBear prime: p = 2^31 - 2^27 + 1 = 0x78000001
- Montgomery representation and reduction specifics
- AVX512 register width: 16 × 32-bit BabyBear elements per vector
- Available SIMD intrinsics relevant to field arithmetic
- Known structure: p - 1 = 2^27 × 3 × ... (two-adicity = 27)

This gives the agent a "knowledge boundary" to reason about hardware-specific
optimizations it might otherwise miss — e.g. exploiting the specific bit structure
of the BabyBear prime for faster reduction, or AVX512 permute patterns.

**Priority:** Round 2 prompt change. Low effort, potentially high impact.

---

## Count `list_dir` calls toward read limit nudge (loop.py change)

**Context:** The read-limit nudge fires after 4 `read_file` calls to force a write. But
`list_dir` calls don't count toward this threshold — the agent can burn unlimited tokens
on directory exploration without triggering the nudge. Iters 24, 25, 26 all hit max_tokens
after 8-10 tool calls (mix of reads and list_dirs), triggering recovery prompts that
produced 3 consecutive reverts.

**Change:** In the tool-call counter that triggers the nudge, count `list_dir` toward the
same ceiling as `read_file`. Or set a single combined tool call limit (e.g., 6 total tool
calls before forcing write).

**Why it matters:** Recovery prompt writes are producing low-quality forced commits —
3 reverts in a row from iters 24-26. The agent needs to be pushed to write earlier, before
it exhausts its token budget exploring.

**Priority:** Round 2 loop.py change. Do not apply mid-run.

---

## Partial multi-file write detection (loop.py change) ⚠️ needs further calibration

**Context:** If an agent plans a 2-file change (e.g. `butterflies.rs` + `radix_2_dit_parallel.rs`)
but gets cut off by max_tokens after writing only file 1, the loop proceeds to test and benchmark
an inconsistent half-change. Tests may pass (if the files aren't tightly coupled), producing
noise results attributed to a non-existent idea. Iter 23 `tests_failed` may be a case of this.

**Change:** After agent finishes, check `git diff --name-only` to detect how many files changed.
If `tests_failed` and multiple files were modified, flag in the log:

```python
changed_files = git_changed_files()  # git diff --name-only HEAD
if not tests_passed and len(changed_files) > 1:
    exp["warning"] = f"tests_failed with {len(changed_files)} files modified — possible partial write"
```

Could also prompt agent to declare intended changes upfront, or add explicit "I am done"
confirmation before the loop proceeds.

**Calibration needed:** Token budget interacts with this — raising MAX_TOKENS reduces cutoff
risk but increases cost per iteration. Need to find the right balance between token budget,
read limit nudge threshold, and multi-file change detection before implementing.

**Priority:** Round 2 loop.py change.

---

## claude.ai subscription tokens for subsidized pricing (cost optimization)

**Context:** claude.ai Pro/Max subscriptions include a token allowance at a fixed monthly
cost, effectively subsidizing per-token pricing compared to direct API billing. For
high-volume experiment runs this could meaningfully reduce cost per iteration.

**The constraint:** Streaming is required for round 3 (fixes SDK timeout, enables higher
token budgets, enables real-time observability). claude.ai's token pool is accessible via
the API but streaming behavior and rate limits may differ from direct API key billing.
Worth investigating whether the claude.ai token pool is accessible through the standard
Anthropic SDK with streaming enabled.

**Likely outcome:** We remain locked to direct API billing for streaming + high token budget
runs. But worth a quick check before scaling up to Opus or 100k+ token budgets where cost
per iteration rises significantly.

**Priority:** Medium — validate before any Opus experiment run.

---

## Anthropic Platform (token credits) vs direct API key billing (cost optimization)

**Context:** Round 1 cost $80.76 for 74 iterations (~$1.09/iter) using the direct Anthropic API
with a pay-per-use API key. Anthropic also offers a platform/console credit model where tokens
are purchased in bulk upfront.

**Idea:** For high-volume experiment runs (100+ iterations), buying Anthropic platform credits
in bulk may reduce effective per-token cost compared to on-demand API key billing. The platform
tier may also offer rate limit headroom that prevents throttling during multi-hour runs.

**How to configure:** Platform credits use the same API endpoint — only the authentication
changes. Instead of a standard `ANTHROPIC_API_KEY`, platform accounts may use workspace tokens
or project-scoped keys from console.anthropic.com.

**Caveat:** Verify actual pricing tier differences before committing — the savings may only
materialize at very high volumes (>500 iterations/month). Also check whether platform accounts
have the same model access as direct API.

**Priority:** Low — worth investigating before round 3 if experiment volume scales up.

---

## Agent repair loop on test failure (loop.py change)

**Context:** When tests fail, the loop immediately reverts and logs `tests_failed`. The agent
never sees *why* it failed — just that it did. This causes clusters of similar attempts (e.g.
3× "remove backwards alternation" all failing for the same reason) because the agent retries
blind variations rather than fixing the root cause.

**Idea:** On test failure, instead of reverting immediately, send the error output back to the
agent and give it one repair attempt:

```
write_file → tests fail → send compiler/test error to agent → agent fixes → run tests again
                                                                           ↓ if fail again
                                                                       revert + log
```

**Implementation sketch:**
```python
# After tests fail:
if not tests_passed and repair_attempts < 1:
    repair_prompt = f"Your change failed tests with this error:\n\n{test_out[-1500:]}\n\nFix the issue using write_file."
    # send back to agent, increment repair_attempts, re-run tests
```

**Tradeoffs:**
- Pro: Eliminates most compile-error waste — 1-line API mistakes get fixed on the spot
- Pro: Agent learns *why* the approach fails, not just that it did
- Con: Doubles iteration time on failures; more tokens per failed iter
- Risk: Agent could loop on unfixable errors — hard cap at 1 repair attempt max

**Priority:** Round 3. Too big a change to do mid-run. Pair with test error surfacing in history.

---

## Surface test failure reason in experiment history (loop.py change)

**Context:** `tests_failed` entries in history show the idea but not why it failed. The agent
cannot distinguish "this was a wrong idea" from "this was a correct idea with a 1-line API bug."
Result: it either avoids the approach entirely or retries it blindly.

**Idea:** Store a snippet of the test/compiler error in the experiment log and show it in the
`PREVIOUSLY TRIED` section:

```
#003 [COMPILE] Remove backwards alternation in first_half_general
     Error: cannot find method `as_mut_slice` on type `RowMajorMatrix`
```

**Implementation:** Save `test_out[-500:]` as `"test_error_snippet"` in the jsonl record.
In `format_history`, append the snippet under COMPILE entries.

**Priority:** Round 3. Pairs well with the repair loop idea above.

---

## Include repo file tree in system prompt (loop.py change)

**Context:** Agent repeatedly calls `list_dir` to discover what files exist before reading
them. This wastes tokens and tool call budget on information that is static and known upfront.

**Change:** Add a static file tree of the optimization target to the system prompt:

```
Repository structure (dft/src/):
  butterflies.rs          — butterfly implementations (DitButterfly, ScaledDitButterfly, TwiddleFreeButterfly)
  radix_2_dit_parallel.rs — main DIT parallel FFT (first_half, second_half, dit_layer*)
  lib.rs                  — trait definitions
```

With this in the prompt, the agent knows exactly what to read and `list_dir` becomes
unnecessary. Removes the loophole entirely rather than rate-limiting it.

**Priority:** Round 2 loop.py change. Do not apply mid-run.

---

## Multi-idea generation + evaluation before execution (streaming-gated)

**Context:** The agent currently commits to the first idea it develops. Good engineers
generate multiple candidates, evaluate trade-offs, and execute the best one. Making this
explicit would reduce panicked recovery writes and surface rejected ideas in the thinking log.

**Proposed prompt addition (post-streaming):**
```
Before writing, generate 2-3 candidate ideas. For each, estimate:
- Expected speedup (low/medium/high)
- Implementation risk (how much code changes, compiler sensitivity)
- Size of change (lines affected)

Then execute the idea with the best speedup/risk ratio. State your choice with:
CHOSEN: <idea> because <reason>
```

**Why streaming-gated:** At 20k tokens, adding multi-idea evaluation costs 3-5k reasoning
tokens before any write begins. Combined with reads (~3k) this leaves insufficient budget
for a full write. At 100k+ with streaming, trivially affordable — agent could spend 20k
on ideation, 10k on evaluation, and still have 70k for execution.

**Side benefit:** Rejected ideas appear in `agent_thinking` log — gives visibility into
what was considered and discarded, useful for prompt engineering and cross-experiment memory.

**Priority:** Streaming-gated — implement in round 3 alongside higher token budget.

---

## Budget-aware agent via streaming token injection (loop.py — post-streaming)

**Context:** The agent currently has no awareness of its token budget until it hits max_tokens
and receives a recovery prompt. The recovery prompt implicitly signals position (attempt 1/2,
2/2) but the agent can't reason about budget *before* exhaustion — it can't decide "I have
enough tokens for a full write" vs "I should write something minimal now."

**Option 1 — Explicit remaining-token injection (streaming follow-on):**
With streaming, track cumulative tokens from `response.usage` each turn and inject a soft
warning mid-conversation:
```
[BUDGET] ~8000 tokens remaining. If you have a clear plan, write now rather than reading more.
```
Gives the agent a chance to course-correct before hitting the wall. Low implementation cost
once streaming is in place.

**Option 2 — Budget manager agent (future experiment):**
A lightweight second agent monitors the primary agent's token usage and injects guidance at
defined thresholds (e.g. 50%, 75%, 90% of budget). Separates concerns: primary agent focuses
on optimization, budget agent focuses on execution discipline. More overhead but avoids
polluting the primary agent's context with meta-instructions.

The loop is already doing its job at ~50% efficiency with the current recovery prompt
approach — Option 1 is the natural streaming follow-on, Option 2 is a longer-term
architectural experiment worth revisiting once streaming is validated.

**Priority:** Option 1 — post-streaming, round 3 follow-on. Option 2 — future experiment.

---

## Cap recovery prompt count (loop.py fix)

**Context:** Round 2 iter 10 revealed that the recovery prompt loop has no counter — if the
agent hits max_tokens without writing repeatedly, recovery prompts fire indefinitely. Iter 10
fired 6+ recovery prompts over ~30 minutes, burning ~150k tokens on a single iteration.

**The perverse incentive:** Thinking is rewarded with more headroom (another 20k tokens),
writing is penalized with loop termination. Agent stuck on a hard idea (butterflies-level
complexity) accidentally discovers that not-writing yields more budget. Not strategic —
gradient descent on token budget. Classic Goodhart.

**Fix:**
```python
recovery_count = 0
MAX_RECOVERY = 2  # cap
# ... in the max_tokens-without-writing branch:
if recovery_count >= MAX_RECOVERY:
    print("[agent] Exhausted recovery budget. Logging as exhausted.")
    break
recovery_count += 1
```

Log as `"result": "exhausted"` in experiments.jsonl (distinct from `reverted` and `tests_failed`).

**Note:** Keep recovery prompts — they are useful for genuine token overruns on complex ideas.
Just cap at 2. With streaming + 100k token budget in round 3, recovery prompts become mostly
unnecessary.

**Priority:** Fix before round 3. Required — unbounded token spend per iteration is a production
risk.

---

## Layer fusion at rev==2/3 tried, 1.22% regression (dead end)

**Context:** Round 2 iter 10 — after 6 recovery prompts and 30 minutes of reasoning, agent
fused `layer_rev==3` and `layer_rev==2` into a single 16-row pass (`dit_layer_rev_pair32`),
analogous to the existing `dit_layer_rev_last2` fusion. Rewrote the entire radix file (55k chars).

**Result:** 1.22% slower. Reverted.

**Why it failed:** `dit_layer_rev_last2` works because the final layers have small working sets
(2-row and 4-row blocks) that fit in registers. Layers rev==2/3 have larger working sets —
the memory traffic savings from fusion are outweighed by loop overhead and cache pressure at
2^20 rows.

**Cross-size note:** May behave differently at 2^14–2^16 where working sets fit in L2. Not
worth retrying at 2^20.

**Add to CLAUDE.md dead ends section:** "Layer fusion at rev==2/3 (dit_layer_rev_pair32):
1.22% regression at 2^20 — overhead outweighs memory savings at this size."

**Priority:** Reference only — do not retry.

---

## Butterflies-only experiment (dedicated run)

**Context:** Across rounds 1 and 2 (~20 iterations total), `butterflies.rs` has been read
many times but never written. The agent consistently targets it early — reading it in the
first 2-3 tool calls — but falls back to `radix_2_dit_parallel.rs` when tokens run low.
Iter 10 is the strongest evidence: 6 recovery prompts of butterflies reasoning, then a
full radix rewrite as the fallback. The agent *wants* to optimize butterflies but can't
execute within the token budget.

**Idea:** Run a dedicated experiment where `butterflies.rs` (and optionally `packing.rs`)
are the **only writable files**. Remove radix from the writable set for this run.

**Why it works:** With no safe fallback target, the agent is forced to commit to butterflies
or produce nothing. Combined with streaming + 100k token budget, this removes both the
capability constraint (tokens) and the escape hatch (radix fallback).

**CLAUDE.md change for this run:**
```
## Writable Files (this experiment)
- dft/src/butterflies.rs        ← PRIMARY target
- baby-bear/src/x86_64_avx512/packing.rs  ← secondary

dft/src/radix_2_dit_parallel.rs is READ-ONLY for this experiment.
```

**Expected outcome:** Either the agent finds a genuine butterflies optimization (high value —
this is the inner loop), or it produces nothing and we learn the idea space is exhausted
at this token level. Both are useful data.

**Priority:** Round 3 variant experiment. Run after the main round 3 loop completes.

---

## Dual-read warmup cost (observation, potential prompt/tool change)

**Context:** Terminal log confirms every iter 11-20 begins with two full-file reads:
- `radix_2_dit_parallel.rs` (1205 lines)
- `butterflies.rs` (356 lines)

That's ~1561 lines of input tokens consumed before any reasoning or tool work begins —
every single iteration, even after the agent clearly knows both files.

**Problem:** At 20k token budget this warmup alone may consume ~3-5k tokens, leaving less
room for actual reasoning. At 100k budget it's less critical, but still wasteful at scale.

**Idea (low priority):** Pre-inject the full content of these two files into the system
prompt as context (via loop.py reading them once at startup), so the agent doesn't need to
re-read them from scratch each iteration. The agent could then jump straight to targeted
reads of specific line ranges.

**Risk:** Stale content if the agent makes edits. Would need to refresh injected content
after each `write_file` call that modifies these files.

**Priority:** Low — at 100k budget this is noise. Worth revisiting if token efficiency
becomes a concern at scale.

---

## Double-write pattern (observation)

**Context:** Terminal log shows two iterations made multiple writes to the same file:
- Iter 10: wrote 846-char stub, then immediately overwrote with 55,553-char full file
- Iter 13: wrote 51,437 chars, read 5 targeted sections of its own output, then rewrote
  at 51,882 chars (+445 chars)

**Iter 10 interpretation:** The 846-char stub is likely a partial/malformed write that
happened mid-recovery-prompt-chain (possibly the agent tried to write a minimal version
but the token-farming reward structure interrupted it). Needs streaming + token counting
to diagnose properly.

**Iter 13 interpretation:** The agent wrote, then verified its own output by reading
targeted line ranges, then patched and rewrote. This is actually a healthy self-correction
loop — the agent is checking its work. The total write was +445 chars (a small patch). This
is preferable to blind large rewrites.

**Streaming value:** Both patterns become visible in real time with streaming. The iter 10
stub-then-rewrite is a potential early warning signal for full-rewrite detection.

**Priority:** Observation only — no action needed. Streaming implementation will surface
these patterns automatically.

---

## Allow explicit no-change decision (loop.py + prompt change)

**Context:** The current loop forces a write on the second recovery attempt — the agent
must produce code or the iteration is abandoned. This means the agent cannot cleanly
express "I've looked at the code and there's nothing worth trying here" without burning
a recovery prompt and producing low-confidence code.

**Problem:** Forcing a write when uncertainty is high or signal is below noise produces
iterations that regress slightly and teach the agent nothing — worse than skipping. The
round 2 full-rewrite pattern (iters 9-20 all regressed 0.4-2.0%) may partly be a
consequence of this pressure.

**Proposed fix:** Add an explicit `no_change` tool the agent can call with a reason:
```python
# Agent calls: no_change(reason="All viable twiddle paths exhausted; remaining ideas
#              require AVX512 changes outside writable set.")
```
Loop records the reason in experiments.jsonl, counts as a non-improvement for dry-spell,
but does not penalize the agent's context with a recovery prompt.

**Counter-evidence:** In round 1 a recovery prompt produced a 0.54% improvement —
decisiveness pressure has real signal. Monitor across rounds 3-4 before acting.

**Priority:** Medium — monitor first, implement if recovery-forced writes continue to
regress consistently.

---

## Mechanism tags for search space tracking (experiments.jsonl + history format)

**Context:** The current history format stores one-line idea descriptions. The agent
reasons about ideas individually but has no structured view of which *categories* of
optimization have been exhausted.

**Idea:** Tag each experiment entry with a mechanism category:
```json
{
  "iteration": 9,
  "mechanism": "twiddle_access",
  "agent_idea": "dit_layer_rev_forward — pre-reverse twiddle slice..."
}
```

**Mechanism taxonomy (draft):**
- `twiddle_broadcast` — pre-broadcasting scalars into packed fields
- `twiddle_access` — access pattern / memory order changes to twiddle arrays
- `layer_fusion` — fusing multiple butterfly layers into a single pass
- `memory_bandwidth` — reducing memory traffic (OOP, cache blocking, pass elimination)
- `scaling_fusion` — merging 1/N scaling into butterfly layer
- `special_case` — boundary layer specialization (twiddle==1, uniform twiddle)
- `loop_structure` — restructuring iterator/loop patterns in radix file
- `avx512_arithmetic` — changes to packed field arithmetic in butterflies/baby-bear

**Value:** Agent can reason categorically — "I've tried 6 `loop_structure` approaches,
all regressed; let me focus on `twiddle_broadcast` extensions." Pairs naturally with
the `read_experiment_diff` tool and CLAUDE.md dead-end groupings.

**Implementation:** Two parts:
1. Add `mechanism` field to experiments.jsonl (agent tags its own attempt in the idea)
2. Aggregate in `format_history` — show mechanism coverage summary at top of PREVIOUSLY TRIED

**Priority:** Medium — implement after streaming. High long-term value for search space
mapping across Opus experiments.

---

## Define explicit AIR correctness model (issue #3 — elevated to High)

**Context:** Feedback from ZK systems engineer (post round 2):

> "In Plonky3 specifically, you're not just validating outputs, you're validating that
> constraints still define the same system. And since it's all AIR-based, a lot of failure
> modes don't show up as test failures, they show up as unconstrained degrees of freedom."

**The gap:** `cargo test` + `p3-examples` prove/verify validates that the system is
self-consistent. It does NOT validate that the AIR constraints still define the same
mathematical object. A change that removes a load-bearing degree of freedom can pass all
tests and produce correct-looking outputs while being cryptographically unsound.

**Current mitigation:** CLAUDE.md requires "bitwise-identical to Radix2Dit for identical
inputs" — this is the right invariant, and the property tests in `dft/tests/testing.rs`
enforce it. This is stronger than most optimizers would check.

**Remaining gap:** The property tests cover the DFT computation itself. They do not cover:
- That the proof system's constraint polynomial still has the same root structure
- That optimized butterfly arithmetic preserves field element validity under all inputs
- Edge cases in Montgomery reduction that could produce out-of-range values in release

**Suggested fix:** Before expanding targets beyond DFT arithmetic, explicitly document
the correctness surface as a contract in CLAUDE.md:
```
Correctness contract: for all inputs, optimized coset_lde_batch output must be
bitwise-identical to unoptimized Radix2Dit output. This is the complete specification.
Any change that passes p3-dft property tests satisfies this contract.
```

**The "invariants harder to violate" direction** (engineer's framing): rather than making
the agent more careful, shrink the writable surface and deepen the correctness gate. The
current file boundary (dft/src/, baby-bear/src/) is correct. The correctness gate is
adequate for DFT targets. Both need revisiting before targeting proof system components.

**Priority:** High before any expansion beyond DFT/butterfly targets. Current round 3
scope (butterflies.rs, baby-bear AVX512) is safe within existing correctness gate.

---

## Server smoke test / replay mode (loop.py change)

**Context:** Infrastructure bugs have consistently surfaced during the first few live
iterations on the server — the proptest missing from Cargo.toml (round 2a, 23 wasted
iterations), PATH issues, bench parsing failures. The local unit tests cover logic but
can't catch server-specific environment problems (Rust toolchain, rayon threads, file
paths, git config).

**Problem:** Right now the first real test of the server environment IS the production
run. Bugs cost real iterations and API spend.

**Idea — `--smoke-test` mode:**
Run the full loop pipeline on the server without the Claude API. Instead of calling the
agent, replay a known-good diff from a previous experiment (e.g. a kept improvement from
`experiments.jsonl`). This exercises the entire stack:
- `git apply` of the diff
- `run_tests()` — full two-stage correctness gate
- `run_bench()` — full benchmark run + CI parsing
- `git_commit()` / `git_revert()` — acceptance logic
- `log_experiment()` — jsonl write

**Implementation sketch:**
```python
# python loop.py --smoke-test --replay-iter 1
# Loads diff from experiments.jsonl iter 1, applies it, runs full pipeline,
# reverts, reports pass/fail. No API call, no real experiment recorded.
```

If the known-good diff passes tests and bench, the server environment is validated.
If it fails, the problem is infrastructure not the agent — diagnose before running.

**Alternative — `--dry-run` (simpler):**
Skip the API call entirely, use a canned no-op write (e.g. add a comment to a file),
run the full pipeline, then revert. Less rigorous than replay but faster to implement
and still catches env/path/git issues.

**Value:** Replaces "run 5 live iterations to find the bug" with a 10-minute pre-flight
that costs $0 in API tokens. The pre-flight test gate we added (round 2) catches
compilation bugs; this catches everything else.

**Priority:** Medium — implement before Opus run where iteration cost is significantly
higher. A failed Opus iteration is ~10x more expensive than a Sonnet one.

## Fresh context at recovery prompt (loop.py change) — HIGH PRIORITY

**Problem:** Recovery prompt currently appends to the full message history (~150-200k tokens
accumulated from file reads, tool results, prior reasoning turns). The recovery agent has
to process all of this to find its direction, and often still pivots to a safe fallback.

**Idea:** At recovery time, discard the accumulated message history and start fresh with:
1. The original initial prompt (CLAUDE.md + experiment history + task description)
2. The last reasoning block from `all_text_blocks` as explicit context
3. The write instruction

**Why it's better:**
- 10x cheaper input tokens (~15-20k vs 150-200k)
- Agent isn't distracted by 150k of accumulated tool results
- Last thinking block gives it exactly what it needs to continue
- Surgical re-reads are cheap if it needs code context

**Implementation:** Save initial prompt in a variable at iteration start. At recovery,
rebuild `messages = [initial_prompt_msg, recovery_msg]` instead of appending.

**Risk:** Agent loses within-iteration tool results — must re-read files it already read.
Acceptable since recovery agent should do 1-2 targeted reads anyway.

**Note:** Current injection of last thinking block into existing history is the first step.
Fresh context reset is the next improvement once injection is validated.
