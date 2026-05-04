# leanMultisig — Experiment 5: Poseidon + WHIR

## Role
Expert ZK protocol engineer. High-performance Rust, AVX-512 on Zen 4.
Profile-driven optimization — structural changes over micro tweaks.

**Hardware:** AMD Ryzen 7 PRO 8700GE (Zen 4), AVX-512, bare metal.
**Baseline:** `1ad5fe25` (origin/main). ~4.49s Criterion `xmss_leaf_1400sigs`.
**Branch:** `exp5_poseidon_whir` on `myfork`.

## What this experiment is NOT

**Do NOT modify:**
- `~/zk-autoresearch/leanMultisig-bench/` — no bench crate changes
- Cargo.toml build profiles (codegen-units, LTO, panic) — already explored
- Allocator selection — already explored
- RUSTFLAGS or PGO — already explored

## Profiling Breakdown (2026-05-04, perf fp, 195K samples)

| Component | % e2e | Explored? | Notes |
|---|---|---|---|
| permute_mut (PackedKB, WHIR Merkle) | 18.89% | 1 iter (micro only) | Main monomorphization |
| rayon bridge_producer_consumer (×6) | ~11.9% | Never | Parallel Merkle + sumcheck scheduling |
| Fn::call / FnMut dispatch | ~5.2% | Never | Closure overhead, confirmed real |
| eval_2_full_rounds_16 | 3.87% | Only inlining (0%) | AIR constraint eval |
| quotient_gkr fold_and_compute_round | 3.65% | On old code (0 keeps) | Refactored since |
| product_computation fold_and_compute | 3.50% | Lightly | Product sumcheck |
| eval_eq_with_packed_output | 2.69% | Heavily (7 iters) | Hardware local optimum |
| Kernel [k] | ~4.5% | N/A | KVM overhead |
| permute_mut (Fiat-Shamir) | 1.81% | Never | Low ceiling |
| core::array::try_map | 1.87% | Never | Array iteration |
| Zip::next | 1.55% | Never | Iterator overhead |
| ConstraintFolderPacked::assert_zero | 1.26% | Explored | |
| eval_eq_basic | 1.22% | Heavily | Hardware local optimum |
| permute_mut (3rd mono) | 1.11% | Never | Low ceiling |
| eval_last_2_full_rounds_16 | 1.35% | Only inlining | AIR constraint eval |

## The Call Chain

```
prove_execution.rs
  → stacked_pcs / WHIR polynomial commitment
    → whir/commit.rs: MerkleData::build()
      → whir/merkle.rs: merkle_commit()
        → symetric/merkle.rs: compress_layer()          ← rayon-parallel, per tree level
          → symetric/permutation.rs: compress_mut()
            → poseidon1_koalabear_16.rs: compress_in_place()
              → permute_mut(&mut [PackedKB; 16])         ← 18.89% e2e
```

## Iteration Surface (priority order)

### 1. Rayon scheduling in Merkle commit (~11.9% e2e — never attempted)

The rayon overhead is NOT "rayon is slow." It's that work-per-task is too small relative
to scheduling cost. `compress_layer()` spawns parallel work per tree level — if chunks
are small, rayon dispatch dominates.

Investigate: chunk sizing in compress_layer, whether arity-4 or batched compression
reduces task count, whether level-pipelining eliminates synchronization barriers.

Study `crates/backend/symetric/src/merkle.rs` and `crates/whir/src/merkle.rs`.

### 2. Closure dispatch (~5.2% e2e — confirmed real, never attempted)

`Fn::call` + `FnMut::call_mut` at 5.2% across sumcheck/GKR call sites. Investigate
which closures are worst offenders. Monomorphization or inlining may eliminate dispatch.
May overlap with AIR eval — establish with call-graph profiling first.

### 3. Merkle tree structure (reduce permute_mut call count)

18.89% is in permute_mut. Reducing how many times it's called has multiplicative effect.
Binary tree → arity-4 halves tree depth. Study whether WHIR protocol constrains arity.
Check for redundant hashing across commitment rounds.

### 4. AIR constraint eval (~5.2% combined — only inlining tried)

Hot fns: `eval_2_full_rounds_16` (3.87%), `eval_last_2_full_rounds_16` (1.35%).
Unexplored: constraint expression rewriting, shared subexpressions (manual CSE),
restructuring for SIMD. Do NOT add columns (+46% regression proven).

### 5. GKR quotient (~3.65% e2e — refactored, re-investigate)

