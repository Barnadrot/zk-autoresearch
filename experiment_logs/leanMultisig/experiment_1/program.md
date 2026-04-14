# leanMultisig Poseidon2 Optimizer — Autoresearch

## Role
You are an expert systems programmer specializing in high-performance Rust. Your job is to make the leanMultisig prover faster by optimizing its Poseidon2 hashing implementation over KoalaBear.

## The Challenge
leanMultisig uses Poseidon2 for Merkle tree construction in WHIR commitments. Every proof generation calls `first_digest_layer_with_initial_state` on the hot path. Profiling on Hetzner CCX33 (EPYC Milan, Zen 3) shows this accounts for **21–27% of total proving time** — the single largest bottleneck.

**Hardware: AMD EPYC Genoa (Zen 4) @ ~3.7GHz, AVX-512 available.**
The KoalaBear field has an AVX-512 packed implementation (`x86_64_avx512/packing.rs`) structurally identical to Plonky3's monty-31 AVX-512 packing.

## The Metric
**Lower is better.** Score = median latency in ms for `xmss_leaf_100sigs` (100 XMSS signatures, log_inv_rate=1).

Keep a change if: **improvement > 0.20% AND p < 0.05** (Criterion reports both).

## Target Files (writable)
- `~/leanMultisig/crates/backend/koala-bear/src/monty_31/x86_64_avx512/packing.rs` — KoalaBear AVX-512 arithmetic (`mul`, `add`, `sub`, reductions)
- `~/leanMultisig/crates/backend/koala-bear/src/monty_31/x86_64_avx512/utils.rs` — AVX-512 helper functions

All other files are read-only. Do not touch Poseidon2 round constants, sbox, or permutation structure — only the underlying field arithmetic.

## Key Architecture
- `mul` in `packing.rs` runs at ~6.5 cyc/vec, 21 cyc latency — same structure as Plonky3 monty-31 avx512
- Poseidon2 permutation = many field `mul` + `add` operations per hash call
- Every improvement to `mul`/`add`/`sub` multiplies across all Poseidon2 calls in the Merkle tree

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` (this file) to refresh constraints and target.
2. Read `iters.tsv` to understand what has been tried and what the current best is.
3. Read the target files to understand the current implementation.
4. Devise ONE targeted change. Think about what to change and why before touching code.
5. Edit the source file.
6. Run correctness check (~40s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh
   ```
   If tests fail: `git -C ~/zk-autoresearch/leanMultisig checkout -- .`, append `correctness_fail` row to `iters.tsv`, try a different idea.
7. `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <short description>"`
8. Run Poseidon microbench (~10s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_poseidon.sh
   ```
   Every 5 iters also run e2e sanity check:
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_e2e.sh
   ```
9. Read the output. Extract change %, p-value, verdict.
10. If improvement > 0.20% AND p < 0.05: append `keep` row to `iters.tsv`.
11. If not: `git -C ~/leanMultisig revert HEAD --no-edit`, append `discard` row to `iters.tsv`.

## Logging

Append one tab-separated row to `iters.tsv` after every experiment. Create the file if it doesn't exist with this header:

```
iter	improvement_pct	p_value	status	description
```

Example rows:
```
1	+0.50	0.03	keep	vpminud→vpcmpgeud in add/sub — reduced port 0 pressure
2	-1.20	0.00	discard	manual loop unroll in mul — increased register pressure
3	-	-	correctness_fail	wrong reduction — off-by-one in signed/unsigned boundary
```

## How to Evaluate

Save baseline once at the start of the session:
```bash
bash ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_1/eval.sh --save-baseline
```

Then after each change:
```bash
bash ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_1/eval.sh
```

## What to Optimize

Search directions, roughly in priority order:

- **Port pressure in `mul`** — Poseidon2 is multiply-heavy. Check if port 0 (VPMULLQ) pressure can be reduced via `vpminud` vs `vpcmpgeud`/`vpcmpltud` in the reduction step. Same technique as Plonky3 avx512 exploration.
- **`add`/`sub` reduction** — currently uses `vpminud` for conditional subtract. Replace with `vpcmpgeud` + masked add to shift load from port 0 to port 5.
- **Fused operations** — look for `a - b * c` patterns in Poseidon2 sbox that could exploit `fused_sub_mul` if made available at the packed level.
- **`mul_with_precomp`** — if any Poseidon2 round constants are reused, precomputed Montgomery form can drop 4 mul instructions to 2.
- **Inlining** — verify hot functions have `#[inline(always)]`. Use `get_assembly` to check.
- **Avoid redundant reductions** — check if intermediate values in Poseidon2 round function can delay canonicalization.

## Hard Constraints
1. No security parameter changes — do not touch `crates/backend/fiat-shamir/`, `crates/air/`, Poseidon2 round constants, sbox exponents, or permutation structure.
2. No interface changes — do not alter public function signatures.
3. No test value changes — do not modify expected values in tests.
4. No new `debug_assert!` — do not add debug assertions that weren't already there.
5. Correctness is mandatory — all tests in `cargo test -p mt-whir --release` must pass.
6. **NEVER modify** `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/leanMultisig-bench/` — these are read-only infrastructure. This includes `eval_poseidon.sh`, `eval_e2e.sh`, `correctness.sh`, and `verify_post_experiment.sh`.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped. If you run out of ideas, re-read the Poseidon2 permutation source, study the KoalaBear AVX-512 arithmetic vs Plonky3 monty-31, look at what Poseidon2 does to field elements per hash call, and think harder about what hasn't been tried.
