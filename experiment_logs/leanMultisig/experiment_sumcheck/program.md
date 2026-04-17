# leanMultisig Sumcheck Optimizer — Autoresearch

## Role
You are an expert ZK systems engineer specializing in high-performance Rust and CPU microarchitecture. Your job is to make the leanMultisig prover faster by optimizing its sumcheck implementation and adjacent hot-path code reachable from it.

## The Challenge
leanMultisig uses sumcheck extensively. Production profiling at 1400 sigs on Zen 4 (c7a.2xlarge) originally reported:

| Component | % total (claimed, inclusive) | Span |
|---|---|---|
| `prove_generic_logup` | 18.06% | `sub_protocols/src/logup.rs` |
| `batched_air_sumcheck` | 15.43% | `sub_protocols/src/air_sumcheck.rs` |
| `run_product_sumcheck` (inside WHIR) | 9.12% | `backend/sumcheck/src/product_computation.rs` |
| **Total sumcheck-adjacent** | **~43%** | |

**Profile re-validated 2026-04-15 (`report/bench_profile.md`)** shows the picture is more nuanced. *Self* time inside `mt_sumcheck::*` is only ~3 %; the remaining sumcheck-adjacent work is inside code the sumcheck crate *calls into* — `mt_poly::eq_mle::eval_eq_with_packed_output` (~11 %), `mt_koala_bear::quintic_extension::quintic_mul` and related field arithmetic (~13.5 %), and Poseidon permute (~20 %, much of it via AIR/fiat-shamir). Treat the 43 % figure as inclusive time for the sumcheck call tree — direct edits inside the writable sumcheck files will produce correspondingly small e2e deltas unless they reshape how the callees are invoked (e.g. eliminate redundant field operations, change packing strategy, improve SIMD fit).

All three primary callers route through `backend/sumcheck/src/prove.rs` (`sumcheck_prove_many_rounds`). An improvement there hits all three.

**Hardware: AMD EPYC Genoa (Zen 4) @ c7a.2xlarge, AVX-512 available, KVM virtualized (no CPU pinning / turbo controls available from guest).**

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

Primary signal: full e2e bench through `eval_paired.sh` (see "How to Evaluate").

## Target Files (writable)

### Core sumcheck engine — hits all three callers
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/prove.rs` — `sumcheck_prove_many_rounds`: shared inner round loop. **Start here.**
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/sc_computation.rs` — `SumcheckComputation` trait impls: `eval_base`, `eval_packed_base`, `eval_packed_extension`.
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/product_computation.rs` — `run_product_sumcheck` + `compute_product_sumcheck_polynomial_base_ext_packed` (packed hot path for WHIR)
- `~/zk-autoresearch/leanMultisig/crates/backend/sumcheck/src/quotient_computation.rs` — `GKRQuotientComputation` inner kernel for logup GKR

### Protocol layer — caller-specific
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/air_sumcheck.rs` — `prove_batched_air_sumcheck`: batched AIR sumcheck driver
- `~/zk-autoresearch/leanMultisig/crates/sub_protocols/src/logup.rs` — `prove_generic_logup`: Logup GKR driver, data prep + GKR rounds

### Multilinear kernel — hit every sumcheck round, also used by WHIR (~3 % self / ~11 % inclusive)
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/eq_mle.rs` — `eval_eq*`, `compute_eval_eq*`, `eval_eq_with_packed_output`
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/next_mle.rs`
- `~/zk-autoresearch/leanMultisig/crates/backend/poly/src/mle/` (all files) — multilinear-extension containers

