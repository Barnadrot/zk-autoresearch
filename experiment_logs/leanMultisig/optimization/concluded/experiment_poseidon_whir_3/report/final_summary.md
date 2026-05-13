# poseidon_whir_3 — Final Report

**Status:** 33 iterations completed. Stop counter 9.0/12. **2 keeps** totaling cumulative -5.30% throughput on the bench (vs iter 28-revert which already includes iter 13's -2.17%, so against the original RATE=8 + Karatsuba MDS baseline the total is approximately -7.4%).
**Branch:** `exp7/open-research`. **HEAD:** `77cd163f` (pw3-33).

## TL;DR

Two structural changes shipped end-to-end with the recursive zk-DSL verifier:

1. **Iter 13** (`-2.17%`): switched AIR `mds_air_16` from Karatsuba (72 mults) to FFT-MDS (50 mults).
2. **Iters 30b → 31 → 32 → 33** (cumulative `-5.30%` on top of iter 13): switched WHIR Merkle leaf hashing from RATE=8 to RATE=12 sponge (capacity=4) — both the native Rust path and the recursive zk-DSL verifier.

End-to-end verification (including the recursive zkVM verifier) confirmed working. All five correctness tests pass. Proof size unchanged at 339-340 KiB.

## Final shippable state

`HEAD = 77cd163f` includes all kept changes:

| Iter | Files | Change |
|------|-------|--------|
| 13 | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs`, `crates/lean_vm/src/tables/poseidon_16/mod.rs` | AIR `mds_air_16` Karatsuba → FFT-MDS (50 mults vs 72). |
| 30b | `crates/backend/symetric/src/sponge.rs`, `crates/whir/src/merkle.rs`, `crates/backend/fiat-shamir/src/verifier.rs` | Sponge RATE=8→12 (capacity=4 with WIDTH=16). Padding kept internal to the sponge — `full_leaf_base_width` stays at the unpadded size. |
| 31 | `crates/rec_aggregation/zkdsl_implem/hashing.py` | zk-DSL `slice_hash_rtl` rewritten for RATE=12 sponge. Dispatches per known `num_chunks` to a helper that pads to `(16 + 12k)` and runs the absorb loop using the existing `poseidon16_compress` primitive. |
| 32 | `crates/rec_aggregation/zkdsl_implem/hashing.py` | Removed `@inline` from `slice_hash_rtl`. The combination `@inline` + multi-return-from-conditional-branches caused dispatch fall-through (all branch bodies emitted sequentially). Without `@inline` the function uses regular conditional return semantics. |
| 33 | `crates/whir/src/merkle.rs` | Fixed `n_zero_suffix_rate_chunks` formula. The original `(padded - effective) / RATE` assumed `WIDTH = 2*RATE` — true for RATE=8, false for RATE=12. Correct formula: `n = 2 + (padded - WIDTH - effective - n_pad) / RATE`, derived from `WIDTH + (n-2)·RATE + effective + n_pad = padded`. |

### Final benchmark numbers

Paired gate (`xmss_leaf_1550sigs`, N=3 paired rounds, baseline = iter 28-revert which has iter 13 included):

| Comparison | Median Δ% | Rounds | All p<0.01? |
|------------|-----------|--------|-------------|
| RATE=8 (iter 28 revert) → RATE=12 + bug (iter 30b) | -4.76% | -4.61, -5.30, -4.76 | yes |
| RATE=8 (iter 28 revert) → RATE=12 fixed (iter 33) | **-5.30%** | -5.30, -5.30, -3.71 | yes |

Single-shot (`prove_loop` 1 sig, end-to-end with verification):
- Time: 2.720s (vs ~2.86s pre-iter-30b baseline).
- Proof: 339 KiB (baseline 340 KiB) — unchanged.
- Verify: OK in 37ms.

Per the program scoring rule: net = `throughput_pct - 3 × proof_size_increase_pct ≈ +5.3 − 3·0 = +5.3` — passes gate by ~5x.

### Correctness tests (all pass at HEAD)

- `test_run_whir` ✓ — direct WHIR prover/verifier
- `test_xmss_signature` ✓ — XMSS leaf signing
- `test_type_1_aggregation` ✓ — recursive type-1 aggregation
- `test_aggregation` ✓ — full aggregation flow
- `test_type_2_aggregation` ✓ — type-2 aggregation

## What worked

### Iter 13: FFT MDS in AIR eval (`-2.17%`, kept)

Replaced Karatsuba MDS (72 mults) with FFT-MDS (50 mults) in the Poseidon AIR evaluation path. 8 MDS calls per AIR row → 176 mults/row saved. AIR Poseidon eval was ~10% of CPU. Calibration error: predicted -1.0 to -1.5%, actual -2.17% — the bigger-than-predicted gain came from compounding cache/ILP wins beyond raw mult count.

Note: same swap REGRESSED trace_gen by +0.50% (iter 16) — tight loops favor Karatsuba's independent recursive halves over FFT's longer dep chain. Lesson recorded: **same algorithmic win can hurt different code paths**; always measure separately.

### Iters 30b–33: Sponge RATE=12 (`-5.30%`, kept)

The user-directed sponge rate increase, debugged across four commits.

**Why RATE=12 helps**: Each sponge round absorbs RATE elements per Poseidon permutation. Going from RATE=8 to RATE=12 cuts the number of permutations per leaf by ~25-32% depending on row width. Initial Merkle leaf hashing was 19% of CPU; the sponge change reduces that proportionally.

**Cryptographic note (iter 29 WIP analysis)**: Standard sponge collision security drops from 124-bit (capacity=8) to 62-bit (capacity=4) per Bertoni et al. The 62-bit collision is below the SECURITY_BITS=124 target. To preserve standard collision security with rate=12, would need either:
- Beetle-mode sponge construction (collision = c·log(p), so 4·31=124 bits) — requires non-trivial protocol change beyond rate parameter.
- Poseidon-24 (width=24, rate=16, capacity=8) — gives 124-bit collision and rate=16, but Poseidon-24 isn't implemented in mt-koala-bear.

The current commit ships the standard-sponge variant. **External cryptographic review needed before production deployment.** The bench numbers demonstrate the 5.3% perf gain is real and end-to-end works; the security mode is the open question.

**Bug story** (preserved as a cautionary lesson):
1. **Iter 30** (first attempt): tried to expose padded width to the protocol layer. `evaluate(folding_randomness)` panicked because `1 << folding_factor != padded_len`. Reverted.
2. **Iter 30b**: kept `full_leaf_base_width` unpadded; padded only inside the sponge. test_run_whir passed, but test_aggregation failed with `Runner: not equal` runtime panic in the recursive verifier.
3. **Iter 31**: rewrote zk-DSL `slice_hash_rtl` for RATE=12. Build clean, but the same runtime panic.
4. **Iter 32**: found `@inline` was the culprit — multi-return-from-conditional-branches doesn't work in inlined zk-DSL functions; all branches' code was being emitted sequentially. Removing `@inline` fixed the dispatch. Got past the runtime panic but hit `InvalidProof` at the outer WHIR's first `merkle_verify`.
5. **Iter 33**: traced the `InvalidProof` to a precompute formula that assumed `WIDTH = 2·RATE`. Fixed the formula. All tests pass.

The dispatch-from-`@inline` bug and the precompute-formula bug are both worth documenting in the codebase if the recursive verifier is being extended. They are subtle and the failure modes (silent dispatch fallthrough, silent under-absorption) made them hard to find.

## Confirmed-well-tuned (do not retry)

| Surface | Iter | Lesson |
|---------|------|--------|
| `LOG_BATCHED_TILE_SIZE` (eq_mle) | 1, 6 | 14 is local optimum |
| Rayon thread pool size | 4 | SMT IS net positive despite cache contention |
| `cargo` LTO config | 5 | Harness already has `lto=fat`; main Cargo.toml profile doesn't propagate |
| `with_min_len` chunk forcing | 3 | Default rayon splitting is optimal |
| Column-major DFT prep | 9 | False sharing across 8 cores caused +17.98% catastrophe |
| Row-chunked DFT prep | 11 | par_iter+collect outperforms explicit chunking |
| `inline(always)` on eq helpers | 10 | Compiler already inlines via `inline` when beneficial |
| pair_coeffs CSE post-iter-13 | 8, 12, 14, 20 | -0.41% pre-iter-13 vanished post-iter-13. Micro signals are baseline-dependent |
| AIR `m_i` partial-round sparsity | 18 | Compiler dead-code elims static-zero `OnceLock` entries |
| AIR last-initial-MDS + m_i fusion | 19 | Generic AIR path is ILP-limited not mult-count-limited |
| Trace-gen FFT MDS swap | 16 | Tight loops favor Karatsuba's ILP over FFT's dep chain |
| `memory_acc` atomic histogram parallelism | 21 | Sequential-but-tiny loops on cache-resident data shouldn't be parallelized |
| Merkle compress chunk granularity (BATCH=4) | 22 | Rayon's adaptive splitting already amortizes per-iter overhead |
| `rayon::join` overlap of memory_acc + bytecode_acc | 26 | Overlap saves min(time_a, time_b); for asymmetric loops the saving is below noise |
| `rs_domain_initial_reduction_factor` 5→6 | 23 | Real -2.86% throughput WIN but +9.7% proof. Net unshippable |
| `rs=6` + `pow=18` combo | 24 | pow grinding doesn't fully compensate query growth from rs change |
| `GRINDING_BITS` 16→20 | 25 | Throughput cost (+7.5%) exceeds proof shrink (-6.2%) |
| Compiler bytecode caching | 27 (WIP) | Already cached via `OnceLock`; not a per-proof lever |
| DFT `LAYERS_PER_GROUP=4` | 28 | Real but small signal: -0.44% median, σ=0.68%. Plonky3's 3 is locally optimal at the lower end of the curve |

## Cross-system findings (iter 17 WIP)

- **SP1** `slop/veil/protocols/sumcheck.rs`: generic batched-RLC abstraction. **leanMultisig's specialized per-protocol kernels are more optimized.** No port target.
- **Plonky3 poseidon1-air**: commits HALF_FULL_ROUNDS post-MDS witness columns. **leanMultisig is ahead** — uses HALF_INITIAL_FULL_ROUNDS = HALF_FULL_ROUNDS/2 (2x witness reduction).
- **Plonky3 MDS** in AIR: dense matrix-vector (256 mults) — **strictly behind leanMultisig (post-iter-13) at 50 mults**.

## Calibration notes

| Iteration | Predicted | Actual | Calibration |
|-----------|-----------|--------|-------------|
| 13 | -1.0 to -1.5% | -2.17% | 1.5× under-predicted |
| 14 | -0.7 to -1.5% | +0.70% | wrong direction |
| 15 | -0.2 to -0.6% | +0.07% | over-predicted |
| 16 | -0.1 to -0.3% | +0.50% | wrong direction |
| 18 | -0.20% | -0.09% | half magnitude |
| 19 | -0.3 to -0.5% | +0.52% | wrong direction |
| 21 | -0.5 to -1.5% | +0.49% | wrong direction |
| 22 | -0.2 to -0.5% | +0.17% | half / noise |
| 23 | -0.5 to -2% | -2.86% | 1.5× under-predicted |
| 28 | 1-3% | -0.44% | 5× over-predicted |
| 30b | -5 to -7% | -4.76% | matched lower bound |
| 33 | shippable | -5.30% | matched (and crossed gate cleanly) |

**Key calibration lessons**:
- Predictions for "tight loop ILP" wins consistently went the wrong direction because the compiler already exploits ILP at this codebase's tuning level.
- Predictions for "fewer multiplications" wins under-predicted because cache/scheduling downstream effects compound the direct savings.
- The sponge rate prediction matched closely (predicted 5-7%, got 5.3%) — protocol-level structural changes are easier to predict than micro/medium ILP-level changes.

## Stop counter accounting

| Iters | Cost | Rationale |
|-------|------|-----------|
| 1-12 | 12.0 | All micro-discards (12 in a row triggered first stop pause) |
| 13 | -- | KEEP, resets counter |
| 14-21 | various | Mix of micro/medium/structural discards |
| 22-26 | 4.0 | iter 22 (medium), iter 23 (medium), iter 24 (micro), iter 25 (micro), iter 26 (micro) |
| 27 | 0.0 | WIP crypto analysis |
| 28 | 0.0 | Structural (262 LoC, multi-layer butterfly) |
| 29 | 0.0 | WIP sponge security analysis |
| 30 | 0.0 | Structural — multi-file sponge rate change (broke initially) |
| 30b | -- | KEEP, structural follow-up to iter 30 |
| 31 | 0.0 | Structural — zk-DSL RATE=12 (broken with @inline) |
| 32 | 0.0 | Structural debug — `@inline` removal fix |
| 33 | -- | Part of iter 30b's structural arc — precompute formula fix |
| **Total** | **9.0/12** | 3.0 budget remaining |

## Cumulative experiment outcome

Starting at iter 0 with the leanMultisig prover at the exp5/poseidon1-stacked-pcs baseline. After 33 iterations:

- **2 keeps** totaling **~-7.4% throughput** vs the pre-experiment baseline (iter 13's -2.17% + iter 33's -5.30% on top of that).
- **Proof size unchanged**: 339-340 KiB throughout.
- **Recursive verifier works end-to-end**: VERIFY=1 prove_loop succeeds.
- **All correctness tests pass**.

Three open issues that the next agent should weigh in on:

1. **Sponge security mode** (iter 29 WIP): the standard-sponge analysis gives 62-bit collision for capacity=4. The user/external review needs to decide between (a) accepting 62-bit collision, (b) implementing Beetle-mode for 124-bit collision, (c) implementing Poseidon-24 for 124-bit collision with width=24. The perf win is real either way; the security mode is orthogonal.

2. **DFT `LAYERS_PER_GROUP=4`** (iter 28): showed a -0.44% signal that didn't cross the gate but wasn't noise either. With more rounds (N=5+) it might cross. Also worth retrying after the iter-30b sponge change has settled.

3. **Stop counter has 3.0 budget remaining**. Plausible additional levers (none with high-confidence > 1% potential):
   - Buffer pooling / arena reuse for DFT scratch (`~1.4%` malloc target)
   - Combine DFT and Merkle commit pipelines
   - Tighter sumcheck inner loops (limited by ILP, see iters 14, 19 dead-ends)

## File pointers (as of HEAD = 77cd163f)

- `crates/backend/symetric/src/sponge.rs` — relaxed asserts; sponge accepts arbitrary `RATE` and `OUT` as long as `(data.len() - WIDTH) % RATE == 0`. Unit tests confirm `hash_slice(D) == hash_rtl_iter(D.iter().rev())` for both RATE=8 and RATE=12.
- `crates/whir/src/merkle.rs` — `SPONGE_RATE = 12`, `padded_full_base_width()` helper, `build_merkle_tree_koalabear` with the corrected `n_zero_suffix_rate_chunks` formula. `merkle_verify` pads `base_data` before hashing.
- `crates/backend/fiat-shamir/src/verifier.rs` — `hash_fn` pads to sponge-aligned length before `hash_slice`.
- `crates/rec_aggregation/zkdsl_implem/hashing.py` — `slice_hash_rtl` (no `@inline`) dispatches per `num_chunks` to `slice_hash_rtl_rate12` helper, which builds RATE=12 sponge state via `poseidon16_compress` primitive.
- `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs`, `crates/lean_vm/src/tables/poseidon_16/mod.rs` — iter 13's FFT MDS application.
- `harness/leanmultisig/bench/src/bin/prove_loop.rs` — extended (uncommitted in zk-autoresearch) to print `proof_kib` per proof for size-tracking.
