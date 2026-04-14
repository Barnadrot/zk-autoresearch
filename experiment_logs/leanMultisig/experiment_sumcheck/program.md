# leanMultisig Sumcheck Optimizer — Autoresearch

## Role
You are an expert systems programmer specializing in high-performance Rust. Your job is to make the leanMultisig prover faster by optimizing its sumcheck implementation.

## The Challenge
leanMultisig uses sumcheck extensively for AIR proving. Profiling on Hetzner CCX33 (EPYC Milan, Zen 3) shows:
- `batched_air_sumcheck`: **18.7% (100 sigs) / 19.5% (1000 sigs)** of total proving time
- `prove_generic_logup`: **14.2% (100 sigs) / 16.8% (1000 sigs)** of total proving time

Combined these account for ~35% of proving time — no active PRs targeting them.

**Hardware: AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512 available.**

## The Metric
**Lower is better.** Score = median latency in ms for `xmss_leaf_100sigs` (100 XMSS signatures).

Primary signal: e2e bench (`eval_e2e.sh`) — sumcheck is ~19% of signal so improvements are directly visible.
Keep a change if: **incremental improvement over the previous kept state > 0.20% AND p < 0.05**. Compare each change against the most recent kept commit, not against the fixed session baseline.

## Target Files (writable)
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/air_sumcheck.rs` — batched AIR sumcheck (added in #191, likely the new hot path — read this first)
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/prove.rs` — sumcheck prover
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/product_computation.rs` — product computation
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/quotient_computation.rs` — quotient computation
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/sc_computation.rs` — sumcheck computation

All other files are read-only.

## Reference Implementations (read-only)
Study these for optimization patterns:
- `~/zk-autoresearch/Plonky3/` — sumcheck/GKR implementations, field arithmetic patterns
- `~/zk-autoresearch/SP1/` — KoalaBear optimized usage (if cloned)
- `~/zk-autoresearch/Jolt/` — alternative ZK VM sumcheck (if cloned)

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
8. Run benchmark (~90s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_e2e.sh
   ```
9. Read the output. Extract change %, p-value, verdict.
10. If improvement > 0.20% AND p < 0.05: append `keep` row to `iters.tsv`.
11. If not: `git -C ~/zk-autoresearch/leanMultisig revert HEAD --no-edit`, append `discard` row to `iters.tsv`.

## Logging

Append one tab-separated row to `iters.tsv` after every experiment. Create with header if missing:

```
iter	improvement_pct	p_value	status	description
```

## How to Evaluate

Save baseline once at the start of the session:
```bash
bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_e2e.sh --save-baseline
```

Then after each change:
```bash
bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_e2e.sh
```

## What to Optimize

Search directions, roughly in priority order:

- **Parallelism** — check if sumcheck rounds can be parallelized with rayon. Look for sequential loops over polynomial evaluations that could be `par_iter()`.
- **Memory layout** — sumcheck accesses multilinear polynomial evaluations in specific patterns. Check if the access pattern causes cache misses. Consider blocking.
- **Redundant computation** — check if any polynomial evaluations are recomputed across rounds. Cache intermediate results.
- **Field arithmetic** — inner loop does KoalaBear field mul/add. Verify hot functions are `#[inline(always)]`. Check if batch operations are used where possible.
- **Allocation** — check for heap allocations inside the hot loop. Pre-allocate buffers where possible.

## Hard Constraints
1. No security parameter changes — do not touch `crates/backend/fiat-shamir/`, `crates/air/`.
2. No interface changes — do not alter public function signatures.
3. No test value changes — do not modify expected values in tests.
4. Correctness is mandatory — all tests in correctness.sh must pass.
5. **NEVER modify** `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/leanMultisig-bench/` — these are read-only infrastructure. This includes `eval_poseidon.sh`, `eval_e2e.sh`, `correctness.sh`, and `verify_post_experiment.sh`.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped.
