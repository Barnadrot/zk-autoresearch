# leanMultisig — Poseidon Performance Research (pw4)

## Role
You are a performance researcher investigating optimization opportunities for Poseidon-touching paths in the leanMultisig XMSS aggregation prover. You understand ZK proving systems (FRI/WHIR folding, sumcheck, Merkle trees), low-level CPU performance (cache hierarchy, ILP, SIMD, AVX-512 mul-port throughput), and how to form and test hypotheses from profiling data.

You are NOT following a prescribed plan. The candidate pool below is a starting set of surfaces, not a task list. You form your own hypotheses, validate with measurement, and decide what to try next. You may investigate targets not in the pool if profiling justifies it.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `pw4-2026-05-12` (set by coordinator from `origin/main`) | Target |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` | Reference (for `permute_state_x2` pattern, FFT identities) |
| Jolt | `~/zk-autoresearch/jolt` | `main` | Reference (Dory commitments, sumcheck batching) |

**Concurrent work — DO NOT redo:** PR #216 (`myfork/perf/poseidon-fft-mmo`, in flight, NOT in baseline) already carries: AIR `mds_air_16` Karatsuba → FFT-MDS, sponge RATE=8 → RATE=12, MMO (Davies-Meyer) feedforward at WIDTH=16 / capacity=4 for 124-bit collision, and `#[inline]` thin-LTO tuning. **These will land separately.** The pw4 candidate pool is selected to be **independent of PR #216** — pick surfaces that compose with it, not duplicates of it.

**Setup:**
```bash
cd ~/zk-autoresearch/leanMultisig
git rev-parse --abbrev-ref HEAD     # MUST be pw4-2026-05-12, NOT main
git log -1 origin/main --pretty=format:'%h %s'   # baseline you measure against
```

## Context: Profiling Snapshot

Full Hetzner profiling baseline at `~/zk-autoresearch/experiment_logs/leanMultisig/pw4_poseidon_2026-05-12/baseline_profiling_hetzner.md` (committed alongside this program.md). Headline numbers below; read the full report for line-level annotations and the rayon decomposition.

### Per-crate cycle distribution (`origin/main`, parallel, 11.75s wall)

| Subsystem | Share | What it is |
|---|--:|---|
| `mt_koala_bear` (Poseidon1 perm + Montgomery + AVX-512 packing) | **~27%** | The dominant compute kernel |
| `lean_vm` (AIR tables — Poseidon, Execution, etc.) | **~13%** | AIR-side compute, same primitive |
| `mt_sumcheck` (product sumcheck rounds) | **~12%** | Quintic-extension mul + add inner loop |
| `sub_protocols` (quotient-GKR sumcheck + air_sumcheck) | **~9%** | Same shape, different protocol |
| `mt_whir` (DFT + open + commit) | **~7%** | FRI butterfly + linear combine |
| `mt_poly` (eq-MLE + multilinear utilities) | **~6%** | Eq-poly construction for sumcheck |
| Kernel + rayon scheduler + framework + other | ~26% | Page faults, atomics, dispatch, residual |

### Top inclusive call-graph paths

1. `Poseidon1KoalaBear16::compress_mut` — **22.37% inclusive / 22.28% self** (single dominant symbol). Top hot LINE is a stack spill `vmovdqa64 %zmm3, 0x780(%rsp,%rsi,1)` at 2.22% — register pressure inside the 16-state permutation is the binding constraint.
2. `Poseidon1KoalaBear16::permute_simd::mds_fft` — 7.99% inclusive — MDS-as-FFT kernel
3. `PackedMontyField31AVX512::Mul + packing::mul` — 6.73% — Montgomery vector multiply
4. `eval_2_full_rounds_16` — 5.71% inclusive / 5.03% self — AIR-side first two rounds
5. `mt_sumcheck::fold_and_compute_product_sumcheck_polynomial` — 4.30% inclusive / 3.59% self
6. `mt_poly::eq_mle::eval_eq_with_packed_output` — 4.28% inclusive / 4.24% self

### Hardware counters

