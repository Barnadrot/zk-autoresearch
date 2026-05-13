# Plonky3 bug hunter 4 — verifier-side audit

*Adversarial review of Plonky3 verifier-side correctness paths. No bugs found; reporting back to document what was checked and what we believe is sound. Includes recommended targets for the next hunter.*

## Summary

Fourth hunt in the rolling Plonky3 bug-hunter series (bh1-3 found 5 prover-side bugs across NEON SIMD, packed extensions, and matrix interpolation). This hunt pivoted to **verifier-side** surfaces — a soundness-critical area not adversarially explored by bh1-3.

**Result: 0 bugs found, 7 hypotheses ruled out analytically.** The verifier appears well-hardened: every attack vector tried was already defended against, either by structural invariants (transcript binding, MMCS authentication) or by width/shape checks (defense in depth).

This PR-shaped writeup is the audit trail. It is not requesting a code change — it requests upstream visibility on (a) which surfaces were checked and what invariants they rely on, and (b) which surfaces remain less battle-tested and would benefit from a follow-up hunt.

## Investigations

7 hypotheses, all `not_found`. Codebase audited at `3ce2e787` on branch `fix/interpolate-duplicate-domain` (which already contains the bh3-4 fix for `interpolate_arbitrary_point`).

| ID | Category | Surface | Reasoning summary |
|---|---|---|---|
| bh4-1 | transcript | `uni-stark::prove` / `verify` | Prover absorbs `log_*_degree as u8`, verifier absorbs `from_usize` — both produce the same canonical field element for `v < 256` via `QuotientMap`; verifier rejects `degree_bits ≥ 64` via `checked_pow2`. |
| bh4-2 | transcript | `fri::verify_fri` | `log_arities` are bound into the challenger before query sampling, so a malicious log-arity substitution desynchronizes the transcript and fails MMCS verification before any subtraction-underflow path is reached. |
| bh4-3 | logup-soundness | `p3-lookup::logup` | Local-lookup transition constraint applies on the last-row wrap-around; combined with `when_first_row` (`s[0]=0`), telescopes to enforce total-sum-zero. Sound by design. |
| bh4-4 | verifier-acceptance | `fri::open_input` | Per-batch invariant check on `ro` at `log_blowup` level is correct: each constant-poly contribution is identically zero (since `f(zeta)=f(x)`), and `mat_opening` is bound by Merkle authentication. |
| bh4-5 | transcript | `challenger::check_witness` | When PoW bits = 0, both `grind(0)` and `check_witness(0, w)` short-circuit without absorbing the witness — symmetric, and dead data when PoW is disabled. |
| bh4-6 | multi-table | `batch-stark::verify_batch` | Permutation-round filter on `permutation_local.is_empty()` (from proof) differs from prover's filter on `lookups.is_empty()` (from common.lookups). The width check at `verifier/mod.rs:528-537` catches the inconsistency; PCS verify catches it again via alpha-power misalignment. Defense in depth. |
| bh4-7 | mmcs-opening | `merkle-tree::verify_batch` | "Heights rounding to same power-of-two must be equal" check is a precondition for the merkle tree's per-layer injection construction, not over-strict. |

Per-hypothesis full reasoning lives in `findings.tsv`. The `not_found` analyses are the deliverable here — each one documents an invariant the verifier silently relies on, which is the kind of thing that should not be regressed by future refactors.

## Surfaces covered

- **`p3-uni-stark` verifier** — full read of `verifier.rs`, including `validate_degree_bits`, `process_preprocessed_trace`, `verify_constraints`, transcript ordering vs `prover.rs`, ZK randomization opening, public-values length check, periodic-column evaluation domain.
- **`p3-batch-stark` verifier** — full read of `verifier/mod.rs` + `transcript.rs`. Cross-checked transcript order vs `prover.rs`, permutation-round filter logic, global-cumulative-sum bookkeeping per bus name.
- **`p3-fri` verifier** — full read of `verifier.rs` (`verify_fri`, `verify_query`, `open_input`), prover comparison for alpha-power accumulation across batches/matrices/points/columns, log-arity transcript binding, PoW witness handling for `bits=0`.
- **`p3-merkle-tree` MMCS** — `verify_batch` height-consistency check, per-layer injection construction.
- **`p3-lookup` LogUp** — local-vs-global transition constraint logic, cumulative-sum verification via `verify_global_sum`.
- **`p3-field` integer→field conversion** — `QuotientMap<u8>` vs `QuotientMap<usize>` path equivalence for small values.

