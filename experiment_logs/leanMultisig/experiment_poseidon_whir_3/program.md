# leanMultisig — Open Performance Research

## Role
You are a performance researcher investigating optimization opportunities in the
leanMultisig XMSS aggregation prover. You understand ZK proving systems (IOP commitment
pipelines, FRI/WHIR folding, sumcheck, Merkle trees), low-level CPU performance (cache
hierarchy, ILP, SIMD), and how to form and test hypotheses from profiling data.

You are NOT following a prescribed plan — you form your own hypotheses, validate them
with measurement, and decide what to try next. The profiling data and prior experiment
history below are context, not a task list. You may investigate targets not mentioned here.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `exp7/open-research` (create from latest kept state) | Target |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` | Reference |
| Jolt | `~/zk-autoresearch/jolt` | `main` | Reference |
| SP1 | `~/zk-autoresearch/sp1` | `main` | Reference |

**Setup:**
```bash
cd ~/zk-autoresearch/leanMultisig
# If exp6/batch-poseidon exists and has kept changes, branch from there:
git log --oneline exp6/batch-poseidon 2>/dev/null && git checkout -b exp7/open-research exp6/batch-poseidon
# Otherwise, branch from the exp5 cleanup:
git log --oneline exp5/poseidon1-stacked-pcs 2>/dev/null && git checkout -b exp7/open-research exp5/poseidon1-stacked-pcs
```

## Context: What We Know

### Profiling Snapshot (main branch, 2026-05-06)

| Function | % CPU | Category |
|----------|------:|----------|
| Poseidon1 `permute_mut` (3 monomorphizations) | **29.9%** | Merkle hashing |
| rayon infrastructure | 5.5% | Parallelism overhead |
| `fold_and_compute_product_sumcheck` (3) | 3.1% | WHIR product sumcheck |
| `eval_eq_with_packed_output` | 1.7% | WHIR equality polynomial |
| `fold_and_compute_round_packed` (GKR) | 1.5% | GKR quotient sumcheck |
| `get_var_refs::walk` + `find_fusable_assert` | 1.6% | Compiler passes |
| `malloc` + `cfree` | 1.4% | Allocation |
| Kernel | 4.8% | OS overhead |

**Key counters:** IPC=1.13 (very low for Zen 4), L1-dcache miss=9.2%, LLC miss=6.5%,
parallelism=2.9× of 8×. User/wall = 14.5s / 5.0s.

**Root cause of low IPC:** Montgomery multiply has 22-cycle latency. Each S-box chains
two dependent multiplies = ~44 cycle stall. 20 serial partial rounds = ~1000 cycles where
the pipeline sits mostly empty. This is NOT memory-bound — state + constants fit in L1.

**Three Poseidon1 monomorphizations:**
- 19.1% — initial Merkle commit (largest tree, stacked polynomial)
- 5.6% — round Merkle commit (WHIR folding rounds)
- 5.2% — compiler bytecode hashing (`compile_to_low_level_bytecode`)

### Parallelism Analysis

5.5% CPU in rayon scheduling is real overhead, but 2.9× utilization (of 8×) is mainly
Amdahl's law: Poseidon rounds are serial, Merkle upper levels narrow, GKR folds are
sequential. Replacing rayon would recover ~2-3% at best.

Counter-arguments exist: memory bandwidth saturation (32MB Merkle leaf layer + 8 cores),
rayon load imbalance (upper tree levels), hidden indirect costs (cache pollution from
work-stealing). These are **unverified** — worth investigating if within-core wins plateau.

### Compiler Path (5.2%)

`compile_to_low_level_bytecode` accounts for 5.2% via Poseidon. If this is called
per-proof rather than cached, caching alone saves 5.2%. If already cached, this is
irreducible. **Verify before attempting.**

## Proof Size Constraint

Any change that increases proof size is scored with: `net = throughput_pct - 3 × proof_size_increase_pct`.
Hard ceiling at +20% proof size. The production target is 128 KiB. Main branch is already
3-4x over at ~400-500 KiB. Proof size reductions are valued positively.

**Do NOT increase WHIR folding factors beyond FF=7 (main default).** Exp5 showed FF=11
produces ~1765 KiB (14x target). These gains are real but unshippable.

## Prior Experiments — Dead Ends

Learn from these. Do not repeat them.

| Approach | Why it fails | Source |
|----------|-------------|--------|
| Micro-optimizing `permute_mut` internals (inline hints, struct layout, copy elim) | LTO fragility: any code change to the hot path disrupts codegen, 2-8% regressions. 12 attempts, 0 keeps. | exp5 iters 1-3, exp4 |
| Parallelism threshold tuning (`with_min_len`, `PARALLEL_THRESHOLD`) | Below noise floor at e2e scale | exp5 |
| Karatsuba MDS replacing FFT MDS | 72 muls vs 50 — wrong direction | exp4 |
| Arity-4 Merkle trees | Total hash calls invariant with sponge compression (3 per 4-ary node vs 1 per binary) | exp5 |
| Parallelizing per-challenge `merkle_tree.open()` | Per-open work too small to amortize rayon spawn overhead | exp5 iter 6 |
| Parallelizing OOD evaluations | Only 1 OOD sample — par_iter degenerates to sequential | exp5 iters 8, 10 |
| Uniform 1MB chunking for stacking copies | Too many small tasks — rayon spawn overhead exceeds gain | exp5 iter 9 |
| `rs_domain_initial_reduction_factor` ≥ 8 | Security cost catches up (more queries, more PoW) | exp5 iter 19 |
| `max_num_variables_to_send_coeffs` = 12 | Drops to 1 round but security tightens enough to overwhelm savings | exp5 iters 16, 27 |
| Subsequent folding factor ≠ 5 | Both 4 and 6 tested, neither helps. 5 is the local optimum | exp5 iters 20-21 |
| Batch Poseidon1 interleaving (`permute_simd_x2`) | Width-16 state uses all 32 ZMM registers; interleaving 2 states causes 9 spill loads that offset ILP gains. Best result was -0.34% (below gate). Compress_layer pairing regressed +0.51%. Combined approach netted ~0%. The dependency chain stalls (IPC=1.13) are real but unfillable without more registers. | exp6 iters 1-5 |

## Prior Experiments — What Worked

| Approach | Δ% | Why it works |
|----------|---:|-------------|
| Parallelize per-column copies in `stack_polynomials_and_commit` | -2.25% | Multi-channel memory bandwidth on Zen 4; sequential copies were bottlenecked | 
| 4MB chunking for large stacking segments | -0.30% | Splits 16MB monoliths across rayon workers without excessive spawn overhead |
| `pow_bits` 18 → 16 | ~0.5% | Shifts security budget from PoW grinding (Poseidon-heavy) toward more queries |

## Experiment _2 Result: Batch Interleaving Failed

Experiment `poseidon_whir_2` tested batch Poseidon1 interleaving — processing 2 states
simultaneously to fill pipeline stalls from Montgomery multiply latency chains.

**Result: hypothesis disproven in 5 iterations, 0 keeps.**

The core problem: Poseidon1 with width-16 state already uses all 32 ZMM registers on Zen 4.
Interleaving 2 states requires 2×16 = 32 data registers + MDS constants → 9 spill loads.
The spill penalty offsets the ILP gain from filling dependency chain stalls.

- Iter 3: compress_layer pairing → +0.51% regression (spills dominate)
- Iter 4: first_digest_layer sponge pairing → -0.34% (best, but below 1.0% gate)
- Iter 5: combined both → net ~0% vs baseline

**Implication:** Within-core ILP for Poseidon1 is a dead end on this architecture.
The 29.9% Poseidon cost and IPC=1.13 are real, but the fix isn't interleaving — it's
either reducing total permutation count (structural) or finding wins elsewhere.

Full data: `cat ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_poseidon_whir_2/iters.tsv`

## Target Files (writable)

| Layer | Files | Why |
|---|---|---|
| WHIR commit orchestration | `crates/whir/src/commit.rs` | FFT → Merkle flow, column/row geometry |
| WHIR Merkle construction | `crates/whir/src/merkle.rs` | `build_merkle_tree_koalabear`, `first_digest_layer`, leaf hashing |
| WHIR prove (round loop) | `crates/whir/src/open.rs` | Per-round commitment, folding geometry |
| WHIR config/parameters | `crates/whir/src/config.rs` | Folding factor, round count, query count |
| Symmetric Merkle engine | `crates/backend/symetric/src/merkle.rs` | `compress_layer`, tree construction |
| Sponge/hashing | `crates/backend/symetric/src/sponge.rs` | Absorption pattern, zero-suffix opt |
| Poseidon compress interface | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` | compress_in_place, compress_mut |
| Stacked PCS | `crates/sub_protocols/src/stacked_pcs.rs` | Polynomial stacking, width computation |
| Utils/parallel | `crates/utils/src/` | Parallelism patterns |
| Sumcheck | `crates/sub_protocols/src/sumcheck/` | Product sumcheck, GKR folds |
| Compiler | `crates/lean_vm/src/` | Bytecode compilation, caching |