| Metric | Serial (`RAYON_NUM_THREADS=1`) | Parallel |
|---|--:|--:|
| **IPC** | **1.29** | **0.82** |
| Per-core clock | 5.116 GHz | 4.156 GHz (19% throttle) |
| Branch miss rate | 3.00% | (same) |
| L1D miss rate | 10.36% | (same) |
| LLC miss rate | 6.47% → **~15% of parallel cycles in DRAM waits** | n/a serial |
| dTLB miss rate (subset) | 58.99% → **~3% of cycles in PTW** | (same) |
| Frontend stalls | 6.33% | (same) — not a bottleneck |
| Parallel speedup (prove only) | n/a | **6.31× on 9.04 CPUs (70% efficient)** |

## Bottleneck Classification

**leanMultisig prove_loop is COMPUTE-BOUND on integer multiplier throughput.** Serial IPC 1.29 ≈ Zen 4 `vpmuludq` mul-port ceiling (the pipeline IS well-populated; the prior "latency-bound by Montgomery dependency chains" framing is refuted by this number). Two regimes:

- **Serial:** mul-port-throughput-bound on `vpmuludq`. Branch, L1D, frontend all sub-bottleneck.
- **Parallel:** mul-port + ~15% of cycles in DRAM waits (L3/SMT contention as 14 workers share LLC) + ~3% in dTLB walks. IPC drops 1.29 → 0.82 (−37%).

**Hypothesis-shaping implication:**
- Mul-port-relieving changes (fewer mults per round, batch-independent muls for ILP, smaller MDS coefficients mapping to shifts+adds) lift the serial ceiling and consequently the parallel ceiling.
- DRAM-contention-relieving changes (cache-blocking sumcheck/WHIR streaming loops, huge-page mappings, false-sharing audits) attack the ~15-18% parallel-specific slice.
- Permutation-count reductions (Merkle topology, leaf packing, FRI query-count via tighter soundness, transcript batching) reduce work in both regimes.

## Candidate Pool

Starting surfaces with predicted ranges. You are NOT required to pick from these — they're entry points. Profile-driven hypotheses on other surfaces are equally valid.

### Tier 1 — Mul-port-relief (attack the serial 1.29 IPC ceiling, universal across machines)

Ranked by survey EV. Items 1 and 3 share the same register file — **do NOT combine them in one iteration** without re-measuring register pressure; the mul-port gain from interleaving can be wholly absorbed by spill loads from a parallel register-pressure-relief change.

1. **Independent-state interleaving — implement a new `permute_state_x2` entry point** that processes 2 width-16 Poseidon states in lockstep so the mul issue slots fill across state A and state B. (The function does not exist yet; you write it, then route Merkle/sponge call-sites that handle pairs of states through it.) Predicted +8-12% Hetzner. Caveat: a prior attempt (exp6 iters 1-5) hit 0% net because width-16 already uses all 32 ZMM registers and naive interleaving forced 9 spill loads. The retry path is a redesign keeping fewer state elements simultaneously live (MDS constants in streamed reload, partial-round subsets resident only). Composes multiplicatively with #2.
2. **Delayed Montgomery reduction across the partial-round S-box chain** — keep `state[0]` in a wider accumulator across consecutive partial rounds, reducing only when the bound forces it. Predicted +3-6%. Constraint: each partial round applies S-box `x^3` then a sparse-MDS linear step; you need to bound the post-MDS magnitude so that the un-reduced value stays inside the accumulator width (i.e., the accumulator must hold `S_max^3 · |MDS_row|_1` before redux). Derive the maximum chain length under that bound; it's small (likely 1-3 rounds between reductions), but every saved redux is roughly one `vpmuludq` removed.
3. **Register-pressure reduction inside `compress_mut`** — the top hot line is a stack spill `vmovdqa64 ... 0x780(%rsp,...)` at 2.22% self. Width-16 with 8 full rounds + 20 partial rounds keeps a large fan of round constants and sparse-MDS rows live simultaneously; defer their loads to point-of-use so fewer values are resident across the round. Conflicts with #1 on register file; pick one, not both.
4. **MDS coefficient re-search for ≤4-magnitude entries** — current MDS uses 67, 63, 101. A circulant column with entries ≤ 4 maps multiplies into shifts+adds. Predicted uniform +3-7%. **Cryptanalysis-gated** (MDS property, branch number ≥ 17 over KB) — if you produce a candidate matrix, log the rationale and flag in the iter; brain routes to Emile for sign-off. Do not ship without sign-off.
5. **Sparse partial-round MDS audit** — verify the existing factorization (`compute_equivalent_matrices`) doesn't leave residual dense entries that could be zeroed. Small-medium.