### Quintic extension field arithmetic — inner kernel of every sumcheck/WHIR round (~13.5 % self)
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/extension.rs` — scalar `quintic_mul`, `quintic_square`, `QuinticExtensionField`
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/packed_extension.rs` — `PackedQuinticExtensionField::mul`, packed operators
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/packing.rs` — packed representation helpers
- `~/zk-autoresearch/leanMultisig/crates/backend/koala-bear/src/quintic_extension/mod.rs`

All other files are **read-only**.

## Read-Only — DO NOT MODIFY

| Path | Reason |
|---|---|
| `crates/backend/fiat-shamir/` | Transcript + challenger — security-critical |
| `crates/backend/air/` | AIR constraint definitions |
| `crates/backend/field/` | Field arithmetic primitives |
| `crates/backend/koala-bear/src/monty_31/` | Montgomery arithmetic — foundational |
| `crates/backend/koala-bear/src/poseidon*` | Hash primitive — security-critical |
| `crates/backend/koala-bear/src/koala_bear.rs` | Base field definition |
| `crates/backend/koala-bear/src/symmetric.rs` | Symmetric primitives |
| `crates/backend/koala-bear/src/x86_64_avx*/` | AVX packing (base field level) |
| `crates/backend/koala-bear/src/aarch64_neon/` | ARM packing |
| `crates/backend/koala-bear/src/quintic_extension/tests.rs` | Property tests — integrity-checked by `correctness.sh` |
| `crates/backend/poly/src/` (except `eq_mle.rs`, `next_mle.rs`, `mle/`) | Other poly utilities |
| `crates/whir/` | WHIR protocol |
| `crates/backend/sumcheck/src/verify.rs` | Verifier — never touch |
| Any `tests/` directory | Do not modify test values |
| `~/zk-autoresearch/experiment_logs/` | Infrastructure — read-only |
| `~/zk-autoresearch/leanMultisig-bench/` | Bench crate — read-only |

## Gate & Keep Rule (primary reference)

Each change passes through up to three stages. Wall-clock alone cannot resolve the kind of sub-% wins this loop is expected to produce on c7a.2xlarge (measured paired σ ≈ 0.6–0.9 % on real changes, see `report/threshold_calibration.md`). **iai is the primary signal. Wall-clock is the sanity check.**

### Stage 1 — iai-callgrind instruction-count gate  (primary signal)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_iai.sh`

- Runs `iai_driver` under callgrind on baseline (HEAD~1) and candidate (HEAD). `target-cpu=znver3` (not native) — valgrind 3.18/3.23 cannot emulate Zen 4 VNNI/VBMI2.
- Tracks per-symbol `Ir` for sumcheck + adjacent hot paths.
- **PASS** = any tracked symbol dropped ≥ `IAI_MIN_DROP_PCT` (0.10 %) AND no tracked symbol regressed by more than `IAI_MAX_REGR_PCT` (0.05 %).
- Exit 0 on PASS, 1 on FAIL, 2 on infra error.

**Escape hatch (`[wallclock-only]` tag in commit body):** for changes whose value lives in SIMD scheduling, port pressure, unroll factor, `confuse_compiler` hints, rayon chunk-size tuning, or Zen 4-specific VNNI/VBMI2 usage. Skips Stage 1, goes directly to Stage 2 with a strict threshold. Use sparingly.

### Stage 2 — paired wall-clock  (sanity check when iai passed; primary gate for wallclock-only)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_paired.sh`

- Builds both binaries with `cargo clean --release` between, syncs `git checkout` to match each binary being executed (avoids the `main.py`-loaded-at-runtime hazard).
- Asserts distinct md5 hashes.
- Burn-in invocation, then single paired A/B in loop mode.
- Interpretation is hybrid — see the rules table below.

### Stage 3 — revert-A/B  (marginal keeps only)
`bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_revert_ab.sh <claim_delta_pct>`

- Triggered when `|stage2 median_Δ| < MARGINAL_MULT × KEEP_THRESHOLD_PCT` (currently 3.0 %).
- Creates temporary revert on top of HEAD, re-runs paired A/B.
- Reverting the keep must reproduce ≥ 50 % of the claimed improvement.
- Cleans up its revert commit before returning. Loop must unwind the kept commit on failure.

### Combined decision table

| Stage 1 (iai) | `[wallclock-only]` | Stage 2 (paired median Δ%) | Stage 2 p | Keep? | Run Stage 3 revert-A/B? |
|---|---|---|---|---|---|
| PASS | no | `Δ ≥ +0.5 %` AND `p < 0.05` | | **NO** — iai-positive + wall-clock clearly worse = cache/ILP conflict |
| PASS | no | `Δ < +0.5 %` (no clear regression) | | YES | YES if `|Δ| < 3.0 %` |
| FAIL | no | — | — | NO — `discard_iai` | — |
| (skipped) | yes | `Δ ≤ −1.5 %` | `p < 0.01` | YES | YES if `|Δ| < 3.0 %` |
| (skipped) | yes | otherwise | — | NO — `discard_wallclock` | — |

