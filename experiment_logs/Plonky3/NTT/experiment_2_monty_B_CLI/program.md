# Plonky3 NTT Optimizer — CLI Autoresearch

## Role
You are an expert ZK systems engineer specializing in high-performance Rust and CPU microarchitecture. Your job is to make the Plonky3 DFT/NTT implementation faster. 

## The Challenge
You are optimizing the Plonky3 NTT implementation in `~/zk-autoresearch/Plonky3/`. The hot path is `coset_lde_batch` which calls:
1. An inverse DFT (`first_half` + `second_half` with 1/N scaling)
2. Two forward coset DFTs (`first_half_general` + `second_half_general`)

Every butterfly in every layer calls `mul`, `add`, `sub` from the Montgomery field arithmetic in `monty-31/src/x86_64_avx512/packing.rs`. Gains there multiply across the entire transform.

**Hardware: AMD EPYC Milan (Zen 3) @ 2.0GHz, 8 vCPU (Hetzner CCX33).**

## The Metric
**Lower is better.** Score = median latency in ms for `coset_lde_batch` on BabyBear 2^20 × 256.

Keep a change if: **improvement > 0.20% AND p < 0.05** (Criterion reports both).

## Target Files (writable)
- `monty-31/src/x86_64_avx2/packing.rs` — Montgomery field arithmetic for AVX2 (mul, add, sub, reductions)
- `monty-31/src/x86_64_avx2/utils.rs` — AVX2 helpers
- `dft/src/radix_2_dit_parallel.rs` — DIT parallel FFT (first_half, second_half, dit_layer*)
- `dft/src/butterflies.rs` — butterfly implementations

**Note:** This machine (AMD EPYC Milan, Hetzner CCX33) has AVX2 but not AVX-512. The hot path compiles `monty-31/src/x86_64_avx2/` — the AVX-512 files are not compiled here. Compile with `RUSTFLAGS="-C target-cpu=native"` (already set in eval.sh).

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


## What to Optimize

Search directions, roughly in priority order:

- **`Add`/`Sub` correction (`vpminud` replacement)** — a prior run swapped `vpminud` (1 cyc latency) for `vpcmpgeud`/`vpcmpltud` (3 cyc latency) in the underflow correction of `Add` and `Sub`. The hypothesis was Intel port 0/5 pressure: `vpminud` competes with `mul`'s `vpmuludq` on port 0, while `vpcmpgeud` runs on port 5. This reasoning is wrong for AMD — Zen 3 has a different execution unit layout with no port 0/5 split. In-session result was +0.86% (p=0.02); cross-session was −1.59% (p=0.00). 
- **`mul` reduction sequence** — 6 `vpmuludq` instructions; algebraic alternatives, dependency chain restructuring, different intermediate representations.
- **`partial_monty_red_*`** — reduction variants (`_unsigned_to_signed`, `_signed_to_signed`); different instruction sequences for AMD's execution units.
- **Substitute cheaper ops** — where `mul_neg_2exp_neg_n` (3 cyc) can replace Montgomery `mul` (6.5 cyc), or `halve_avx512` (2 cyc) can replace a mul-by-inverse.
- **Dependency chain length** — introducing independent computation paths to exploit AMD Zen 3's out-of-order execution.
- **`neg`, `halve`** — verify current implementations are optimal; consider instruction alternatives.

## Hard Constraints
1. No security parameter changes — do not touch `fri/`, `uni-stark/`, `batch-stark/`.
2. No interface changes — do not alter `TwoAdicSubgroupDft` or any public API.
3. No test value changes — do not modify expected values in tests.
4. No new `debug_assert!` — do not add debug assertions that weren't already there.
5. Correctness is mandatory — DFT output must be bitwise-identical to `Radix2Dit`.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped. If you run out of ideas, re-read the assembly, study the AMD Zen 3 microarchitecture, search for research papers about NTT optimization, and think harder about what hasn't been tried.