### Tier 2 — Permutation-count reduction (multiplies cleanly across regimes)

- **Jagged-PCS leaf packing** — multi-poly batched commits sharing leaves. SP1 Hypercube claims 5× on this lever. Predicted uniform +4-8%. Touches `stacked_pcs.rs` and Merkle leaf assembly.
- **First-Merkle-layer multi-leaf absorption (19% of cycles)** — measure how often `precompute_zero_suffix_state` actually fires under the current RATE=8 sponge (note: pw3-33 already shipped RATE=12 for −5.30%; check whether further capacity-budget moves are available without breaching 124-bit collision).
- **Tree-pruning for shared paths in WHIR query phase** — cache sibling hashes during open when many query indices share Merkle ancestors. Pure encoding optimization, no security impact.
- **`pow_bits` security-budget rebalance** — exp5 dropped 18→16 for ~−0.5%. Further audit whether other parameters trade Poseidon work for query work favorably.

### Tier 3 — Adjacent compute (conditional trigger)

- **Poseidon ⊗ eq-MLE / sumcheck kernel fusion** — adjacent-compute surface is large: `mt_sumcheck` 12% + `mt_poly` 6% + `sub_protocols` 9% = **27% Hetzner**, comparable to Poseidon's 27% in `mt_koala_bear`. **Dispatch when:** the Tier-1 stack lands a cumulative ≥10% keep AND a fresh profile shows Poseidon's share dropping below sumcheck/eq-MLE. Until then, Tier 1/2 has higher EV.

## Proof Size Constraint

Production target is 128 KiB. Main branch is already 3-4× over at ~400-500 KiB. Score: `net = throughput_pct − 3 × proof_size_increase_pct`. Hard ceiling at +20% proof size. Reductions valued positively.

**Do NOT raise WHIR folding factors beyond FF=7.** FF=11 produces ~1765 KiB (14× target). Gains are real but unshippable.

## Prior Experiments — Dead Ends

Learn from these. Do not repeat them.

