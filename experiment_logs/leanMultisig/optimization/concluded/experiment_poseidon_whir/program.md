# leanMultisig — Experiment 5: WHIR Commitment Pipeline

## Role
You are an expert ZK protocol engineer working on the WHIR polynomial commitment
pipeline in leanMultisig. You understand how IOP-based provers compose FFT, Merkle
commitments, and folding rounds to achieve sublinear verification. You write
high-performance Rust on AVX-512 (Zen 4) and think in terms of system structure
before instruction-level detail.

**Hardware:** AMD Ryzen 7 PRO 8700GE (Zen 4), AVX-512, bare metal.
**Baseline:** `fc1a9903` (origin/main, includes zk-alloc).
**Branch:** `exp5_poseidon_whir` on `myfork`.
**Benchmark:** Criterion `xmss_leaf_1400sigs` (~4.49s baseline).
**Inspiration repos:** `~/zk-autoresearch/Plonky3/`, `~/zk-autoresearch/jolt/`, `~/zk-autoresearch/sp1/`

## System Structure (measured, not assumed)

One `xmss_leaf_1400sigs` proof performs **4 Merkle commitments** (1 initial + 3 folding rounds):

| Commitment | Leaves | Width (base elems) | Perms/leaf | Leaf perms | Tree compress | Total perms | % of commitment |
|---|---|---|---|---|---|---|---|
| Initial (stacked poly) | 1,048,576 | 124 | 16 | 16,777,216 | 1,048,575 | 17,825,791 | **78.7%** |
| Round 0 (fold-5) | 131,072 | 160 | 20 | 2,621,440 | 131,071 | 2,752,511 | 12.2% |
| Round 1 (fold-5) | 65,536 | 160 | 20 | 1,310,720 | 65,535 | 1,376,255 | 6.1% |
| Round 2 (fold-5) | 32,768 | 160 | 20 | 655,360 | 32,767 | 688,127 | 3.0% |
| **TOTAL** | | | | **21,364,736** | **1,277,948** | **22,642,684** | |

**Key facts:**
- **Leaf hashing is 94.4%** of commitment work. Tree compression (compress_layer) is only 5.6%.
- **The initial commit is 78.7%** of all commitment permutations.
- Each permutation is at hardware throughput limit (50 Montgomery muls via FFT MDS, fully pipelined on Zen 4). Making individual calls faster is not feasible.
- **The lever is structural:** reduce total permutation count or improve how work is scheduled.

## WHIR Parameters

```
num_variables = 26
starting_log_inv_rate = 1
folding_factor = [7 (first), 5 (subsequent)]
n_rounds = 3
max_num_variables_to_send_coeffs = 8
security = 123 bits, grinding = 18 bits
soundness = JohnsonBound
```

## The Pipeline

```
prove_execution()
  → stack_polynomials_and_commit()           ← stacks ALL tables into one 2^26 polynomial
    → WhirConfig::commit()
      → reorder_and_dft()                    ← FFT: time-domain → evaluation-domain
      → build_merkle_tree_koalabear()        ← 78.7% of all commitment (16.8M + 1M perms)
        → first_digest_layer()               ← LEAF HASHING: 1M rows × 16 perms each
        → MerkleTree::from_first_layer()     ← compress_layer loop: 1M nodes, 20 levels
  → WhirConfig::prove()
    → for round in 0..3:
      → reorder_and_dft()                    ← FFT for folded evaluations
      → build_merkle_tree_koalabear()        ← 21.3% combined (rounds 0+1+2)
        → first_digest_layer()               ← leaf hashing dominates here too
        → MerkleTree::from_first_layer()
      → sumcheck (out of scope)
```

## What You Should Investigate

The data above tells you WHERE the work is. Before proposing changes, understand WHY:

- **Why 16 absorptions per leaf in the initial commit?** The stacked polynomial has
  effective_width=124 base elements per row. At RATE=8, that's ceil(124/8)=16 Poseidon
  calls. Can rows be made narrower? What determines effective_width?

- **Why 1M leaves in the initial commit?** Leaves = 2^(26 + 1 - 7) = 2^20. The folding_factor_0=7
  creates 2^7=128 columns. Higher folding factor = fewer rows but wider columns (same total work?
  or is there a sweet spot?).

