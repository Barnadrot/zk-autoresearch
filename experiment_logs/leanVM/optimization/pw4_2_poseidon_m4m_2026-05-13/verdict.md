---
experiment: pw4_2-poseidon-m4m
start_commit: c868330c
final_commit: f5f24964
cumulative_pct: 0.00
cumulative_p_value: n/a
keeps: []
discards: 4
orphans: 0
dead_ends_confirmed:
  - "h1 (Target A.1): x2 batched Poseidon1 permutation. AVX-512 register-spill mechanism does not apply on NEON; M4 OoO scheduler already saturates one permutation. Both attempts measured regression."
  - "h2 (Target C.1): first-layer compression fast-path. Phase-2-validated kill: WHIR_INITIAL_FOLDING_FACTOR=7 / WHIR_SUBSEQUENT_FOLDING_FACTOR=5 → full_base_width is 128/32/160/640 — never the WIDTH=16 the fast-path requires. Fires 0 times in prove_loop."
  - "h3 (Target D.1): precompute eq_middle per query. Regression (+0.52%, p=0.06) — M4 base 8 MB SLC + 4-query × 16 KB eq_middle vectors evict each other; the developer's own TODO comment warned about smaller caches."
  - "h4 (off-pool M4 P/E): 8-thread rayon pool. Attempt 1 crashed (custom pool incompatible with zkalloc's per-phase reset of late-spawned worker state). Attempt 2 worked but regressed +10.94% — losing 2 E-cores' compute capacity dominates over cvwait reduction."
  - "h5 (Target A.3): mds_fft constant fold. Phase-1 kill: critical-path math shows bt+lambda fusion has same 5-cycle depth as bt then separate lambda mul; identical mul count, no scheduling slack."
  - "h6 (Target A.2): single-permutation reschedule for ZMM budget. Phase-1 kill: NEON has 87% register headroom (4 of 32 Q-regs per state), no spill to fix. Secondary +rc fusion subanalysis showed unshortenable 15-cycle partial-round critical path."
  - "h7 (Target C.2): eliminate leaf-pad step. Phase-1 kill: open() path is per-QUERY not per-leaf, well below 0.5% profile floor; pool itself rated as 'sub-gate alone, viable as bundle' — no bundle target remains."
  - "h8 (Target D.2): Toom-Cook product folding. Phase-1 kill: prove_loop's product sumcheck is degree-2 (sumcheck_quadratic returns (P(0), leading_coeff)); D.2 mechanism applies only at degree-3+, requires protocol change."
  - "h9 (off-pool): rayon 12-thread oversubscription. Phase-1 kill: M4 has no SMT; oversubscription adds context-switch overhead. iter 4 already proved fewer-threads regresses, oversubscription strictly worse."
  - "h10 (off-pool): KoalaBear Montgomery codegen tuning. Phase-1 kill: monty_31 NEON emits canonical sqdmulh+mul+sqdmulh+shsub+cmgt+mla pattern, already minimal; no slack in instruction count or critical path."
  - "h11 (off-pool): Poseidon width reduction. Phase-1 kill: requires fresh cryptanalysis (same gate as Target E), doesn't ship as keep, doesn't count toward counter."
  - "h12 (off-pool): cargo release-profile tuning. Phase-1 kill: harness/leanmultisig/bench/Cargo.toml already at lto=fat + codegen-units=1, no remaining knob."
methodology_notes: |
  All four implemented attempts (h1-h4) followed the commit-eval-decide protocol: commit on
  pw4_2-m4m-2026-05-13 with [structural|medium] tag, run eval_paired.sh, git revert on
  discard. Phase-1-only kills (h5-h12) cite specific architectural/workload evidence
  derived from the initial profile baseline and the implemented-iter measurements; no
  Cargo.lock modifications, no off-main cherry-picks, all references stayed on
  origin/main of inspiration repos. Proof_size_check baseline range 330810-331753 bytes
  was confirmed non-deterministic (~0.3% natural variance from prover RNG); no iter
  introduced a proof-size regression beyond that floor.
---

# pw4_2-m4m verdict: systematic class-mismatch between Hetzner-tuned pool and Apple M4 NEON

## Summary

Twelve hypotheses tested across the brain-curated candidate pool (Targets A, C, D, E
sub-angles) plus four off-pool surfaces. **Zero keeps.** Cumulative Δ vs `origin/main @
c868330c` is unchanged. The pattern is consistent and the conclusion is structural: the
candidate pool's EV estimates were anchored to Hetzner Zen 4 + AVX-512 (the sibling
experiment's hardware) and do not transfer to Apple M4 NEON.

## What was learned

