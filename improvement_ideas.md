# Improvement Ideas

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

**Priority:** Round 2, after current run completes.

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
