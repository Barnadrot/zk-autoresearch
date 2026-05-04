# leanMultisig — Experiment 5: Poseidon + WHIR

## Role
You are an expert ZK protocol engineer with deep knowledge of Poseidon hash functions,
Merkle tree commitment schemes, and WHIR polynomial commitment. You write high-performance
Rust and understand AVX-512 microarchitecture on Zen 4.

**Hardware:** AMD Ryzen 7 PRO 8700GE (Zen 4), AVX-512, bare metal.
**Baseline:** `fc1a9903` (origin/main, includes zk-alloc). Criterion `xmss_leaf_1400sigs`.
**Branch:** `exp5_poseidon_whir` on `myfork`. Baseline is `fc1a9903`.

## What this experiment is NOT

**Do NOT modify:**
- `~/zk-autoresearch/leanMultisig-bench/` — no bench crate changes
- Cargo.toml build profiles (codegen-units, LTO, panic) — already explored
- Allocator selection — already explored
- RUSTFLAGS or PGO — already explored
- fiat-shamir/ (EXCEPT `merkle_pruning.rs`), field/, lean_vm/, all tests/

This experiment targets the WHIR Merkle commitment path. Sumcheck, GKR, logup,
and AIR constraints are separate experiments — don't modify that code.

## Profiling Breakdown (2026-05-04, perf fp, 221K samples, latest main + zk-alloc)

| Component | % e2e | Explored? | Notes |
|---|---|---|---|
| permute_mut (PackedKB, WHIR Merkle) | 20.59% | Never on this baseline | Main monomorphization, called from compress_layer |
| rayon bridge_producer_consumer (total) | ~12.5% | Never on this baseline | Spans both Merkle and sumcheck parallelism |
| eval_2_full_rounds_16 (AIR) | 4.68% | Only inlining (0%) | Out of scope |
| eval_eq_with_packed_output | 2.90% | Heavily (7 iters) | Hardware local optimum, out of scope |
| product_computation | 2.53% + 1.29% | Lightly | Out of scope |
| quotient_gkr fold_and_compute | 2.52% | On old code (0 keeps) | Out of scope |
| Kernel [k] | ~5% | N/A | Not actionable |
| permute_mut (2nd mono) | 1.90% | Never | Same function, different caller |
| Poseidon16Precompile::eval (AIR) | 1.87% | Never | Out of scope |
| FnMut::call_mut | 1.56% | Never | Mostly sumcheck, out of scope |
| permute_mut (3rd mono) | 0.98% | Never | Same function, different caller |
| permute_mut (4th mono) | 0.92% | Never | Same function, different caller |

**Total permute_mut: 24.4% of e2e** (all monomorphizations combined).
zk-alloc removed allocation overhead elsewhere, making Poseidon/WHIR a relatively larger target.

## The Call Chain (target path)

```
prove_execution.rs
  → stacked_pcs / WHIR polynomial commitment
    → whir/commit.rs: MerkleData::build()
      → whir/merkle.rs: merkle_commit()
        → symetric/merkle.rs: compress_layer()          ← rayon-parallel, per tree level
          → symetric/permutation.rs: compress_mut()
            → poseidon1_koalabear_16.rs: compress_in_place()
              → permute_mut(&mut [PackedKB; 16])         ← 20.59% e2e
                → permute_simd()
                  → mds_circ_16 (circulant MDS, Karatsuba, ~72 PF muls)
                  → S-box (x³)
                  → round constant addition
```

## Iteration Surface

### 1. Merkle tree arity (never attempted, structural, 100-200 lines)

Binary Merkle tree means log2(N) levels. Each level calls compress_layer which calls
permute_mut on every node. Arity-4 halves tree depth → halves total permute_mut calls
in the commitment path. Study whether WHIR's polynomial commitment protocol constrains
arity (FRI folding factor is the analogy — FRI uses arity-2 but some implementations
support higher). If arity is protocol-constrained, this is a dead end.

Requires changes to `merkle_commit()`, `compress_layer()`, and `compress_mut()` to
handle width-4 input. The Poseidon compression function takes `[PackedKB; 16]` which
may already support wider input with restructuring.

Study `crates/whir/src/merkle.rs` and `crates/backend/symetric/src/merkle.rs`.

### 2. Redundant hashing across commitment rounds (never attempted, structural)

