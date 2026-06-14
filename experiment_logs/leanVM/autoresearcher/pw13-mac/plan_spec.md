# plan_spec — iter 1: h-wf "whir-lazy-fusion" (composition c2)

Source plan: report/hypothesis_2/whir-initial-sumcheck-fusion.md (anchors verified against
pw13-mac @ 938a2ced). Transcript-identical prover optimization; proof bytes must be EQUAL.
Gate baseline for eval_paired: 938a2ced (pre-plan HEAD).

## Task checklist

- [x] Task T0: kill-ladder rung benches (T0a lazy-vs-stream weight, T0b EF×EF vs base×EF ratio) — ACCEPT 45cfb1ab; spec 0.76 PASS, e2e 1.26 ⇒ lazy-ONCE redesign; MAX_SLICES=2
- [x] Task T1: lazy-once fused combine+round-0 + proof-equality test — ACCEPT (eb1568f1 + 8cdca03a review fixes; byte-identical proofs at n {18,22,26} incl. dual-arm coverage)
- [x] Task T2: segment-hoisted fused kernel — ACCEPT (d692efbc; 119→112ms, mul floor recorded; h-wf running total −14ms)
- [x] Task T3: DelayedEf rounds-2/3 slices — ACCEPT (134c624d; algebra independently re-derived by reviewer; run_initial 262→251ms; h-wf cumulative ~−25ms span / ~−1.0% e2e single-run)
- [x] (T3-parallel-hardening absorbed into T2's segment-hoisting; spans verified per-commit)

RESCOPE RATIONALE (T1 production tracing, 1550-sig): fused pass 119ms ≈ combine 121ms — both
mul-bound at the same count; only the round-0 read pass (~15ms) was truly saved; span −8ms,
e2e −0.4%. The original T2/T3 order inverted: kernel optimization (originally T3 scope) is
now the path to clearing the −1.0% gate; delayed-EF is the conditional tail.

## Task T0 — kill-ladder rung benches (one commit, test-only)

Files: `crates/whir/src/open.rs` (#[cfg(test)] mod fusion_bench — private access to
combine_statement + SparseStatement), `crates/backend/sumcheck/src/product_computation.rs`
(#[cfg(test)] ratio bench) — or both in open.rs if visibility allows.

- T0a: build a representative 15-statement set at n_vars=26 mirroring
  stacked_pcs_global_statements shapes: 2 full (selector 0), several dense-eq selector_len 1-3,
  2-3 is_next, sparse multi-selector. Measure (a) stream baseline = combine_statement +
  one streaming read pass; (b) lazy chunked prototype = per-chunk Σ_s γ^{k_s}·weight_s via
  SplitEq-style prefix/suffix sharing. Print ns totals + ratio.
  GATE: lazy ≤ 1.3× (combine+read) → PASS; 1.3-2.0× → GRAY (need T0b win); > 2.0× → KILL.
- T0b: compute_product_sumcheck_polynomial cost on (BasePacked, ExtensionPacked) vs
  (ExtensionPacked, ExtensionPacked) at 2^20..2^23 packed. Print ratio per size; pins
  MAX_SLICES (expected 2-3). GATE: ratio < 2 AND T0a > 1.3× → KILL.
- Harness: #[test] #[ignore], std::time::Instant, black_box, no criterion, no Cargo.lock
  change, no benches/ dir.
- Invariants: zero production-code change; imports of private items only inside cfg(test).
- Tests: `cargo test -p whir --release -- --ignored fusion_bench --nocapture` runs and prints
  verdicts; `cargo build --workspace` green.
- Rollback: revert the commit; zero production surface.

## Task T1 — lazy-ONCE fused combine+round-0 (one commit) [REDESIGNED after T0a]

T0a evidence (938a2ced bench): memory passes are nearly free on M4 (1.34 GB read = 12-15ms);
the cost of combine_statement (158ms at bench scale) is the EF arithmetic + RMW scatter, and
evaluating weights lazily TWICE (round-0 + round-1-fold) is net SLOWER (ratio_e2e 1.26).
MANDATED DESIGN: evaluate weights lazily exactly ONCE — fuse combine INTO round 0:
per chunk, compute w[j] in-register from the term tables, accumulate round-0 (c0,c2), AND
stream-write w[j] to the materialized buffer. Round 1+ proceed on the materialized buffer
UNCHANGED (fold_and_compute as today). Expected saving ≈ the RMW/multi-pass overhead of
combine (~30-40ms at production scale) — bench-confirmed shape, not memory-bandwidth-based.

Files: `crates/whir/src/open.rs`, `crates/backend/sumcheck/src/product_computation.rs`.

- LazyTerms { full: Vec<FullT>, dense: Vec<DenseT>, overlay } built by
  `build_lazy_terms(statements, gamma) -> (LazyTerms, EF)` replaying combine_statement's
  exact γ-power accounting (incl. dual fast-path start_idx 2/1/0) — combined_sum bit-equal,
  debug_asserted. Tiny statements (inner < packing width or lane-level: public input, pc
  cells) handled by a SparseOverlay arm (exact, not skipped).
- `combine_and_compute_product_sumcheck_polynomial(evals, terms, sum) ->
  (DensePolynomial, ArenaVec<EFPacking>)`: one parallel pass, same (c0,c2)+c1-from-sum
  skeleton, writes the materialized weight buffer + returns round-0 poly. Round 1+
  (fold_and_compute, sumcheck_prove_many_rounds) untouched.
- Wiring in run_initial_sumcheck_rounds (open.rs:410-444) behind env toggle
  WHIR_LAZY_COMBINE (default on; off = legacy combine_statement + compute_product path);
  `bytecode_claims.rs:74` caller untouched.
- Proof-equality test (T4-style): prove twice (toggle off/on), assert identical proof bytes +
  verifier accepts, at n_vars ∈ {18, 22, 26}, several seeds + statement shapes covering every
  WeightTerm arm. Lives in `crates/whir/tests/` alongside existing run_whir test.
- Invariants: γ-power order identical; accumulation order fixed = statement order;
  packing_width==1 falls back to Materialized; combined_sum equality debug-checked.
- Tests: workspace green; `cargo test -p whir` incl. the new equality test with both toggle
  states; existing run_whir untouched.
- Rollback: toggle false = byte-identical legacy path; full revert leaves combine_statement +
  run_product_sumcheck intact.

## Task T2 — segment-hoisted fused kernel (one commit) [RESCOPED]

Replace per-index term dispatch in combine_and_compute_first_round with run-segmented
iteration: process j in aligned runs of length min(2^rshift_full, 2^grid_log) so the
full-term left factors and the cell's block contexts (inner-table base pointers + scalars)
are hoisted out of the inner loop; pair side (half+j) hoisted symmetrically. Muls unchanged
(~15 packed/word irreducible); removes Vec double-indirection + bounds checks + left
lookups per index. Gate: production combine_and_compute span 119ms -> <= 105ms, else
record ceiling and proceed to gate decision with honest numbers. Proof-equality test must
stay green (bit-identical).

## Task T3 — DelayedEf slices for round-1 eval-fold (one commit) [CONDITIONAL, was T2]

T0b measured EFxEF/basexEF = 2.29 => MAX_SLICES = 2: exactly ONE delayed round is
profitable, margin ~13%. Scope: in round-1's fold_and_compute, keep the EVALS side as 2
base slices with EF coefficients (skip the base->EFPacking promotion muls), run round-2's
product as 2x(basexEF), collapse before round 3. Skip entirely if the measured kernel win
< 3% of the r1fold+r2 time (record and close p10 for this context).

Files: `crates/backend/sumcheck/src/product_computation.rs` (additive), open.rs wiring.

- struct DelayedEf { slices: [ArenaVec<PFPacking>; 2], coeffs: [EF; 2] }; collapse() ->
  ExtensionPacked single pass.
- Round-2 kernel: per-slice basexEF partial (c0,c2) accumulators, ONE EFxEF scale by
  coeffs at the end.
- Gated by WHIR_DELAYED_EF (env); off = T1 output bit-identical.
- Extend the proof-equality test matrix: (lazy, delayed) ∈ {(0,0),(1,0),(1,1)} all equal
  bytes; MAX_SLICES ∈ {1,2,3} all equal bytes (switch-over must not change transcript).
- Invariants: (c0,c1,c2) bit-identical (exact-field reassociation only); no rayon; no alloc
  in hot loops.
- Rollback: USE_DELAYED_EF=false instantly; revert commit fully — types are additive.

## Task T3 — parallel hardening + span verification (one commit)

- All new hot loops on `parallel` crate primitives (map_reduce/map_reduce_with_state/
  par_chunks_mut); PARALLEL_THRESHOLD small-size fast paths mirrored; LazyWeight kernel
  allocation-free; oversubscription idiom for P/E rebalance where eq_mle uses it.
- Run `lean-multisig xmss --n-signatures 1550 --tracing`: combine_statement span must be
  gone/â‰ª, run_initial_sumcheck_rounds span reduced; record numbers in commit message.
- Tests: workspace green; equality test still green both toggles.
- Rollback: revert commit (changes confined to new fns).

## After T3

Correctness gate (`bash ~/zk-autoresearch/harness/leanvm/correctness/correctness.sh`) — no
protected files touched, normal mode. Then performance gate
`bash ~/zk-autoresearch/harness/leanvm/scripts/eval_paired.sh --baseline 938a2ced --candidate HEAD`
(pre-plan baseline per program.md; no other compute during the gate). Log to iters.tsv,
refill pool, post-keep flamegraph if kept.

---

# plan_spec — iter 2: h-ep "air-efround-pack" (composition c1)

Source plan: report/hypothesis_5/air-efround-pack-plan.md (Plan-agent, anchors verified at
938a2ced; baseline now c8ea299c — re-verify drifted line anchors during T0). Transcript-
identical prover optimization of the batched AIR sumcheck (569ms span). Gate baseline for
eval_paired: c8ea299c (pre-plan HEAD, iter-1 keep included). predicted_pct -2.3 central.

## Task checklist (iter 2)

- [x] Task U0: h-ep kill-ladder — U0c identities PASS (3 production rounds); U0a PASS -7.0%; U0a2 PASS -12.3% (exec enabled); U0b KILL +1.8% (fusion dead on M4 mul-floor)
- [ ] Task U1: Air::eval_row_restriction hook + 3 table impls (dormant)
- [ ] Task U2: Qbar z=0 elimination, unfused (air_qbar.rs; gated by U0a/U0c)
- [x] Task U3: fold-fusion — KILLED by U0b (+1.8%, gate <= 0.97x); p18 closed for AIR sessions on this hardware; h-ep = Qbar-only, revised predicted -1.4%
- [ ] Task U4: DT24 eq-blocking (optional, >=1% rung gate)
- [ ] Task U5: enable-set finalization + e2e span check (569 -> <=535ms acceptance), then Phase-3 gates

## Task U0 — kill-ladder (one commit, test-only)

Per report/hypothesis_5/ §T0: benches as #[ignore] tests (Instant+black_box, no criterion),
in crates/lean_vm/src/tables/poseidon/mod.rs (sibling mod of h1_kill_ladder) and
crates/sub_protocols/tests/qbar_reference.rs (U0c, NOT ignored).
- U0a gate: candidate (full nodes {2,3,4,5} + skips {6..10} + state anchors z=2/3 + 2x
  (d+1)-dot Qbar consume + 11 stores + acc0) <= 0.97x baseline (production split z-loop,
  nodes {0,2,3,4}+{5..10}) on EFPacking cols, else KILL Qbar half for poseidon.
- U0a2 gate: execution-shaped kernel (26 cols, d=5) candidate <= 0.97x => exec enabled.
- U0b gate: fused fold+eval (4-index map: base=(j_hi<<(b'+2))|j_lo; m0..m3; folded writes
  + eval) <= 0.97x (separate production fold pass + eval pass), else KILL fusion half.
- U0c: scalar-EF brute-force reference vs production AirSumcheckSession, 3+ rounds,
  n=14 poseidon trace with real padding (non_padded=9000): row-restriction identity
  (C(y) == Bus(y) on every padded-trace row), footnote-12 interpolation table reproduction,
  p_evals[0] equality per round. Any mismatch kills (a) outright.
- Invariants: zero production change; gates printed PASS/GRAY/KILL with thresholds.
- Rollback: revert commit.

## Tasks U1-U5

As specified in report/hypothesis_5/air-efround-pack-plan.md (T1-T5 there): U1 dormant trait
hook with unit tests vs full eval on padding_row + filled traces for all 3 tables; U2 new
module air_qbar.rs {qbar_round0_kernel, qbar_unfused_kernel, fold_e_rows_to_qbar,
lagrange_node_weights} + AirProverTuning{qbar,fuse_folds} routed from compute_bare_round_poly
(phase-1 packed rounds only; phases 2/3 legacy), A/B DensePolynomial-equality tests per
round + final_column_evals equality; U3 qbar_fused_kernel with deferred pending_fold
(never across unpack boundary / last round; mandatory fold-only tail over [active,iter));
U4 optional eq_lo hoist; U5 defaults + tracing span + proof-bytes-identical A/B prove,
then correctness --expect-protected-changes + eval_paired --baseline c8ea299c.

## PAUSED (user request, 2026-06-12 20:43 UTC) — resume point
U0 review-gate: ACCEPT (reviewer reproduced U0C PASS, U0A -7.0% PASS, U0A2 -12.8% PASS,
U0B +2.3% KILL). Working tree clean at the U0 commit; NO U1 code written yet (two
attempted edits failed on stale-read and touched nothing). h-ep pool entry updated
(predicted -1.4, Qbar-only). RESUME WITH: Task U1 — add Air::eval_row_restriction
default-false hook after low_degree_air in crates/backend/air/src/lib.rs (anchor:
lines 28-32), impls for Poseidon16Precompile<BUS> (bus prelude replay, mod.rs:~322-360
shape), ExecutionTable<BUS> (air.rs:56-104 prelude), ExtensionOpPrecompile<BUS>
(air.rs:58-101 prelude), BUS=false => return true with zero accumulation; unit tests in
crates/sub_protocols/tests/qbar_reference.rs via scalar ConstraintFolder (pub, normal.rs:6,
fields flat/shift/accumulator) asserting hook == full-eval accumulator on (i) every row of
build_valid_trace, (ii) padding_row-replicated rows for all 3 tables (shift vals = same
row's first n_shift entries). Then commit "pw13-2 U1: ...", review gate, then U2
(air_qbar.rs unfused kernels per report/hypothesis_5/). Deadman switch NOT re-armed
(paused); re-arm on resume.
