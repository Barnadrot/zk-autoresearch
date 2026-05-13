# Repo context — leanMultisig

Mutable facts about the leanMultisig target repo. Read by `brain-author-*` personas before authoring program.md. Updated whenever a new profiling baseline lands or a known-no-go shifts.

## What it is

XMSS hash-based signature aggregation prover, built on Plonky3 + WHIR. Lean Ethereum's signing protocol candidate. Primary metric: **prover wall-clock** at fixed signature count + proof-size budget. Proof size is a hard constraint, not a soft one.

## Location

```
~/zk-autoresearch/leanMultisig          # cloned per scripts/setup/leanmultisig.sh
```

Repo is gitignored at the brain checkout root — clone separately. Upstream: github.com/maceip/leanMultisig.

## Active baseline (as of 2026-05-13)

| Item | Value |
|---|---|
| Branch baseline | `origin/main @ c868330c` (close to current HEAD) |
| Wall-clock at baseline | 11.75 s total / 7.77 s pure prove for `prove_loop 3` on Hetzner Zen 4 |
| IPC parallel / serial | 0.82 / 1.29 (≈ vpmuludq mul-port ceiling) |
| Workload classification | mul-port-throughput-bound serial; +DRAM-bandwidth contention under parallel |
| Proof size budget | 128 KiB (Lean Ethereum gossip target) |

Source of truth for current baseline: `experiment_logs/leanMultisig/profiling/concluded/profiling_baseline_hetzner_2026-05-11/`.

## Canonical workload

```bash
# In leanMultisig repo on origin/main with native target-cpu
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin prove_loop --features zkalloc_global
./target/release/prove_loop 3
```

`prove_loop 3` = 3 proofs × 1550 sigs × log_inv_rate=1, fat LTO, zkalloc global allocator. This is the bench workload — NOT `fancy-aggregation` (which has different cost profile). Always cite the exact workload in any results.

## Hot symbols (parallel run, Hetzner Zen 4, perf record -F 997 --call-graph dwarf)

| Symbol | %self | %inclusive |
|---|--:|--:|
| `Poseidon1KoalaBear16::compress_mut` | 22.28% | 22.37% |
| `Poseidon1KoalaBear16::permute_simd::mds_fft` | — | 7.99% |
| `PackedMontyField31AVX512::Mul + packing::mul` | — | 6.73% |
| `eval_2_full_rounds_16` (AIR-side) | 5.03% | 5.71% |
| `mt_sumcheck::fold_and_compute_product_sumcheck_polynomial` | 3.59% | 4.30% |
| `mt_poly::eq_mle::eval_eq_with_packed_output` | 4.24% | 4.28% |
| `mt_whir::merkle::first_digest_layer + hash_slice` | — | ~5% combined |

Per-crate cycle distribution: `mt_koala_bear` ~27%, `lean_vm` (AIR) ~13%, `mt_sumcheck` ~12%, `sub_protocols` ~9%, `mt_whir` ~7%, `mt_poly` ~6%, kernel+rayon+other ~26%.

Re-validate before authoring if the experiment dispatches after a notable code change.

## Forked primitives (HARD FACT — do NOT confuse with Plonky3)

leanMultisig vendors forked copies of Plonky3 primitives. These crates are **mt-*** prefixed and live in `crates/backend/` — they are NOT `p3-*` deps from the Plonky3 workspace:

- `mt-koala-bear` (Poseidon1, packed field arithmetic — fork of p3-koala-bear)
- `mt-poseidon` (sponge / compression / merkle — independent)
- `mt-sumcheck`, `mt-poly`, `mt-whir`, `mt-fiat-shamir` (independent)

Optimizations target `mt-*`, NOT `p3-*`. Bug-hunting tests run on `mt-*`. Tests for the equivalent `p3-*` crates DO NOT validate leanMultisig.

## Production integrations (HARD FACTS)

- **zk-alloc by default.** `xmss` CLI is NOT a glibc baseline — it links zkalloc_global per feature flag. Comparing "with vs without zk-alloc" requires explicit feature-flag toggling.
- **Poseidon1 (NOT Poseidon2).** Team migrated P2 → P1 for security. Do NOT propose Poseidon2 migration as a perf lever — it's a closed decision. (See `feedback`-class memory: `project_leanmultisig_poseidon1_choice.md`.)

## Gate methodology

```bash
# Primary paired-test gate (KEEP_THRESHOLD_PCT=1.0 in config.env)
bash ~/zk-autoresearch/harness/leanmultisig/scripts/eval_paired.sh
#   exit 0 = keep   (auto-chains cumulative + Criterion ship-gate)
#   exit 1 = discard
#   exit 2 = infra error
```

Config: `harness/leanmultisig/scripts/config.env`. Tweak `KEEP_THRESHOLD_PCT`, `WARMUP_RUNS`, `N_RUNS` there.

Auto-chain on keep: `eval_cumulative.sh` (cumulative since baseline) + Criterion ship-gate (xmss_leaf bench with noise_threshold=0.7%).

## Target hardware (current fleet)

| Executor | Hardware | Role |
|---|---|---|
| hetzner-ax42u | AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB, AVX-512 | Primary perf target — most optimization experiments run here |
| m2-asahi | Apple M2 (Asahi Linux, NEON), 10c, 16 GiB | Cross-validation; aarch64 Linux 16k pages |
| m4m-macos | Apple M4 Pro, 32 GiB, macOS Sequoia | Stretch target for M-series perf; xctrace tooling |

The same code, different hardware: Hetzner is mul-port-bound, M-series often memory-bound; optimization that wins on one may be NULL on another. Cross-check after structural changes.

## Branch protocol

Each optimization experiment uses a dedicated branch named `<exp-id>-YYYY-MM-DD` off `origin/main`. Coordinator checks out the branch pre-dispatch. Agent commits per iteration on it. Failed iterations get `git revert`, never `git reset`.

leanMultisig fork on `Barnadrot/leanMultisig` is the brain-side branch host. PRs back to upstream (`maceip/leanMultisig`) are user-driven, not agent-driven.

## Known dead-ends (HARD FACTS only — do NOT pollute an agent prompt with non-hard ones)

- **Mul-count reduction in AIR symbolic path** — NEGATIVE on serial (symbolic builder regresses).
- **Rayon nesting cleanup / chunk-size tuning** — NULL (HW prefetcher + chunk-size locally optimal).
- **Source-level wrappers / inline hints** — NULL (LTO neutralizes).
- **+s feedforward Davies-Meyer attack via SPONGE-DM c/2** — refuted; residual telescopes. (See memory `project_plus_s_defense_2026-05-12.md`.)

## Active investigations / open candidates

- **pw4_2** (active 2026-05-13) — successor to pw4. Candidate pool: x2 batched permutation, first-layer sponge→compression, MDS coefficient re-search (cryptanalysis-gated), BDDT eq-MLE residual lift, WHIR DFT cache-blocking.
- **leanMultisig sync vendored zk-alloc to upstream** (PR #11 aarch64 fix carries).

## Files an author should reference but NOT re-author

- Eval gate: `harness/leanmultisig/scripts/eval_paired.sh` — gate logic, drift abort, env preflight.
- Config: `harness/leanmultisig/scripts/config.env` — thresholds.
- Bench crate: `harness/leanmultisig/bench/` (prove_loop bin + Criterion xmss_leaf).

When the gate methodology changes, update those harness files first, then update this bundle to reflect.