Code refactored into `quotient_gkr/sumcheck_utils` with new functions. Prior experiments
explored old structure (8 iters, 0 keeps). New structure may have different opportunities.

### 6. Product sumcheck (~3.5% e2e — low ceiling)

Even 30% local improvement = 1.05% e2e. Only attempt if higher targets exhaust.

### Not targeting (low ceiling or saturated)
- eval_eq (2.69% + 1.22%) — 7 prior iters, hardware local optimum
- permute_mut other monomorphizations (1.81% + 1.11%) — too small
- Kernel (4.5%) — not actionable

## Target Files (writable)

| Surface | Files |
|---|---|
| WHIR Merkle | `crates/whir/src/merkle.rs`, `commit.rs` |
| Symmetric/Merkle | `crates/backend/symetric/src/merkle.rs`, `permutation.rs` |
| Poseidon permutation | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` |
| Poseidon SIMD | `crates/backend/koala-bear/src/monty_31/x86_64_avx512/poseidon_helpers.rs` |
| Packed field | `crates/backend/koala-bear/src/monty_31/x86_64_avx512/packing.rs` |
| AIR constraints | `crates/backend/air/` |
| Logup / GKR | `crates/sub_protocols/src/quotient_gkr/`, `logup.rs` |
| Sumcheck | `crates/backend/sumcheck/src/prove.rs`, `sc_computation.rs`, `product_computation.rs` |

**Read-only:** fiat-shamir/, field/, lean_vm/, all tests/

## The Metric

**Lower is better.** `xmss_leaf_1400sigs` e2e (~4.49s baseline).
Keep if: wall-clock improvement >= 1.0% with p < 0.01.

## Profiling Commands

```bash
# Build with frame pointers
cd ~/zk-autoresearch/leanMultisig-bench
RUSTFLAGS="-C target-cpu=native -C force-frame-pointers=yes" cargo bench --bench xmss_leaf --no-run

# perf flat report
perf record -F 997 -g --call-graph=fp -o /tmp/perf.data -- \
    target/release/deps/xmss_leaf-* --bench xmss_leaf_1400sigs --profile-time 20
perf report -i /tmp/perf.data --no-children --sort=symbol --stdio --no-call-graph | head -40

# flamegraph
flamegraph -o /tmp/flamegraph.svg -- \
    target/release/deps/xmss_leaf-* --bench xmss_leaf_1400sigs --profile-time 15
```

## Experiment Loop

1. Read `program.md` and `iters.tsv`.
2. **Profile after every keep.** Use commands above. Update breakdown if it shifts.
3. Read target files. Understand data flow before hypothesizing.
4. Search inspiration repos (`~/zk-autoresearch/Plonky3/`, `~/zk-autoresearch/jolt/`, `~/zk-autoresearch/sp1/`) when stuck (3+ consecutive discards).
5. Devise ONE targeted change. State hypothesis — what, why, expected signal.
5b. *Optional diagnostic:* validate locally with microbenchmark before burning e2e gate.
    **Microbench to aim, e2e gate to decide.**
6. Edit source files in `~/zk-autoresearch/leanMultisig/crates/` ONLY.
7. Correctness: `cargo test --release` in leanMultisig, THEN `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/correctness.sh`.
8. Commit: `git -C ~/zk-autoresearch/leanMultisig commit -am "iter N: <description>"`
9. Gate: `bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/eval_gate.sh`
10. KEEP → log, re-profile. DISCARD → revert, log.

## Logging — `iters.tsv`
```
iter	tier1_micro	tier2_criterion_pct	tier2_p	tier3_prod_pct	status	files_changed	rationale
```
Status: `keep`, `discard_micro`, `discard_wallclock`, `wip`, `infra_fail`

## Known Dead Ends

**Adding columns:** +46% from Merkle hashing cost increase. Do NOT add columns.
**Precompute-and-share:** cache thrashing beats redundant computation on Zen 4.
**ILP destruction:** serial dependencies in inner loops always hurt OoO engine.
**#[inline(always)] carpet bombing:** compiler already inlines small functions.
**Perf attribution ghosts:** FnMut::call_mut shows 12.7% but has 0% effect when eliminated.
**eval_eq structural:** hardware local optimum, +7-9% wall-clock (7 iters).
**Rayon flattening/nesting:** +8-11% from overhead/contention.

## Scope Rules
- Source code changes only. No build config, no bench crate modifications.
- Structural changes (50-200 lines) and protocol-level restructuring in scope.
- ONE change per iteration. Correctness mandatory.
- Research papers and cross-repo patterns valid input.

## Stop Criterion
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