### 1. M4 NEON OoO scheduler already saturates one permutation

The iter-1 disassembly diagnostic compared `compress_layer.closure` symbol presence at
baseline (c868330c, no symbol = fully inlined into `MerkleTree::from_first_layer`) vs my
[structural] x2 batched candidate (5689-instruction symbol = outlined). The x2 batched
permute (Target A.1) was designed to expose cross-permutation ILP to the OoO scheduler
during MDS_FFT cross-stage butterfly chains and the partial-round serial point. Both
attempts (initial: trusting LLVM inliner; second: breaking the `#[inline(always)]` chain
to force `compress_x2` outlining and restore caller inlining) measured at +0.35% and
+0.93% respectively — i.e., regression or no change.

The mechanism the pool cited was AVX-512's 32 ZMM stack-spill at 2.22% self-time
(`vmovdqa64 %zmm3, 0x780(%rsp,%rsi,1)`). NEON's 128-bit-wide Q registers mean ONE state
fits in 4 of 32 Q-regs (87% headroom); two interleaved states fit in 8 of 32 (75%
headroom). The spill-relief mechanism is null. The remaining mechanism (ILP for OoO)
contributed measurably zero — strongly suggesting M4's scheduler already extracts
adequate ILP from a single permutation's data-parallel body across 4 SIMD lanes.

### 2. Pool workload preconditions don't fire in prove_loop

Target C.1's first-layer-compression fast-path requires `full_base_width == WIDTH == 16`
in `first_digest_layer`. The leanMultisig prove configuration uses
`WHIR_INITIAL_FOLDING_FACTOR=7` (n_blocks=128) and `WHIR_SUBSEQUENT_FOLDING_FACTOR=5`
(n_blocks=32). Both KoalaBear-base and QuinticExtension paths yield full_base_width ∈
{32, 128, 160, 640} — the fast-path's narrow precondition is **never satisfied** in the
prove_loop hot path. Measured Δ +0.32% (noise) confirms the fast-path was unreachable.

Target D.2's Toom-Cook product folding requires degree-3+ sumcheck univariates; the
prove_loop product sumcheck is degree-2 (`sumcheck_quadratic` returns `(P(0),
leading_coeff)` with `c1` derived from the sum constraint). No applicability.

### 3. M4-base cache pressure dominates over compute saving (D.1)

The dev's own TODO at `eq_mle.rs:419-421` warned "2x faster on M4 max, 2x slower on
smaller caches." On M4 base (8 MB SLC vs M4 Max's 32 MB), 4-query × 16 KB precomputed
eq_middle vectors evict each other from L1/L2 between tile chunks; the per-tile memory
reads cost more than the lazy expansion saves. Measured: +0.52% regression. The TODO
held.

### 4. M4 P/E parallelism overhead cannot be cheaply reclaimed

cvwait is 18.54% of self-time — the biggest non-Poseidon cost. The intuitive lever
(reduce thread count to less-heterogeneous subset) measured +10.94% regression: losing 2
E-cores' compute capacity (16% headroom drop) dominates over any cvwait reduction at 8
threads. M4-Pro/Max has higher P-core ratios and may behave differently; M4 base's 4P+6E
asymmetry makes E-cores load-bearing despite the heterogeneity tax.

## What was NOT learned (open surfaces deferred to next experiment)

- **AIR-side Poseidon evaluation** (`lean_vm::tables::poseidon_16` family): 5%+
  combined self-time. Generic `Algebra<KB>` arithmetic; whether NEON-packing is feasible
  is open.
- **Different rayon scheduling strategies** at the par_iter call-site level (custom
  chunk sizes per heterogeneous-worker-aware split): more invasive than the global pool
  tuning that was tested.
- **macOS QoS-class hints** on rayon worker threads (`pthread_set_qos_class_self_np`):
  worth a controlled trial but requires care around zkalloc thread registration (h4
  attempt 1 demonstrated the failure mode).

## Cross-platform note

The sibling experiment `pw4_2-2026-05-13` on Hetzner Zen 4 AVX-512 is independent; this
verdict makes no claim about its outcomes. The cross-platform delta is the meaningful
signal for the curated pool: if Hetzner finds keeps on A.1/A.2/A.3/D.1 (mechanisms
that target AVX-512 spill, ZMM register pressure, large SLC), that confirms the
ISA/cache-hierarchy specificity of those wins.

## Per-iter audit

See `iters.tsv` for the full hypothesis ledger, including predicted-Δ vs measured-Δ,
status classifications, file lists, and rationales. All implemented iterations
(h1-h4) appear in `git log` as `[tag]` commit + revert pair on `pw4_2-m4m-2026-05-13`.