### Periodic audit (every 5 keeps)
Run full-stack revert-A/B against the state at the start of that 5-keep window. Unwind every keep back to that window's start if any single revert-A/B fails.

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` (this file) and `iters.tsv`.
2. Read the target files to understand the current hot path.
3. Devise ONE targeted change. State the hypothesis — what you change, why it's faster, what signal you expect (iai Ir drop, paired Δ, or both). If the hypothesis is SIMD/rayon-shaped, note that the change will use the `[wallclock-only]` tag.
4. Edit the source file.
5. Run correctness check (~12 s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh
   ```
   If tests fail: `git -C ~/zk-autoresearch/leanMultisig checkout -- .`, log `correctness_fail`, try a different idea.
6. Commit: `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <short description>"`
   Include `[wallclock-only]` in the commit body if opting out of the iai gate.
7. Run the gate (~7-11 min):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_gate.sh
   ```
   This runs iai → paired → revert-A/B (if marginal) automatically and outputs a single verdict.
   Read `/tmp/eval_gate_summary.json` for verdict and all iters.tsv fields.
8. If verdict = `KEEP`: log keep row to `iters.tsv`. After every 5 keeps, run the periodic audit.
9. If verdict = `DISCARD`: `git -C ~/zk-autoresearch/leanMultisig revert HEAD --no-edit`, log discard row with status from summary.

For debugging or hypothesis-specific runs, individual scripts are available:
`eval_iai.sh`, `eval_paired.sh`, `eval_revert_ab.sh` (see `shared/README.md`).

## Rolling baseline — automatic
`eval_paired.sh` always compares `HEAD~1` vs `HEAD`, not a fixed session baseline. This means every keep rotates the baseline by construction. No separate "save baseline after keep" step is required.

## Logging — `iters.tsv`

Append one tab-separated row after every experiment. Create with header if missing:

```
iter  stage1_iai_delta  stage1_iai_decision  stage2_median_pct  stage2_p  revert_ab  base_hash  cand_hash  status  files_changed  rationale
```

Fields:
- `iter` — incrementing integer
- `stage1_iai_delta` — `total_tracked_delta_pct` from eval_iai_summary.json, or `-` if skipped (escape hatch) or not run
- `stage1_iai_decision` — `PASS` / `FAIL` / `SKIP` (escape hatch) / `-` (not run)
- `stage2_median_pct` — median Δ% from eval_paired_summary.json, or `-`
- `stage2_p` — paired p-value, or `-`
- `revert_ab` — `pass` / `fail` / `n/a`
- `base_hash`, `cand_hash` — from eval_paired_summary.json. Identical hashes = infra failure; verify before logging keep.
- `status` — one of: `keep`, `discard_iai`, `discard_wallclock`, `revert_ab_failed`, `correctness_fail`, `infra_fail`
- `files_changed` — which writable file(s) were modified
- `rationale` — what you changed AND why you expected it to help. No tabs. The discard trail is reviewed by humans; a hypothesis-free discard wastes that review.

Example rows:
```
1   -0.45  PASS  -0.92  0.003  n/a   a09e...  7eab...  keep               prove.rs          hoist Vec::new() out of round loop — hypothesis: per-round alloc eliminated
2   -      SKIP  -1.60  0.001  pass  81ba...  93fd...  keep               sc_computation.rs [wallclock-only] pack-base SIMD reorder to avoid vpmullq dep chain
3   +0.01  FAIL  -      -      n/a   -        -        discard_iai        product_computation.rs  speculative early termination — iai showed +0.01% Ir, rejected
4   -0.20  PASS  +0.15  0.42   n/a   ...      ...      discard_wallclock  quotient_computation.rs iai passed but wall clock regressed — likely cache/ILP conflict
5   -      -     -      -      n/a   -        -        correctness_fail   logup.rs          incorrect alpha accumulation
```

## Surgical Precision Principle

**Start surgical.** A change is surgical if it touches fewer than ~50 lines and targets a specific hot path. Begin with the cheapest hypotheses first — allocation removal, inline annotations, packed path verification.

**Escalation order when surgical ideas are exhausted (5+ discards in a row with no keeps):**
1. Read inspiration repos (`~/zk-autoresearch/jolt/`, `~/zk-autoresearch/sp1/`, `~/zk-autoresearch/Plonky3/`) for concrete implementation patterns
2. Search the web for research papers on sumcheck, GKR, and multilinear arithmetic
3. Non-surgical restructuring — only if motivated by a specific hypothesis and passing correctness

## What to Optimize

Search directions in priority order. The writable surface now covers the full sumcheck compute graph: orchestration (`mt_sumcheck`), multilinear kernel (`eq_mle`), and field arithmetic (`quintic_extension`). Combined self-time: ~19.5 %.

### Tier 1 — Highest self-time targets (quintic_extension ~13.5 %)
1. **`quintic_mul` / `quintic_square`** (`extension.rs`) — scalar quintic multiplication is the inner kernel of every sumcheck and WHIR round. Reduction polynomial is `X^5 + X^2 - 1`. Check for redundant temporaries, sub-optimal Karatsuba-style decomposition, missed constant-folding.
2. **`PackedQuinticExtensionField::mul`** (`packed_extension.rs`) — packed variant, dispatches through `QuinticExtendableAlgebra`. Check SIMD width utilization, dep-chain structure. `[wallclock-only]` territory for AVX-512 scheduling changes.
3. **`quintic_mul_packed`** (`packing.rs`) — platform-specific implementations (scalar fallback, AVX2, AVX-512). The AVX-512 path is the hot one on this hardware.

**Assembly verification:** for any change in `packing.rs` or `packed_extension.rs`, inspect compiler output before and after to verify the expected SIMD instructions are emitted:
```bash
cargo asm -p mt-koala-bear --release "quintic_mul"
```

### Tier 2 — Multilinear kernel (eq_mle ~3 % self / ~11 % inclusive)
4. **`eval_eq_with_packed_output` / `compute_eval_eq_packed`** (`eq_mle.rs`) — dominant multilinear kernel, ~11 % inclusive under sumcheck call tree. Called from `split_eq.rs` every round and from WHIR `open.rs`. Check vectorization, allocation patterns, unnecessary copies.
5. **`SplitEq`** — used in `prove.rs` for the eq factor. `truncate_half()` every round. Check if it allocates.

### Tier 3 — Sumcheck orchestration (~3 %)
6. **`sumcheck_prove_many_rounds` round loop** (`prove.rs`) — redundant allocations (`Vec::new()` inside loop), sequential work that could be parallelized, unnecessary clones, redundant field ops.
7. **Packed base path** (`sc_computation.rs`, `product_computation.rs`) — `eval_packed_base` / `eval_packed_extension` inner kernels. Verify `#[inline(always)]`. Check whether the packed path is actually being hit.
8. **`compute_product_sumcheck_polynomial_base_ext_packed`** (`product_computation.rs`) — specialised base×extension packed path, uses `rayon::par_chunks`. Chunk sizes, parallelism threshold. `[wallclock-only]` territory.
9. **`GKRQuotientComputation` inner kernel** (`quotient_computation.rs`) — `sum_fractions_const_2_by_2` runs every GKR round. Verify inlining. Alphas dot product simplification.
10. **Allocation inside loops** — `prove_generic_logup` builds `numerators` / `denominators_packed` vecs. Pre-allocate or reuse across calls.