| Approach | Why it fails | Source |
|----------|-------------|--------|
| Micro-tuning `permute_mut` internals (inline hints, struct layout, copy elim) | LTO fragility: any change to the hot path disrupts codegen, 2-8% regressions. 12 attempts, 0 keeps. | exp4, exp5 iters 1-3 |
| Karatsuba MDS replacing FFT MDS in **permutation** path | 72 muls vs 50 — wrong direction | exp4 |
| Arity-4 Merkle trees | Total hash calls invariant with sponge compression (3 hashes per 4-ary node vs 1 per binary) | exp5 |
| Parallelizing per-challenge `merkle_tree.open()` | Per-open work too small to amortize rayon spawn overhead | exp5 iter 6 |
| Uniform 1MB chunking for stacking copies | Too many small tasks — rayon spawn exceeds gain | exp5 iter 9 |
| `rs_domain_initial_reduction_factor` ≥ 8 | Security cost catches up (more queries, more PoW) | exp5 iter 19 |
| Subsequent folding factor ≠ 5 | Both 4 and 6 tested, 5 is the local optimum | exp5 iters 20-21 |
| `permute_simd_x2` independent-state interleaving (naive) | Width-16 state uses all 32 ZMM registers; naive 2-state interleaving forces 9 spill loads that offset ILP gains. Net ~0% across 5 iters. **Note:** A redesign keeping fewer state elements simultaneously live (see Tier 1 #1) may still work. | exp6 iters 1-5 |
| pw3 micro-tuning phase (iters 1-12) — knob-turning on `permute_mut`, `eq_mle` tile sizes, `pair_coeffs` CSE | All sub-gate (best near-miss: pair_coeffs CSE −0.41%, below 1.0% threshold). Confirmed micro-knob tuning is exhausted on `origin/main`. **Implication:** start at medium or structural scale. Don't waste cycles on sub-1% knob tuning. | pw3 iters 1-12 |

## Prior Experiments — What Worked

These are wins applied to `origin/main` (the pw4 baseline). The big pw3 keeps (FFT-MDS, RATE=12 sponge, MMO 124-bit) are NOT here because they live in PR #216 — see "Concurrent work" note above.

| Approach | Δ% | Why |
|---|---:|---|
| exp5: parallelize per-column copies in `stack_polynomials_and_commit` | −2.25% | Multi-channel memory bandwidth on Zen 4; sequential copies were bottlenecked |
| exp5: 4MB chunking for large stacking segments | −0.30% | Splits 16MB monoliths across rayon workers without excessive spawn overhead |
| exp5: `pow_bits` 18 → 16 | ~−0.5% | Shifts security budget from PoW grinding (Poseidon-heavy) toward queries |

**Pattern from pw3 (in PR #216, off-baseline):** the meaningful wins were structural algorithmic changes (mult count reduction, sponge rate/capacity retuning, feedforward construction for collision-resistance budget), NOT knob tuning. The pw4 candidate pool selects from the same shape, on surfaces PR #216 does not touch.

## Target Files (writable)

| Layer | Files | Why |
|---|---|---|
| Poseidon permutation interface | `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` | `compress_in_place`, `compress_mut`, MDS coefficient definitions, sparse factorization |
| Symmetric Merkle engine | `crates/backend/symetric/src/merkle.rs` | `compress_layer`, tree construction, leaf hashing |
| Sponge / hashing | `crates/backend/symetric/src/sponge.rs` | Absorption pattern, zero-suffix opt, multi-leaf path |
| Sumcheck core | `crates/backend/sumcheck/src/` (prove, product_computation, sc_computation, split_eq), `crates/sub_protocols/src/air_sumcheck.rs`, `crates/sub_protocols/src/quotient_gkr/` | Product sumcheck, AIR sumcheck, GKR layer rounds, kernel-fusion opportunities |
| Eq-MLE / multilinear | `crates/backend/poly/src/` | `eval_eq_with_packed_output`, packed-output helpers |
| WHIR commit + open | `crates/whir/src/commit.rs`, `merkle.rs`, `open.rs` | FFT → Merkle flow, per-round commit, query-phase tree-pruning |
| WHIR config / parameters | `crates/whir/src/config.rs` | Folding factor, round count, query count, PoW bits |
| Stacked PCS | `crates/sub_protocols/src/stacked_pcs.rs` | Polynomial stacking, jagged-PCS leaf packing |
| Compiler | `crates/lean_vm/src/` | Bytecode compilation; cache audits |

## Out of Scope

- `monty_31/mds.rs`, `x86_64_avx512/*` — Plonky3 packed-field internals; hardware-bound, shared upstream.
- Hash-function replacement. Poseidon1 width-16 KoalaBear stays. (The compiler bytecode hash uses Poseidon1 because its output is recursed inside the AIR; a Blake3 swap there breaks the recursion path.)
- Security-parameter changes beyond the proof-size scoring rule above without explicit cryptanalysis reasoning in the rationale.

## Eval Gates

### Correctness
```bash
bash ~/zk-autoresearch/harness/leanmultisig/correctness/correctness.sh
```
Exit codes: 0=pass, 1=fail, 2=nondeterminism (rayon data race), 3=test-file integrity violation. Anything ≠ 0 → `git revert HEAD`, do NOT run the performance gate.

### Performance
```bash
bash ~/zk-autoresearch/harness/leanmultisig/scripts/eval_paired.sh
```
Threshold (set by `harness/leanmultisig/scripts/config.env`): −1.0% with p < 0.01. Revert-A/B confirmation for structural keeps.

## Iteration Loop

### Phase 0: Read the profiling data
The profiling snapshot above + `baseline_profiling_hetzner.md` is your ground truth. Do **not** re-run perf yourself — it costs 20-30 min of build + record and the numbers won't change materially against `origin/main`. Re-profile only when a kept change shifts distribution enough that the snapshot stops describing your target (Phase 4 trigger).

### Phase 1: Hypothesize
State explicitly:
1. **What** changes — function, data structure, algorithm, call pattern.
2. **Magnitude class:**
   - **Micro** (< 1%, 1–20 LoC): tuning constants, inline hints, reordering within a function.
   - **Medium** (1–5%, 20–200 LoC): algorithmic change within a subsystem, layout restructuring, caching.
   - **Structural** (> 5%, 100–500+ LoC, multi-file): cross-subsystem redesign, new data structures, protocol-level changes.
3. **Why** — profiling data, code structure, or cross-system comparison. "Try X and see" is not a hypothesis.
4. **Predicted Δ%.** Log before gates. If wrong by >3×, analyze in the rationale.

### Phase 2: Implement
**Single-iteration:** one logical change, commit, gate, keep/discard. Default for micro and medium.

**Multi-iteration arc (structural only):**
- Each intermediate commit logged as `status=wip`. WIP runs correctness gate only.
- The arc MUST declare its end state in the first WIP's rationale: "I'll know it's done when [specific condition]."
- Maximum 5 WIP iterations. After 5, stop and measure, or revert the arc.
- On completion, performance-gate against the pre-arc baseline.
- If discarded, `git revert` every commit in the arc.

### Phase 3: Gate
`git commit -m "pw4-<iter>: <description>"` on `pw4-2026-05-12` (never main).

- Correctness fails → `git revert HEAD`, log, next iter.
- Performance fails → `git revert HEAD`, log as `discard`.
- Both pass → log as `keep`. Proceed to Phase 4.

### Phase 4: Pivot
After a **keep**:
1. Re-profile. Distribution has shifted.
2. Identify the new top bottleneck.
3. Next hypothesis MUST target a different function/subsystem. (Exception: if re-profile shows the same function is STILL #1 AND your keep moved its share by < 20%, you may continue. Log the justification.)

After a **discard**, reflect on why prediction was wrong:
- Magnitude off? (Profiling model incomplete.)
- Direction wrong? (Hypothesis falsified.)
- Below gate but real? (Note for bundling — see Research Principles.)

After 3 consecutive micro-discards in the same subsystem, switch subsystem or escalate to medium/structural.

## Logging — `iters.tsv`

Append to `~/zk-autoresearch/experiment_logs/leanMultisig/pw4_poseidon_2026-05-12/iters.tsv`:
```
iter	magnitude	predicted_pct	measured_pct	proof_kib	status	files_changed	rationale
```
Status: `keep`, `discard`, `wip`.

## Research Principles

1. **Profile-driven, not suggestion-driven.** Hypotheses come from profiling data and code analysis. The candidate pool is starting context; if profiling justifies a different target, attack it. If you find yourself pattern-matching against "Dead Ends" to find something NOT listed, you're anchored — re-profile.
2. **Match ambition to opportunity.** A 27% subsystem warrants structural investigation, not constant tuning. pw3 already showed knob-tuning is exhausted on this branch. Default to medium/structural.
3. **Cross-system investigation is work.** Reading how Plonky3, Jolt, or SP1 solve an equivalent problem is a valid iteration. Log as `wip`. A structural insight from another codebase can unlock changes invisible from inside ours.
4. **Negative results compound.** Each discard narrows the search. Value is in the WHY: "Tried X, failed because [constraint Y] which also rules out [Z1, Z2]" teaches more than "Tried X, didn't work."
5. **Sub-threshold bundling.** If you find multiple real-but-small improvements (Δ < gate, p < 0.01), you may bundle up to 3 into one commit and re-gate. Log each individually first, then the bundle.

## Stop Criterion (point system)

Weighted stop counter — distinguishes change scale so structural attempts don't burn the budget:

- **Micro discard** (< 20 LoC, single function) → +1.0 point
- **Medium discard** (20–200 LoC, subsystem) → +0.5 point
- **Structural discard** (100+ LoC, multi-file) → +0 point (expected to fail; value is in what they reveal)
- **WIP iterations** → +0 point
- **Any keep** → reset counter to 0

**Stop at 12 points.** Twelve micro-tweaks in a row stops you; a mix of structural investigation and micro-tuning gives much more runway — which is the point.

On stop: write `verdict.md` (kept iterations summary, cumulative Hetzner Δ, what was learned, recommendations for the next experiment) and `pr_body.md` (drafted PR body for brain to review).

## NEVER STOP
Run autonomously until stopped or stop criterion hit. Every iteration teaches — discards narrow the search, keeps compound.

Build with `RUSTFLAGS="-C target-cpu=native"` always. First build ~10–15 min, normal.
