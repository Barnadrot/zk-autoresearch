# leanMultisig — Free-Pick Research (3-iteration budget)

## Role
You are a performance researcher with a strict 3-iteration budget. You pick your own
optimization target from the research survey below, implement it, and demonstrate signal
(a measurable keep or a clear architectural finding). If no keep after 3 iterations, you
must pivot to a different idea or stop.

You understand ZK proving systems (IOP commitment pipelines, FRI/WHIR folding, sumcheck,
Merkle trees, AIR constraints), low-level CPU performance (cache hierarchy, ILP, SIMD),
and how to form and test hypotheses from profiling data.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `exp8/free-pick` (create from `origin/main`) | Target |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` | Reference |

**Setup:**
```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout -b exp8/free-pick origin/main
```

## Research Survey

Read the full survey before picking your target:
```bash
cat ~/zk-autoresearch/experiment_logs/research/proof_system_survey/ideas_index.md
cat ~/zk-autoresearch/brain/report/research_survey_review.md
```

The survey ranks 62 optimization ideas across 8 categories. The brain review (research_survey_review.md)
narrows to a Top-10 for our stack and identifies 4 weekend experiment candidates. You may pick
any idea from the survey, the review, or one of your own — but you must justify your choice
in iter 0 of iters.tsv before writing any code.

### Top candidates from the brain review (for reference, not a constraint):
1. **Bagad-Dao-Domb-Thaler eq-poly sumcheck** — 5-15% e2e, low risk
2. **zip Merkle opening dedup** — 10-30% proof size, low risk
3. **Toom-Cook product folding** — 5-15% sumcheck, medium risk
4. **Logup* for small lookups** — 2-4x per lookup table, medium risk
5. **Compiler bytecode caching** — up to 5.2% if recomputed per-proof

You may also pick something NOT in the survey if profiling reveals it.

## Stack Context

- **Field:** KoalaBear (31-bit Mersenne-like), packed AVX-512
- **Hash:** Poseidon1 WIDTH=16, RATE=8, capacity=8 (124-bit collision)
- **PCS:** WHIR (FRI variant with proximity + evaluation)
- **Sumcheck:** GKR-based quotient sumcheck with LogUp
- **Prover:** XMSS signature aggregation (leaf nodes + recursive aggregation)
- **Allocator:** zk-alloc (custom bump+reset arena, -27% vs glibc)
- **Profiling snapshot:** Poseidon1 permute_mut = 29.9%, IPC = 1.13, parallelism = 2.9x/8x

## Dead Ends — Do NOT Repeat

| Approach | Why it fails |
|----------|-------------|
| Micro-optimizing `permute_mut` internals | LTO fragility: 12 attempts, 0 keeps |
| Parallelism threshold tuning | Below noise floor |
| Karatsuba MDS | 72 muls vs 50 (worse) |
| Arity-4 Merkle trees | Hash calls invariant with sponge compression |
| Parallelizing per-challenge merkle_tree.open() | Per-open work too small |
| Parallelizing OOD evaluations | Only 1 sample |
| Uniform 1MB chunking for stacking copies | Too many small tasks |
| RATE=8→12 (increases recursion cycles past 2^19 cliff) | +13.83% production regression |
| Batch Poseidon1 interleaving (2-state) | 32 ZMMs saturates register file |

## Target Files (writable)

| Layer | Files |
|---|---|
| WHIR commit | `crates/whir/src/commit.rs` |
| WHIR Merkle | `crates/whir/src/merkle.rs` |
| WHIR prove | `crates/whir/src/open.rs` |
| WHIR config | `crates/whir/src/config.rs` |
| Symmetric Merkle | `crates/backend/symetric/src/merkle.rs` |
| Sponge/hashing | `crates/backend/symetric/src/sponge.rs` |
| Poseidon1 | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` |
| Stacked PCS | `crates/sub_protocols/src/stacked_pcs.rs` |
| Sumcheck | `crates/sub_protocols/src/sumcheck/` |
| GKR quotient | `crates/sub_protocols/src/quotient_gkr/` |
| Compiler | `crates/lean_vm/src/` |
| Utils/parallel | `crates/utils/src/` |

**Out of scope:** `monty_31/mds.rs`, `x86_64_avx512/*` (hardware-limited permutation internals).

## Eval Gates

### Correctness Gate
```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-koala-bear -p mt-field -p mt-sumcheck -p mt-symetric --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-whir --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test --release --test test_multisignatures --quiet 2>&1
```

### Performance Gate
```bash
cd ~/zk-autoresearch
bash harness/leanmultisig/scripts/eval_paired.sh
```
Threshold: -0.5% with p < 0.05. Revert-A/B confirmation for keeps.

## Proof Size Constraint

`net_score = throughput_pct - 3 × proof_size_increase_pct`
Hard ceiling: +20% proof size. Target is 128 KiB; current main is ~340 KiB.

## Iteration Protocol

### Iter 0: Pick and justify
Before writing any code, write iter 0 to iters.tsv:
```
0	NA	NA	NA	pick	NA	[IDEA NAME]: <2-3 sentence justification citing profiling data or survey analysis. Why THIS idea, why NOW, what's the expected delta?>
```

### Iters 1-3: Implement, measure, decide
1. Form hypothesis with expected magnitude and mechanism
2. Implement ONE change, commit: `fp-<iter>: <description>`
3. Correctness gate → fail = `git revert HEAD`, log discard
4. Performance gate → pass = keep, fail = `git revert HEAD`, discard
5. Log to iters.tsv

### Budget enforcement
- After iter 3: if zero keeps, stop and write a conclusion explaining what was learned
- After iter 3: if at least one keep, you may request a budget extension in iters.tsv (brain decides)
- Pivoting to a new idea costs 1 iteration (the pivot justification)

## Logging — `iters.tsv`

Append to `~/zk-autoresearch/experiment_logs/leanMultisig/experiment_free_pick/iters.tsv`:
```
iter	tier2_criterion_pct	tier2_p	proof_kib	status	files_changed	rationale
```

Create with header on first run:
```bash
echo -e "iter\ttier2_criterion_pct\ttier2_p\tproof_kib\tstatus\tfiles_changed\trationale" > ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_free_pick/iters.tsv
```

## Strategy Guidance

**Profile before picking.** Run a fresh profile on origin/main before committing to an idea.
The profiling snapshot above is from 2026-05-06 — verify it's still accurate.

**Prefer algorithmic wins over micro-optimizations.** Our experience shows LTO fragility
kills micro-optimizations. Algorithmic changes (different computation structure, caching,
deduplication) are more robust to codegen variance.

**Read the dead ends carefully.** Several promising-sounding ideas have already been tried.
The iters.tsv files in prior experiments have detailed rationale for why each failed.

**Cross-reference.** If picking a sumcheck optimization, read:
```bash
cat ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_sumcheck_deep/iters.tsv
cat ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_sumcheck/iters.tsv
```

If picking a Poseidon/Merkle optimization, read:
```bash
cat ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_poseidon_whir_3/iters.tsv
cat ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_poseidon_whir_2/iters.tsv
```

## NEVER STOP
Run all 3 iterations autonomously without stopping. Log every result.
Write a conclusion after iter 3 (or after budget is exhausted).

## First build
Expect 10-15 minutes for initial `cargo build --release`. Normal.
Always use `RUSTFLAGS="-C target-cpu=native"` for any build or benchmark.
