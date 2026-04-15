# leanMultisig Sumcheck Optimizer — Autoresearch

## Role
You are an expert ZK systems engineer specializing in high-performance Rust and CPU microarchitecture. Your job is to make the leanMultisig prover faster by optimizing its sumcheck implementation.

## The Challenge
leanMultisig uses sumcheck extensively. Production profiling at 1400 sigs on Zen 4 (c7a.2xlarge) shows:

| Component | % total | Span |
|---|---|---|
| `prove_generic_logup` | **18.06%** | `sub_protocols/src/logup.rs` |
| `batched_air_sumcheck` | **15.43%** | `sub_protocols/src/air_sumcheck.rs` |
| `run_product_sumcheck` (inside WHIR) | **9.12%** | `backend/sumcheck/src/product_computation.rs` |
| **Total sumcheck-adjacent** | **~43%** | |

All three call into `backend/sumcheck/src/prove.rs` (`sumcheck_prove_many_rounds`) — the shared hot loop. An improvement there hits all three.

**Hardware: AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512 available.**

## Inspiration Repos (source reference)

Three repos are cloned under `~/zk-autoresearch/` for reference:

| Repo | Built | Notes |
|---|---|---|
| `Plonky3/` | yes | Read sumcheck/NTT patterns |
| `jolt/` | yes | Read sumcheck/GKR patterns |
| `sp1/` | source only | Requires CUDA (GPU) + `succinct` custom toolchain — not built on this CPU server. Source files readable. |

Use `read_file` on any of these for inspiration. Do not modify them.

## The Metric
**Lower is better.** Score = median latency in ms for `xmss_leaf_1400sigs` (1400 XMSS signatures).

Primary signal: e2e bench (`eval_e2e.sh`) — sumcheck is ~43% of signal so improvements are directly visible.

**Keep a change if: incremental improvement over the previous kept state > 0.20% AND p < 0.05.**
Compare each change against the most recent kept commit, not against the fixed session baseline.

## Target Files (writable)

### Core sumcheck engine — hits all three callers
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/prove.rs` — `sumcheck_prove_many_rounds`: the shared inner round loop, called by everything. **Start here.**
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/sc_computation.rs` — `SumcheckComputation` trait impls: `eval_base`, `eval_packed_base`, `eval_packed_extension`. Hot path per round.
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/product_computation.rs` — `run_product_sumcheck` + `compute_product_sumcheck_polynomial_base_ext_packed` (packed hot path for WHIR)
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/quotient_computation.rs` — `GKRQuotientComputation`: `sum_fractions_const_2_by_2` is the inner kernel for logup GKR

### Protocol layer — caller-specific
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/air_sumcheck.rs` — `prove_batched_air_sumcheck`: batched AIR sumcheck driver
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/logup.rs` — `prove_generic_logup`: Logup GKR driver, data prep + GKR rounds

All other files are **read-only**.

## Read-Only — DO NOT MODIFY

| Path | Reason |
|---|---|
| `crates/backend/fiat-shamir/` | Transcript + challenger — security-critical |
| `crates/backend/air/` | AIR constraint definitions |
| `crates/backend/field/` | Field arithmetic primitives |
| `crates/backend/koala-bear/` | KoalaBear field implementations |
| `crates/whir/` | WHIR protocol |
| `crates/backend/sumcheck/src/verify.rs` | Verifier — never touch |
| Any `tests/` directory | Do not modify test values |
| `~/zk-autoresearch/experiment_logs/` | Infrastructure — read-only |
| `~/zk-autoresearch/leanMultisig-bench/` | Bench crate — read-only |

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
8. Run benchmark (~9 min):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_e2e.sh
   ```
9. Read the output. Extract change %, p-value, verdict.
10. If improvement > 0.20% AND p < 0.05: append `keep` row to `iters.tsv`.
11. If not: `git -C ~/zk-autoresearch/leanMultisig revert HEAD --no-edit`, append `discard` row to `iters.tsv`.

## Logging

Append one tab-separated row to `iters.tsv` after every experiment. Create with header if missing:

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
1	+1.20	0.02	keep	prove.rs	remove Vec::new() inside round loop — eliminates per-round alloc
2	-0.80	0.00	discard	sc_computation.rs	alternative packed eval order — higher latency on Zen 4
3	-	-	correctness_fail	quotient_computation.rs	incorrect alpha accumulation — sum_fractions output wrong
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

## Surgical Precision Principle

**Start surgical.** A change is surgical if it touches fewer than ~50 lines and targets a specific hot path. Begin with the cheapest hypotheses first — allocation removal, inline annotations, packed path verification.

**Escalation order when surgical ideas are exhausted (5+ discards in a row with no keeps):**
1. Read inspiration repos (`~/zk-autoresearch/jolt/`, `~/zk-autoresearch/sp1/`, `~/zk-autoresearch/Plonky3/`) for concrete implementation patterns
2. Search the web for research papers on sumcheck, GKR, and multilinear arithmetic
3. Non-surgical restructuring — only if motivated by a specific hypothesis and passing correctness

## What to Optimize

Search directions in priority order:

1. **`sumcheck_prove_many_rounds` hot loop** (`prove.rs:117`) — the round loop iterates `n_vars` times, calling `compute_and_send_polynomial` each round. Check for redundant allocations (`Vec::new()` inside loop), sequential work that could be parallelized, unnecessary clones.

2. **Packed base path** (`sc_computation.rs`, `product_computation.rs`) — the `eval_packed_base` / `eval_packed_extension` functions are the inner kernel. Verify `#[inline(always)]` is present. Check if the packed path is actually being hit (look for `is_packed()` checks in `prove.rs:118`).

3. **`compute_product_sumcheck_polynomial_base_ext_packed`** (`product_computation.rs`) — specialised path for base×extension packed. Uses `rayon::par_chunks`. Check chunk sizes, par overhead vs sequential threshold.

4. **`GKRQuotientComputation` inner kernel** (`quotient_computation.rs`) — `sum_fractions_const_2_by_2` runs every GKR round. Verify it inlines. Check if alphas dot product can be simplified.

5. **Allocation inside loops** — `prove_generic_logup` builds `numerators` / `denominators_packed` vecs. Check if they can be pre-allocated or reused across calls.

6. **`SplitEq`** — used in `prove.rs` for the eq factor. `truncate_half()` is called every round. Check if it allocates.

## Research Directions

Before coding, **search for relevant research papers** on:
- Sumcheck protocol optimizations — batching, parallelism, round reduction
- GKR protocol — efficient prover implementations, lookup argument variants
- Lasso / Spartan — alternative sumcheck-based approaches for lookup arguments
- Multilinear extension arithmetic — packed evaluation tricks, eq-polynomial optimizations
- WHIR / FRI-based polynomial commitments — prover bottlenecks

Use web search to find papers. Read abstracts and look for techniques applicable to the current implementation. Also read the source of inspiration repos (`~/zk-autoresearch/sp1/`, `~/zk-autoresearch/jolt/`, `~/zk-autoresearch/Plonky3/`) for concrete implementation patterns.

## Hard Constraints
1. No security parameter changes — do not touch `crates/backend/fiat-shamir/`, `crates/air/`.
2. No interface changes — do not alter public function signatures.
3. No test value changes — do not modify expected values in tests.
4. Correctness is mandatory — all tests in correctness.sh must pass.
5. **NEVER modify** `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/leanMultisig-bench/`.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped.