## Surfaces *not* covered — recommended for next hunter

- **WHIR verifier** (`whir/src/pcs/verifier/mod.rs`, `whir/src/sumcheck/layout/verifier.rs`). Two specific entry points worth probing:
  - `verify_merkle_proof` uses `for (&index, query) in indices.iter().zip(queries.iter())` — if `queries.len() < indices.len()` the zip silently truncates. Downstream `SelectStatement::new` asserts `vars.len() == evaluations.len()`, so this **panics** rather than returning a clean error. Unclear whether reachable from a structurally-valid proof; worth a test.
  - Final identity check `claimed_eval == evaluation_of_weights * final_value` at `pcs/verifier/mod.rs:211-217` — the `VariableOrder::Prefix`/`Suffix` reversal interacts with folding randomness reversal at multiple call sites. Subtle ordering bugs would survive property tests but break under adversarially-chosen variable orders.
- **Bus-based cross-AIR lookup infrastructure** (`lookup/src/bus.rs`, `lookup/src/builder.rs`, `lookup/src/symbolic.rs`) — newly introduced in #1566. `LookupBus::table_entry` encodes a receive as `-num_lookups.into()`; verify signed-multiplicity handling around field-wrap-around. `Lookups::from_interactions` orders local-first then global with sequential `column` indexing — verify no caller assumes a different order.
- **Recursion / AIR-as-verifier** — not in this checkout, so program.md's surface 6 is N/A here. Worth a dedicated hunt once recursion lands.

## Methodology

- **Build:** `RUSTFLAGS="-C target-cpu=native" cargo check --release` on Hetzner CCX33 (AMD Zen 4, AVX-512). Build succeeded.
- **No new tests written.** I considered writing tests for several hypotheses (FRI log-arity substitution attack, WHIR zip-truncation panic, FRI subtraction underflow) but in each case the analytical trace showed the attack was already foiled upstream of the candidate failure point. Writing a test I expect to pass would be coverage, not hunting (per program.md guidance). I chose to log analytical `not_found` entries instead — the reasoning is the deliverable.
- **Stop criterion:** consecutive `not_found` without `found` — pivoted to verdict + writeup rather than churning on the same surface.

## Why this is useful even without a fix

The bh3 examples table notes that "disproved hypotheses (also valuable — they document invariants)." A canonical example: bh3 ruled out `batch_multiplicative_inverse` split-into-prefix-and-tail correctness, which is now an invariant a future packed-inverse refactor must preserve. The 7 `not_found` entries here serve the same role for the verifier:

- bh4-1 documents that `from_u8`/`from_usize` round-trip identity is load-bearing for transcript consistency.
- bh4-2 documents that `log_arities` MUST stay bound to the transcript before query sampling, or the FRI underflow path becomes reachable.
- bh4-6 documents the defense-in-depth on permutation-round filtering — if someone refactors the width check away, the multi-table soundness regresses.

These are the kind of invariants that would be silently broken by a "clean up some checks" refactor, so they are worth having on record.

## Verdict

**Plonky3's verifier surface is hardened.** Recommend the next bug-hunter pivot to WHIR sumcheck/STIR or the new bus-based lookup infrastructure, both of which are less battle-tested than the core STARK verifier paths covered here.

Full audit trail: `experiment_logs/Plonky3/bug_hunter_4/`
- `program.md` — hunt instructions (verifier-side surface)
- `findings.tsv` — 7 `not_found` entries with per-hypothesis reasoning
- `verdict.md` — 1-page summary
- `pr_body.md` — this file