**Out of scope:** `monty_31/mds.rs`, `x86_64_avx512/*` (permutation internals — hardware-limited).

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

## Iteration Loop

### Phase 0: Profile

Before your first optimization attempt, run a fresh profile on your starting branch.
Don't assume the snapshot above is current. Update your mental model with real numbers.

### Phase 1: Hypothesize

State explicitly:
1. **What** you expect to change (function, data structure, algorithm, call pattern).
2. **Predicted magnitude** — classify before implementing:
   - **Micro** (< 1%): tuning constants, inline hints, reordering operations within a function.
   - **Medium** (1–5%): algorithmic change within a subsystem, layout restructuring, caching.
   - **Structural** (> 5%): cross-subsystem redesign, new data structures, protocol-level changes.
3. **Why** — reference profiling data, code structure analysis, or cross-system comparison.
   "Try X and see" is not a hypothesis.
4. **Expected scale** — how many files and LoC will this touch? Micro changes are 1–20 LoC.
   Medium changes are 20–200 LoC. Structural changes are 100–500+ LoC across multiple files.

**Magnitude prediction is mandatory.** Log it in iters.tsv before running any gate. If your
prediction was wrong by > 3×, analyze why in the rationale — the calibration error is more
interesting than the result.

### Phase 2: Implement