WHIR commits to multiple polynomial evaluations. If the Merkle tree is rebuilt from
scratch each round (rather than incrementally), there may be redundant subtree
computation. Study `MerkleData::build()` in `commit.rs` — how many times is
`merkle_commit()` called per proof? Are any subtrees shared across calls?

If the same leaves appear in multiple commitments, caching subtree hashes could
eliminate a fraction of permute_mut calls entirely.

### 3. compress_layer parallelism and batching (1 iter, -0.44%)

`with_min_len(64)` gave -0.44% — real signal but below threshold. The issue is deeper:
compress_layer processes one tree level at a time with a barrier between levels. Bottom
levels have many small nodes (high parallelism, low work-per-task). Top levels have
few large subtrees (low parallelism, high work-per-task).

A structural fix: process multiple bottom levels in a single parallel pass (fused
compression). Instead of compress → barrier → compress → barrier, compute 2-3 levels
of the tree in one rayon chunk. This changes the work-per-task ratio fundamentally
rather than just tuning min_len.

### 4. Algorithmic change to permute_mut (only if fundamentally different algorithm)

20.59% is in permute_mut. Do NOT micro-optimize instruction scheduling, register
allocation, or inline hints — these produce <1% e2e. Only pursue if you find a
fundamentally different algorithm: different MDS construction, different round structure,
reduced round count with equivalent security. This requires 100-200+ lines and deep
understanding of Poseidon security margins.

The SIMD path already uses FFT-based MDS. Karatsuba is only in the generic fallback.

## Target Files (writable)

| Surface | Files |
|---|---|
| WHIR Merkle | `crates/whir/src/merkle.rs`, `commit.rs`, `open.rs`, `verify.rs` |
| Symmetric/Merkle | `crates/backend/symetric/src/merkle.rs`, `permutation.rs`, `compression.rs`, `sponge.rs` |
| Poseidon permutation | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs`, `symmetric.rs` |
| Poseidon MDS | `crates/backend/koala-bear/src/monty_31/mds.rs` |
| Poseidon SIMD / AVX-512 | `crates/backend/koala-bear/src/monty_31/x86_64_avx512/` (all files) |
| Merkle proof structure | `crates/fiat-shamir/src/merkle_pruning.rs`, `prover.rs`, `verifier.rs` |

## The Metric

**Lower is better.** `xmss_leaf_1400sigs` e2e (~4.49s baseline).
Keep if: wall-clock improvement >= 1.0% with p < 0.01.

## Profiling Commands

```bash
# Build with frame pointers
cd ~/zk-autoresearch/leanMultisig-bench
RUSTFLAGS="-C target-cpu=native -C force-frame-pointers=yes" cargo bench --bench xmss_leaf --no-run

# Find the bench binary (hash changes on recompile)
BENCH_BIN=$(ls -t target/release/deps/xmss_leaf-* | grep -v '\.d$' | head -1)

# perf flat report
perf record -F 997 -g --call-graph=fp -o /tmp/perf.data -- \
    "$BENCH_BIN" --bench xmss_leaf_1400sigs --profile-time 20
perf report -i /tmp/perf.data --no-children --sort=symbol --stdio --no-call-graph | head -40

# flamegraph
flamegraph -o /tmp/flamegraph.svg -- \
    "$BENCH_BIN" --bench xmss_leaf_1400sigs --profile-time 15
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

**SIMD micro in permute_mut (instruction scheduling, register tricks, inline hints):** produces <1% e2e regardless of local improvement — the 20.59% share dilutes ~4-5x and the compiler already optimizes well. Don't touch poseidon1_koalabear_16.rs unless you have a fundamentally different algorithm.
**FFT-based MDS replacement:** SIMD path already uses FFT-based MDS (mds_fft). Karatsuba is only in the generic fallback that doesn't run on this hardware.
**Arity-4 Merkle:** total hash calls are invariant (N-1) with sponge-based compression — 3 hashes per 4-ary node vs 1 per binary node. No benefit without changing the compression function itself.

## Scope Rules
- Source code changes only. No build config, no bench crate modifications.
- Structural changes (~200 lines) and protocol-level restructuring in scope.
- Multi-iter blocks for complex work. Log `status=wip` until gate.
- ONE change per iteration. Correctness mandatory.
- Research papers and cross-repo patterns valid input.

## Stop Criterion
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