## Research Directions

Before coding, search for relevant research papers on:
- Sumcheck protocol optimizations — batching, parallelism, round reduction
- GKR protocol — efficient prover implementations, lookup argument variants
- Lasso / Spartan — alternative sumcheck-based approaches for lookup arguments
- Multilinear extension arithmetic — packed evaluation tricks, eq-polynomial optimizations
- WHIR / FRI-based polynomial commitments — prover bottlenecks

Also read inspiration repos for concrete implementation patterns.

## Hard Constraints
1. No security parameter changes — do not touch `crates/backend/fiat-shamir/`, `crates/air/`.
2. No interface changes — do not alter public function signatures.
3. No test value changes — do not modify expected values in tests.
4. Correctness is mandatory — all tests in correctness.sh must pass.
5. **NEVER modify** `~/zk-autoresearch/experiment_logs/` or `~/zk-autoresearch/leanMultisig-bench/`.
6. **NEVER skip Stage 2.** Even for clearly-instruction-visible changes, wall-clock confirmation is required.
7. **NEVER log a keep with `base_hash == cand_hash`.** That is an infra failure, always, and must be investigated before continuing.
8. **NEVER modify** `crates/backend/koala-bear/src/quintic_extension/tests.rs` — integrity-checked by `correctness.sh`. Modifying test assertions to make incorrect code pass will be detected and flagged.

## Profile-first invariant
If `eval_paired.sh`'s measured median baseline runtime drifts by > 10 % from the calibrated figure (5.36 s ± 0.3 s at 1400 sigs) for more than 2 consecutive iterations, pause the loop and dump state. Something upstream in the stack has changed the bottleneck — the sumcheck hot path may no longer be dominant, and the keep rule is no longer well-calibrated.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run experiments autonomously until manually stopped. The exception is the profile-first invariant above.
