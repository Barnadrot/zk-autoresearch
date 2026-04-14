# Plonky3 AVX-512 Port Pressure Experiment — Constrained

## Role
You are an expert Rust systems programmer specializing in x86-64 microarchitecture. Your job is to test one specific hypothesis about AVX-512 port pressure in the Plonky3 Montgomery field `add` and `sub` operations on AMD Zen 4.

## Background

### The Change
In `monty-31/src/x86_64_avx512/packing.rs`, `add` and `sub` use `vpminud` for their conditional correction step. This experiment replaces it with `vpcmpgeud`/`vpcmpltud` + masked add/sub.

### How the Agent Found This
Three separate zk-autoresearch sessions independently converged on this same idea, with improving articulation each time:
- Session 1: found it but couldn't justify it — applied Intel port 0/5 reasoning directly to AMD without validation
- Session 2: found it again, same reasoning, slightly cleaner implementation
- Session 3: cleanest implementation, submitted as PR — still using Intel port methodology, but the empirical signal was strong enough to open

The pattern of three independent rediscoveries with decreasing p-values suggests the agent was finding a real signal, even if the explanation was wrong. The justification (port 0 contention) is Intel-specific and doesn't map directly to AMD execution units.

### PR Result on Zen 3 (Hetzner CCX33, EPYC Milan, AVX2 machine)
Single-size, cross-session Criterion benchmark, 60s measurement, 10 samples:
- **Median improvement: −1.59%, p=0.00**
- **Important caveat:** the benchmark ran on an AVX2 machine where AVX-512 codepath was not active. Rust compiled without `target-cpu=native` for the initial run — the improvement may have been in AVX2 fallback code, not the AVX-512 path we modified.

Independent validation by SyxtonPrime on the PR: "a mix of 1-2% increases but also nothing and some slowdowns." Not reproducible across environments.

### PR Review Objections (nbgl)
1. **Latency increase** — `vpminud` latency=1, `vpcmpud` latency=3 (Intel). Add goes 3→5 cyc, sub 3→4 cyc. Not a dealbreaker but not ideal.
2. **Port 0 may not be the bottleneck** — per-butterfly port count: port 0 has 8 instructions, port 5 has 5, shared 0/5 has 6. Both ports are already saturated — moving one instruction may not relieve anything.
3. **AMD mismatch** — the port 0/5 reasoning is Intel-specific. AMD has no equivalent port split. Any improvement observed on AMD is unexplained.

nbgl's conclusion: "not enough reason to think this is actually a helpful change" — requested benchmarks across wider workloads and microarchitectures before considering merge.

## This Experiment

**Purpose:** decisive cross-session, correct-cpu-flag validation on AMD Zen 4 (AVX-512 active).

If the effect is real — independent of the port pressure explanation — it should appear consistently on Zen 4 with `target-cpu=native` (AVX-512 codepath actually compiled and run). If it doesn't, the PR should be closed.

**Hardware: AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512 confirmed active.**

## The Hypothesis (restated)
Replacing `vpminud` with `vpcmpgeud`/`vpcmpltud` in `add`/`sub` produces measurable improvement on Zen 4 AVX-512. The mechanism may be port pressure, dependency chain restructuring, µop cache effects, or scheduler behavior — the goal of this experiment is empirical confirmation, not mechanistic explanation.

## The Metric
**Lower is better.** Score = median latency in ms for `coset_lde_batch` on BabyBear 2^20 × 256.

Keep a change if: **improvement > 0.20% AND p < 0.05**.

## Target File (writable)
- `~/zk-autoresearch/Plonky3/monty-31/src/x86_64_avx512/packing.rs` — specifically `add` and `sub` implementations

All other files are read-only.

## The One Change to Test

In `packing.rs`, find `add` and `sub`. They currently look roughly like:

```rust
// add: compute a + b, conditionally subtract P if result >= P
let sum = _mm512_add_epi32(a, b);
let corrected = _mm512_sub_epi32(sum, P);
let mask = _mm512_min_epu32(sum, corrected);  // vpminud — PORT 0
```

Replace the `vpminud` correction with `vpcmpgeud`/`vpcmpltud`:

```rust
// vpcmpgeud → mask where sum >= P → PORT 5, not PORT 0
let ge_p = _mm512_cmpge_epu32_mask(sum, P);
let result = _mm512_mask_sub_epi32(sum, ge_p, sum, P);
```

Apply the equivalent fix to `sub` (which uses `vpminud` to handle underflow via conditional add).

## Experiment Loop

Run exactly these steps — no more:

1. Read `iters.tsv` (create with header if missing).
2. Read `packing.rs` — find current `add` and `sub` implementations.
3. Use `get_assembly` to capture assembly BEFORE the change for `add` and `sub`.
4. Apply the change.
5. Use `get_assembly` to capture assembly AFTER — verify `vpminud` is gone, `vpcmpgeud`/`vpcmpltud` appears.
6. Run correctness check:
   ```bash
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/correctness.sh
   ```
   If fail: revert, log `correctness_fail`, stop.
7. `git -C ~/zk-autoresearch/Plonky3 commit -am "iter 1: vpminud→vpcmpgeud in add/sub — port 0→5 pressure shift"`
8. Save baseline:
   ```bash
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh --save-baseline
   ```
9. Run benchmark 3 times (back-to-back, same session):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh
   bash ~/zk-autoresearch/experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/eval.sh
   ```
10. Report all three change% and p-values. Log the median result in `iters.tsv`.
11. If all 3 show improvement > 0.20% AND p < 0.05: `keep`. Otherwise: revert + `discard`.

**Stop after this one experiment.** Do not continue to other ideas.

## Logging

`iters.tsv` header:
```
iter	improvement_pct	p_value	status	files_changed	description
```

## Hard Constraints
1. Only edit `monty-31/src/x86_64_avx512/packing.rs`.
2. No security parameter changes — do not touch `fri/`, `uni-stark/`, `batch-stark/`.
3. No interface changes — do not alter public API.
4. No test value changes.
5. Correctness mandatory — DFT output must be bitwise-identical to `Radix2Dit`.
6. Do not modify `eval.sh`, `correctness.sh`, or anything in `~/zk-autoresearch/experiment_logs/`.

## Expected Assembly Change

Before: `vpminud zmm*, zmm*, zmm*` in the add/sub hot path  
After: `vpcmpgeud k*, zmm*, zmm*` + `vpsubd zmm*, zmm{k*}, zmm*`

If assembly doesn't change, the compiler optimized it back — report this and stop.
