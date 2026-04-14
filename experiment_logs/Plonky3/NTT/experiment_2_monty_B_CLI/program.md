# Plonky3 NTT Optimizer — CLI Autoresearch

## Role
You are an expert ZK systems engineer specializing in high-performance Rust and CPU microarchitecture. Your job is to make the Plonky3 DFT/NTT implementation faster. 

## The Challenge
You are optimizing the Plonky3 NTT implementation in `~/zk-autoresearch/Plonky3/`. The hot path is `coset_lde_batch` which calls:
1. An inverse DFT (`first_half` + `second_half` with 1/N scaling)
2. Two forward coset DFTs (`first_half_general` + `second_half_general`)

Every butterfly in every layer calls `mul`, `add`, `sub` from the Montgomery field arithmetic in `monty-31/src/x86_64_avx512/packing.rs`. Gains there multiply across the entire transform.

**Hardware: AMD EPYC Genoa (Zen 4), AVX-512, 8 vCPU (AWS c7a.2xlarge).**

## The Metric
**Lower is better.** Score = median latency in ms for `coset_lde_batch` on BabyBear 2^20 × 256.

Keep a change if: **incremental improvement over the previous kept state > 0.20% AND p < 0.05** (Criterion reports both). Compare each change against the most recent kept commit, not against the fixed session baseline.

## Target Files (writable)
- `monty-31/src/x86_64_avx512/packing.rs` — Montgomery field arithmetic AVX-512 (mul, add, sub, reductions)
- `monty-31/src/x86_64_avx512/utils.rs` — AVX-512 helpers
- `dft/src/radix_2_dit_parallel.rs` — DIT parallel FFT (first_half, second_half, dit_layer*)
- `dft/src/butterflies.rs` — butterfly implementations

`RUSTFLAGS="-C target-cpu=native"` is already set in eval.sh — AVX-512 codepath is active.

All other files are read-only.

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` (this file) to refresh constraints, target files, and evaluation criteria.
2. Read `iters.tsv` to understand what has been tried and what the current best is.
3. Read relevant source files to understand the current hot path.
4. Devise ONE targeted change. Think about what to change and why before touching code.
5. Edit the source file(s).
6. Run correctness check (~60s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/correctness.sh
   ```
   If tests fail: `git checkout -- .`, append `correctness_fail` row to `iters.tsv`, and try a different idea.
7. `git commit -am "iter N: <short description>"`
8. Run benchmark (~30s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh
   ```
9. Read the output. Extract change %, p-value, verdict.
10. If improvement > 0.20% AND p < 0.05: append `keep` row to `iters.tsv`.
11. If not: `git revert HEAD`, append `discard` row to `iters.tsv`.

## Logging

Append one tab-separated row to `iters.tsv` after every experiment. Create the file if it doesn't exist with this header:

```
iter	improvement_pct	p_value	status	files_changed	description
```

- `iter`: incrementing iteration number
- `improvement_pct`: % improvement (positive = faster), use `-` if correctness failed
- `p_value`: Criterion p-value, use `-` if correctness failed
- `status`: `keep`, `discard`, or `correctness_fail`
- `files_changed`: which file(s) were modified
- `description`: what you changed and why (no tabs)

Example rows:
```
1	+0.50	0.03	keep	packing.rs	shorter dependency chain in mul reduction — fewer serial vpmuludq
2	-1.20	0.00	discard	packing.rs	alternative add correction sequence — higher latency on Zen 3
3	-	-	correctness_fail	utils.rs	incorrect shift count in halve_avx512 — off-by-one overflow
```

## How to Evaluate

Save baseline once at the start of the session:
```bash
bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh --save-baseline
```

Then after each change:
```bash
bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh
```

## AVX512 Arithmetic Reference
Key functions in `monty-31/src/x86_64_avx512/`:
- `packing.rs` — `mul` (~line 524): 6.5 cyc/vec throughput, 21 cyc latency. Most expensive op.
- `packing.rs` — `add`, `sub`: ~1 cyc/vec
- `utils.rs` — `halve_avx512`: 2 cyc/vec
- `utils.rs` — `mul_neg_2exp_neg_n_avx512`: 3 cyc/vec, 9 cyc latency


## Context: Why Further Improvement Is Expected

5 surgical iterations on `packing.rs` were all discarded on Zen 4. The arithmetic is at a tight local optimum for single-instruction substitutions. However, a core Plonky3 contributor has confirmed that further improvements are likely — the current implementation was designed for a different microarchitecture and there is room left.

**Non-surgical changes are now permitted.** A change that touches more than 50 lines is allowed if:
1. It passes correctness (bitwise-identical DFT output)
2. It is motivated by a specific hypothesis, not a blind rewrite
3. Assembly is verified before and after with `get_assembly`

## Research Directions

Before coding, **search for relevant research papers** on:
- Montgomery multiplication AVX-512 — papers on faster modular arithmetic for ZK/NTT
- NTT butterfly optimization — latency hiding, instruction-level parallelism
- Zen 4 microarchitecture — execution unit layout, port throughput, out-of-order windows
- CIOS Montgomery multiplication — alternative reduction algorithm (fewer dependent multiplies)
- Karatsuba-based field multiplication for 31-bit primes

Use web search to find papers. Read abstracts and look for techniques applicable to 31-bit Montgomery fields on AVX-512.

## What to Optimize

**Confirmed dead (do not retry):**
- `vpminud→vpcmpgeud` in add/sub — regression on Zen 4, confirmed closed
- Inverse (`vpcmpgeud→vpminud` in mul correction) — null result
- `sub_epi64` tail fusion in mul — latency worse
- Removing `confuse_compiler` around q_evn/q_odd — compiler picks worse lowering
- `vpsrlq` instead of `vmovshdup` for lhs_odd — shuffle port not contested on Zen 4

**Still open:**
- **CIOS Montgomery reduction** — alternative to schoolbook: fewer serial `vpmuludq`, better instruction-level parallelism. Requires rewriting `mul` non-surgically. Read: "Montgomery Multiplication Using Vector Instructions" and similar.
- **Dependency chain across butterflies** — the DIT butterfly does mul+add+sub in sequence. If `radix_2_dit_parallel.rs` interleaves independent butterfly pairs, the OOO window can hide latency. Requires touching `dft/src/` alongside `packing.rs`.
- **`mul_neg_2exp_neg_n` substitution** — where twiddle factors are powers of 2, replace 6.5 cyc Montgomery mul with 3 cyc shift. Check how many butterfly layers use power-of-2 twiddles.
- **Lazy reduction** — accumulate unreduced values across multiple operations before final reduction. Requires understanding the field's overflow bounds for BabyBear (P = 2^31 - 2^27 + 1).
- **Alternative `partial_monty_red_*`** — restructure the signed/unsigned reduction variants to reduce critical path depth.

## Hard Constraints
1. No security parameter changes — do not touch `fri/`, `uni-stark/`, `batch-stark/`.
2. No interface changes — do not alter `TwoAdicSubgroupDft` or any public API.
3. No test value changes — do not modify expected values in tests.
4. No new `debug_assert!` — do not add debug assertions that weren't already there.
5. Correctness is mandatory — DFT output must be bitwise-identical to `Radix2Dit`.
6. Do not modify `eval.sh`, `correctness.sh`, or anything in `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/correctness-checker/`.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped. If you run out of surgical ideas, search the web for research papers on Montgomery multiplication, NTT optimization, and Zen 4 microarchitecture — then implement what you find. Non-surgical rewrites are permitted if they pass correctness and are hypothesis-driven.
