# plan_spec — Iteration 7, h14: WHIR lazy-fold + FFT-prepare composite

Repo /home/ubuntu/zk-autoresearch/leanVM, branch goldilocks-ax42u, baseline HEAD 22fd8b5e.
protocol_depth = NONE (prover-only; transcript/proof bytes unchanged; net = wall).
predicted_pct = -1.5 [-0.9, -2.2]. Selection: sole survivor of 3 Plan agents (h15, h16
killed_at_plan — see hypothesis_pool history); composite enrichment per h12 precedent
because core central (-0.9) sits at the keep bar (h3 lesson).

Full core plan: Plan agent a6f8dff3 report (cost model, call-site enumeration, kernel
designs). Tasks below are binding; gates strictly ordered; one commit per task.

## CORE (product_computation.rs)

T0 — attribution profile (no commit). Warm prove + perf. The three kernels are distinct
symbols. GATE: R1 (fold_and_compute_product_sumcheck_polynomial) + R2-entry region
>= 100ms of the 250ms run_product_sumcheck span. KILL core if < 60ms.

T1 — refactor + equality harness (behavior-free commit). Extract eager path as
run_product_sumcheck_base_eager (verbatim, kept as oracle + fallback). Recording mock
FSProver (deterministic ChallengeSampler) in #[cfg(test)]. Tests generic over DIM using
existing koala-bear dev-dep (NO new deps; Cargo.lock untouched; no existing test
modified). GATE: workspace tests green; byte-diff IDENTICAL (refactor-only).

T2 — lazy round-1 + fused R2-entry (core commit).
- fold_weights_and_compute_lazy_round1: chunked 512-1024; pass A writes W' halves; then
  4 lazy-acc passes (c0*a, c0*b, c2*a, c2*b; 3 groups x 4 zmm budget per the R0-kernel
  precedent at product_computation.rs:208-211); bind r0 once per accumulator.
- materialize_double_fold_and_compute_round2: fused E''@2^24 via 4-term basis comb +
  W'->W'' fold + round-2 quad, one pass; hands off to sumcheck_prove_many_rounds(
  group@2^24, Some(r3), n_rounds-3) — verify against prove.rs:119-121 trailing-fold
  semantics.
- Dispatch: lazy iff (BasePacked, ExtensionPacked) && DIMENSION==3 && n_rounds>=2 &&
  n_vars>=18 (keeps bytecode_claims.rs:74 on eager). n_rounds==2 returns (E'',W'').
GATES in strict order: (a) EQUALITY FIRST — E1 lazy-R1 coeffs+W' bit-equal vs oracle;
E2 fused R2-entry vs fold-twice oracle; E3 full forced-lazy vs forced-eager under mock
FSProver: identical coeff sequences/challenges/sums/folds, n_vars 6..14 x n_rounds
{2,3,6}. (b) workspace tests green. (c) span: run_product_sumcheck <= 225ms over 3
interleaved A/B pairs. MIDPOINT-KILL: delta < 18ms -> revert T2, core dead. (d)
byte-diff IDENTICAL vs 22fd8b5e.

T3 — round-2 deferral. DEFAULT SKIP. Pre-gate: only if T2 >= 25ms AND post-T2 profile
shows fused R2-entry pass >= 35ms. Equality tests extended first. GATE: additional
>= 5ms else revert T3 (keep T2).

## C-F — FFT-prepare transpose tiling (crates/whir/src/utils.rs, gated component)

prepare_evals_for_fft_unpacked: current loop nest (col outer, r inner) makes writes
512B-strided (r*dft_n_cols+col); ~23 GiB/s effective vs ~39 ceiling, span 65ms. Tile
the (col, r) loops so stores are contiguous runs (col inner within a cache tile) while
keeping read streams within prefetcher limits (tile the col dimension; <= 16-32
streams). Output array must be byte-IDENTICAL (same values, same positions).
PRE-GATE: standalone microbench (production shape: 2^26 evals, folding_factor 6,
log_inv_rate 1, dft_n_cols from effective cols) tiled >= 1.3x current, else SKIP C-F.
GATES: equality test on output array (random + production shapes); span
prepare_evals_for_fft_unpacked <= 45ms over 3 interleaved pairs; byte-diff IDENTICAL.
One commit.

## Composite rules
- MIDPOINT: if core dies at T0/T2 AND C-F skipped or < 15ms -> no surviving sum >= 1.0%
  -> revert everything, discard iteration honestly.
- T-last (PARENT runs it, not the implementation agent): cargo fmt --check; workspace
  tests; correctness.sh --expect-protected-changes (Layer 0.8: only the inherited
  pre-h9-format flags acceptable per iter6 record — proofs must be byte-identical to
  22fd8b5e baseline); sustained-idle; eval_paired.sh --baseline 22fd8b5e --n 4; net =
  wall (proof delta 0); keep bar -1.0%, p < 0.01.

## Risks (from plan)
SIMD register spills (multi-pass chunk design; check perf annotate; kill on
spill-driven slowdown); P re-read cache-cold at R2-entry (already in traffic ledger);
arena: existing ArenaVec APIs only, zk-alloc untouched; bytecode_claims
transcript-length assert is the canary for the second call site.
