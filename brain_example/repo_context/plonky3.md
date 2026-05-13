# Repo context — Plonky3

Mutable facts about the Plonky3 target repo. Read by `brain-author-*` personas before authoring program.md. Updated whenever a new profiling baseline lands or a known-no-go shifts.

## What it is

ZK proving framework — BabyBear / KoalaBear / M31 / Goldilocks base fields, Poseidon1 / Poseidon2 hashes, Keccak, FRI / Circle-FRI commitments, AIR + STARK provers. Upstream: github.com/Plonky3/Plonky3. Multiple downstream provers depend on this (SP1, leanMultisig, RISC0, Stwo, etc.).

## Location

```
~/zk-autoresearch/Plonky3              # cloned per scripts/setup/plonky3.sh
```

Repo is gitignored at the brain checkout root — clone separately.

## Active baseline (as of 2026-05-13)

| Item | Value |
|---|---|
| Branch baseline | `origin/main` (track HEAD; user-driven PRs to upstream) |
| Brain fork | `Barnadrot/Plonky3` (for experiment branches before upstream PR) |

Profiling baselines vary per benchmark binary — see `experiment_logs/Plonky3/` for the most recent runs per surface.

## Canonical benchmarks (separate per primitive)

```bash
# In Plonky3 repo with native target-cpu
RUSTFLAGS="-C target-cpu=native" cargo build --release

# Examples on main:
cargo run --release --example prove_poseidon2_baby_bear_keccak_zk
cargo run --release --example prove_poseidon2_koala_bear_keccak
cargo run --release --example prove_poseidon1_baby_bear_keccak

# Bench bins (harness):
~/zk-autoresearch/harness/plonky3/bench/   # Poseidon1, Poseidon2, Keccak benches
```

The right baseline is **per-primitive** — Poseidon1 BabyBear is a different workload from Poseidon2 KoalaBear. Always specify which.

## Hot subsystems (per primitive)

| Subsystem | What it does | Bench bin |
|---|---|---|
| `p3-baby-bear` / `p3-koala-bear` / `p3-mersenne-31` / `p3-goldilocks` | Base field arithmetic | inline in each bench |
| `p3-poseidon` / `p3-poseidon2` | Hashes (multiple S-box / round counts per field) | poseidon1/poseidon2 bench |
| `p3-keccak` / `p3-keccak-air` | Keccak constraint system | keccak bench |
| `p3-fri` | FRI commitment + open + verify | wrapped by each example |
| `p3-monty-31` | Montgomery-form 31-bit primes | implicit dep |
| `p3-uni-stark` | STARK prover (single-trace) | `prover.rs` is integration point |
| `p3-air` | AIR (algebraic intermediate representation) trait | every constraint system |
| `p3-circle` | Circle-STARK / M31 variant | M31-specific bench |

## Cargo workflow

- **Tests:** `cargo test --release` (NOT nextest — Plonky3 uses stock cargo test).
- **Build:** Always `RUSTFLAGS="-C target-cpu=native"` for benchmarking. Without it, AVX-512 paths are dead — measurements silently 2× slower.
- **fmt + clippy + check:** Required before any PR or push (per `feedback_check_ci_before_pr.md`):
  ```bash
  cargo fmt --check
  cargo clippy --workspace --all-targets -- -D warnings
  cargo test --release
  ```

## Gate methodology

```bash
# Correctness (bitwise DFT validator + per-bench reproducibility)
bash ~/zk-autoresearch/harness/plonky3/scripts/correctness.sh

# Performance (cross-branch Criterion comparison)
bash ~/zk-autoresearch/harness/plonky3/scripts/eval.sh
```

Cross-branch comparison: `scripts/run_benchmark.sh` runs the same bench on `main` and on the experiment branch, computes A/B delta. CRITICAL: must use `RUSTFLAGS="-C target-cpu=native"` consistently across both branches.

## Target hardware