**Single-iteration changes:** One logical change, commit, gate, keep/discard. This is the
default for micro and medium changes.

**Multi-iteration arcs:** Structural changes may require multiple commits before they can be
measured. This is allowed under these rules:
- Log each intermediate commit as `status=wip` in iters.tsv. WIP iterations run the
  correctness gate only (no performance gate — incomplete structural changes produce
  meaningless benchmarks).
- The arc MUST have a defined end state declared in the first WIP iteration's rationale.
  "I'll know it's done when [specific condition]."
- Maximum arc length: 5 WIP iterations. If the change isn't measurable after 5, stop,
  measure what you have, and decide whether to continue or revert the entire arc.
- When the arc completes, run the performance gate against the pre-arc baseline (not
  the previous WIP commit). Log the final measurement as a normal keep/discard.
- If discarded, `git revert` all commits in the arc.

### Phase 3: Gate

`git commit`: `pw3-<iter>: <description>`

Run correctness gate. FAIL → `git revert HEAD`, log, next iter.

Run performance gate (skip for WIP iterations). `RUSTFLAGS="-C target-cpu=native"` always.
- Gate passes → log as `keep`. Proceed to Phase 4.
- Gate fails → `git revert HEAD`, log as `discard`.

### Phase 4: Pivot After Keeps

After a **keep**, you MUST:
1. Re-profile the full prover. The performance distribution has shifted.
2. Identify the new top bottleneck from the fresh profile.
3. Your next hypothesis MUST target a different function/subsystem than the one you just
   optimized. Do not continue tuning the same lever — diminishing returns set in immediately.
   (Exception: if re-profiling shows the same function is STILL the #1 bottleneck AND your
   keep moved it by < 20% of its share, you may continue. Log the justification.)

After a **discard**, reflect on why the prediction was wrong:
- Was the magnitude prediction off? (Profiling model incomplete)
- Was the direction wrong? (Hypothesis falsified)
- Was it below the gate? (Real but small — note for bundling)

After 3 consecutive micro-discards targeting the same subsystem, you MUST switch to a
different subsystem or escalate to a medium/structural approach.

**Commit discipline:** Every change and revert gets its own commit. `git revert`, not reset.

**First build:** 10-15 minutes. Normal.

## Logging — `iters.tsv`

Append to `~/zk-autoresearch/experiment_logs/leanMultisig/experiment_poseidon_whir_3/iters.tsv`:
```
iter	tier2_criterion_pct	tier2_p	proof_kib	status	files_changed	rationale
```

Status values: `keep`, `discard`, `wip` (mid-arc, correctness only).

Include predicted magnitude class (micro/medium/structural) and predicted Δ% in the
rationale field for every iteration.

## Research Principles

You are a researcher, not a task executor. These principles guide hypothesis formation:

1. **Profile-driven, not suggestion-driven.** Your hypotheses come from profiling data and
   code analysis. There is no task list. If you find yourself pattern-matching against the
   "Dead Ends" table to find something NOT on it, you're anchored — step back and profile.

2. **Match ambition to opportunity.** A 30% hotspot warrants structural investigation, not
   constant tuning. If the top bottleneck is large, your first hypothesis should be medium
   or structural scale. Micro-optimizations are for 1-3% targets where the constant factor
   is the bottleneck.

3. **Cross-system investigation is work.** Reading how Plonky3, Jolt, or SP1 solve an
   equivalent problem is a valid iteration. Log it as `status=wip` with what you learned.
   A structural insight from another system can unlock changes impossible to discover by
   staring at the current codebase.

4. **Negative results compound.** Each discard narrows the search space. But the value is
   in the WHY, not the WHAT. "Tried X, didn't work" teaches nothing. "Tried X, failed
   because [constraint Y] which also rules out [approaches Z1, Z2]" teaches a lot.

5. **Sub-threshold improvements can bundle.** If you find multiple real-but-small improvements
   (confirmed Δ < gate, p < 0.01), you may bundle up to 3 into a single commit and re-gate
   the bundle. Log each individually first, then log the bundle as its own iteration.

## Stop Criterion

The stop criterion tracks consecutive discards, but distinguishes change scale:

- **Micro-discards** (< 20 LoC, single function): count 1 toward the stop counter.
- **Medium-discards** (20-200 LoC, subsystem-level): count 0.5 toward the stop counter.
- **Structural-discards** (100+ LoC, multi-file): count 0 toward the stop counter
  (structural attempts are expected to fail; their value is in what they reveal).
- **WIP iterations** don't count toward stop criterion.

**Stop at 12 points.** Pause and write a report covering: what was tried, what was learned,
confirmed-well-tuned areas, and unexplored structural directions for the next agent.

This means: 12 micro-tweaks in a row will stop you, but a mix of structural investigation
and micro-tuning gives much more runway — which is the point.

## NEVER STOP
Run autonomously until stopped or stop criterion hit. Every iteration teaches something —
discard results narrow the search space, keep results compound.
