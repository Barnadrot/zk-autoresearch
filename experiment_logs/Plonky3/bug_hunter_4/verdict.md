# bug_hunter_4 verdict

**Branch (Plonky3):** fix/interpolate-duplicate-domain @ 3ce2e787 (no new commits this hunt)
**Branch (zk-autoresearch):** bug-hunter-4
**Date:** 2026-05-12
**Surface:** Plonky3 verifier-side correctness paths

## Total investigations: 7 (all `not_found`, analytical)

No new bugs found. All hypotheses I formed against the verifier-side surfaces ultimately turned out to be already defended against — either by a structural invariant the verifier enforces upstream, or by a width/shape check that catches the inconsistency before it could be exploited.

## Bugs found: 0

## Key invariants documented via `not_found`

The following analyses verify that the Plonky3 verifier-side code is sound on these surfaces (see findings.tsv for full reasoning):

- **bh4-1** (transcript): `from_u8(x)` and `from_usize(x)` produce the same canonical field element for `x ∈ [0, 256)` in all standard Plonky3 prime fields (BabyBear, KoalaBear, Goldilocks, Bn254). Verifier rejects `degree_bits ≥ 64` via `checked_pow2`, so the prover's `as u8` truncation in `uni-stark/src/prover.rs:161-162` cannot diverge from the verifier's `from_usize` in `uni-stark/src/verifier.rs:351-352`.

- **bh4-2** (transcript): FRI verifier binds `log_arities` into the challenger via `challenger.observe(Val::from_usize(log_arity))` (`fri/src/verifier.rs:228-230`) before query-index sampling. Any modification by a malicious prover desynchronizes the transcript, causing MMCS verification to fail in the fold loop before subtraction underflow could happen in `log_folded_height = log_current_height - log_arity`.

- **bh4-3** (logup-soundness): LogUp local-lookup constraint applies on all rows including last-row wrap-around. Combined with the `when_first_row` constraint `s[0] = 0`, this telescopes to enforce `c_0 + ... + c_{n-1} = 0` (total contribution = 0). The design is sound, not buggy.

- **bh4-4** (verifier-acceptance): FRI `open_input` checks `ro.is_zero()` for `log_blowup`-level reduced openings after each batch. Since each individual constant-polynomial contribution `(f(zeta) - f(x))/(zeta - x) = 0`, the accumulated value stays zero. Bound by MMCS authentication of `mat_opening`, so non-zero `ro` correctly signals an attack on `ps_at_z` for constant matrices.

- **bh4-5** (transcript): When `commit_proof_of_work_bits = 0`, both prover's `grind(0)` and verifier's `check_witness(0, w)` short-circuit without absorbing the witness. The witness field is effectively dead data when PoW is disabled — symmetric and not exploitable.

- **bh4-6** (multi-table): batch-stark verifier's filter for the permutation round uses `inst_opened_vals.permutation_local.is_empty()` (from proof) vs prover's `lookups.is_empty()` (from common.lookups). The width check at `batch-stark/src/verifier/mod.rs:528-537` catches inconsistencies (`PermutationWidthMismatch`), and PCS verify also rejects if alpha-power accumulation differs. Defense in depth makes this sound, though the width check could be moved earlier for performance.

- **bh4-7** (mmcs-opening): MMCS `verify_batch` enforces that matrices whose heights round to the same power-of-two must be equal-height. This precondition is consistent with the merkle tree's per-height-layer injection construction, not over-strict.

## Recommendations for next hunter

Surfaces I covered (mostly):
- uni-stark verifier (`verifier.rs`, `process_preprocessed_trace`, `verify_constraints`)
- batch-stark verifier (`verifier/mod.rs`, transcript ordering vs prover)
- FRI verifier (`verify_fri`, `verify_query`, `open_input`)
- MMCS `verify_batch` height-consistency checks
- LogUp constraint logic (`logup.rs`)

Surfaces I touched lightly — worth deeper investigation:
- **WHIR verifier** (`whir/src/pcs/verifier/mod.rs`): The `verify_merkle_proof` uses `for (&index, query) in indices.iter().zip(queries.iter())` — if `queries.len() < indices.len()`, the zip silently truncates. Downstream `SelectStatement::new` asserts `vars.len() == evaluations.len()`, so this currently panics rather than returning a clean error. Worth investigating whether the panic is reachable from a malformed proof and whether it should be replaced with a clean error.
- **WHIR sumcheck verifier** (`whir/src/sumcheck/layout/verifier.rs`, `whir/src/sumcheck/strategy.rs`): I did not deeply analyze the sumcheck round verification, including the final identity check `claimed_eval == evaluation_of_weights * final_value` (`whir/src/pcs/verifier/mod.rs:211-217`). The interaction between `VariableOrder::Prefix`/`Suffix` and folding randomness reversal looks like a likely place for subtle ordering bugs.
- **Recursion / AIR verifier**: There is no native recursion code in this checkout (no AIR implementing the verifier), so surface 6 in `program.md` is not applicable here. Skip until recursion lands.
- **Bus-based cross-AIR interactions** (`lookup/src/bus.rs`, `lookup/src/builder.rs`, `lookup/src/symbolic.rs`): Recently introduced (#1566). The `LookupBus::table_entry` uses `-num_lookups.into()` to encode a receive; check that signed multiplicities are handled correctly when negated values overflow into the field's full range. The `Lookups::from_interactions` orders local first then global with sequential `column` indexing — verify nothing else assumes a different order.

Style note: the prior hunts found one clear primary surface (NEON SIMD canonicalization, packed extension transmute, function-contract violations). The verifier surface seems hardened by structural invariants and defense-in-depth, so finding a bug here may require either (a) a much deeper sumcheck/STIR-style analysis, or (b) testing the WHIR/multilinear-util newer code which is less battle-tested.

## Stop criterion hit

I'm stopping under criterion 2 (consecutive `not_found` without `found`). The verifier-side surface looks well-guarded, so further hunts on the same surface have diminishing returns. Recommend switching focus to WHIR or the newer bus-based lookup infrastructure for the next hunt.