| Executor | Hardware | Primary use |
|---|---|---|
| hetzner-ax42u | AMD Ryzen 7 PRO 8700GE Zen 4, AVX-512 | Primary perf + bug hunting |
| m2-asahi | Apple M2 / Asahi Linux NEON | Cross-validation (aarch64 Linux) |
| m4m-macos | Apple M4 Pro 32 GiB macOS Sequoia | macOS aarch64 validation; zk-alloc integration |

NEON-vs-AVX-512: Plonky3 has separate SIMD paths. NEON bugs found in past hunts (#1580, #1591) — packed-field invariants differ.

## Active investigations / open candidates

- **Bug hunters 1-8** — correctness hunts. bh1-3 found NEON `add_asm`, `sub_asm`, `interpolate_arbitrary_point`, `PackedCubicTrinomialExtensionField::div` bugs (one critical). bh4 is verifier-side (in flight). bh5-8 queued.
- **NTT/Montgomery experiments** — concluded. See `experiment_logs/Plonky3/NTT/`.
- **zk-alloc integration on Plonky3** — m4m-macos active experiment validates 0.0.9 crates.io dep. Hetzner + Asahi validation pending.
- **permute_state_x2 for Poseidon1** — upstream PR planned for AVX-512 batch interleaving.

## Confirmed bugs (cumulative across bug hunters)

| Bug | Surface | Severity | Status |
|---|---|---|---|
| Plonky3 #1580 | NEON `add_asm` non-canonical input | high | PR merged |
| Plonky3 #1591 | NEON `sub_asm` sub(0, P+1) wrong | high | PR merged |
| Plonky3 #1600 | (third bug from prior hunt) | medium | PR merged |
| bh3-4 | `interpolate_arbitrary_point` duplicate x_coord early-exit | medium | confirmed |
| bh3-5 | `PackedCubicTrinomialExtensionField` unsafe `impl PackedValue` | medium | confirmed |
| bh3-6 | `PackedCubicTrinomialExtensionField::div` via broken `as_slice` | critical | confirmed; dormant (no callers) |

## Bug-class patterns (use to calibrate new hunts)

1. Correct for "interior" inputs, wrong at representation boundaries (canonical-vs-non-canonical, near-zero, near-P).
2. SIMD subtly violates an invariant the scalar path maintains.
3. Silent corruption — wrong field element, no crash, proof might still verify.
4. Documentation says X, code does Y.
5. Unsafe transmute between storage layouts.
6. Composition assumes a contract that the dependency doesn't guarantee.
7. Dormant bugs in unused-but-public code paths.

## Known dead-ends / not-found analyses (HARD FACTS)

Disproved from prior hunts (documented invariants):
- `batch_multiplicative_inverse` split into prefix+tail is correct (Montgomery's trick is self-contained per slice).
- `halve` Goldilocks branchless mask is bitwise-equivalent (sum < 2^64 always).
- WHIR `sumcheck_coefficients_prefix` K=8 chunked path agrees with scalar across all tail sizes.
- FRI `fold_matrix` log_arity=k equals chained arity-2 folds (squared-betas invariant).

## Branch protocol

Experiment branches: `bh<N>-<focus>-YYYY-MM-DD` or `opt-<focus>-YYYY-MM-DD` off `origin/main` of `Barnadrot/Plonky3` (the brain fork). Coordinator checks out pre-dispatch. Agent commits per iter. Upstream PRs (to Plonky3/Plonky3) are user-driven after brain review.

## Files an author should reference but NOT re-author

- Eval gate: `harness/plonky3/scripts/{eval.sh, correctness.sh}` — gate logic.
- Bench crate: `harness/plonky3/bench/` — Criterion benchmarks for Poseidon1/2/Keccak.
- Correctness crate: `harness/plonky3/correctness/` — bitwise-identical DFT validator.

When gate methodology changes, update those harness files first, then update this bundle.