- **What's the cost of `reorder_and_dft()` relative to Merkle?** The FFT that prepares
  evaluations before each commitment — is it significant? Profile it.

- **Is there redundancy in the stacking?** `stack_polynomials_and_commit()` packs all tables
  into one polynomial. Does this create padding waste that inflates leaf width?

- **Can leaf hashing be restructured?** `first_digest_layer` iterates RATE=8 chunks RTL
  with a sponge. The zero-suffix optimization (`precompute_zero_suffix_state`) already skips
  trailing zeros. Is there a different absorption strategy that reduces permutation count?

## Target Files (writable)

| Layer | Files | Why |
|---|---|---|
| WHIR commit orchestration | `crates/whir/src/commit.rs` | Controls FFT → Merkle flow, column/row geometry |
| WHIR Merkle construction | `crates/whir/src/merkle.rs` | `build_merkle_tree_koalabear`, `first_digest_layer`, leaf hashing |
| WHIR prove (round loop) | `crates/whir/src/open.rs` | Per-round commitment, folding geometry |
| WHIR config/parameters | `crates/whir/src/config.rs` | Folding factor, round count, query count |
| Symmetric Merkle engine | `crates/backend/symetric/src/merkle.rs` | `compress_layer`, tree construction |
| Sponge/hashing | `crates/backend/symetric/src/sponge.rs` | Absorption pattern, zero-suffix opt |
| Poseidon compress interface | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` | compress_in_place, compress_mut |
| Merkle pruning | `crates/fiat-shamir/src/merkle_pruning.rs` | Opening/proof structure |
| Stacked PCS | `crates/sub_protocols/src/stacked_pcs.rs` | Polynomial stacking, width computation |
| Utils/parallel | `crates/utils/src/` | Parallelism patterns |

**Out of scope:** `monty_31/mds.rs`, `x86_64_avx512/*` (permutation internals — hardware-limited,
not the lever). Also out of scope: sumcheck, GKR, AIR, logup, field arithmetic, lean_vm, tests.

## Scope Rules
- Source code changes only. No build config, no bench crate.
- This experiment targets the commitment pipeline structure. Reduce total work
  or improve scheduling — not individual operations marginally faster.
- ONE logical change per iteration. Multi-file is fine. Correctness mandatory.
- Microbench to validate direction, e2e gate to decide keep/discard.
- Research papers and inspiration repos are valid inputs.

## The Metric

**Lower is better.** `xmss_leaf_1400sigs` e2e (~4.49s baseline).

The gate script (`eval_gate.sh`) decides keep/discard. It runs iai (instruction count)
then paired wall-clock comparison, then revert-A/B for marginal results. Trust its
verdict — don't manually interpret intermediate numbers.

## Profiling Commands

```bash
cd ~/zk-autoresearch/leanMultisig-bench
RUSTFLAGS="-C target-cpu=native -C force-frame-pointers=yes" cargo bench --bench xmss_leaf --no-run

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
2. **Understand the system first.** Read the target files. Instrument if needed (remove before bench). Answer the questions above with data.
3. **Profile after every keep.** Update the cost model if the distribution shifts.
4. Search inspiration repos when stuck (3+ consecutive discards).
5. Devise ONE targeted change. State: what structural property you exploit, expected permutation reduction or scheduling improvement, expected e2e signal.
5b. *Optional:* microbenchmark to confirm direction before e2e gate.
6. Edit source in `~/zk-autoresearch/leanMultisig/crates/` ONLY.
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

| Approach | Why it fails |
|---|---|
| Micro-optimizing permute_mut internals (inline hints, struct layout, copy elim) | LTO fragility: any code change to the hot path disrupts codegen, 2-8% regressions. 12 attempts, 0 keeps. |
| Parallelism threshold tuning (with_min_len, PARALLEL_THRESHOLD) | Below noise floor at e2e scale |
| Karatsuba MDS replacing FFT MDS | 72 muls vs 50 — wrong direction |
| Arity-4 Merkle trees | Total hash calls invariant with sponge compression (3 per 4-ary node vs 1 per binary) |

## Stop Criterion
12 consecutive discards = pause and report.

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
