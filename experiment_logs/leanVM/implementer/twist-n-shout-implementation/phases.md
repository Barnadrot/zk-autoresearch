# Soundness Fix: Virtual Column Vulnerability (V-1 through V-4)

## Role

You are an autonomous cryptography researcher and expert ZK Rust developer working on the leanMultisig proving stack. You reason from primary sources: ePrints, the code itself, and formal protocol specifications — not from general knowledge summaries.

You understand the full leanMultisig verification pipeline: stacked PCS commitment (WHIR), LOGUP-GKR bus fingerprint balance, memory binding (Shout d=2 product sumcheck), bytecode binding (LOGUP* pushforward + GKR quotient), back-loaded AIR sumcheck, and the recursion circuit (Python zkDSL in `crates/rec_aggregation/zkdsl_implem/`, compiled to bytecode via `compilation.rs` which reads table traits dynamically). You know that the stacked PCS commits columns 0..n_committed per table, that the AIR sumcheck's oracle check requires all column evaluations at the evaluation point to be either WHIR-verified or verifier-derived, and that any unverified evaluation is a free variable that defeats sumcheck soundness. You operate on branch `pw8` of the leanMultisig repo, over KoalaBear (p = 2^31 - 2^24 + 1, alpha=3, t=16) with quintic extension, targeting 124-bit security (Johnson bound).

You understand the distinction between computation chain columns (Poseidon intermediates — round function composition does not commute with multilinear evaluation, so no lookup binding can substitute for commitment) and lookup columns (memory values, bytecode instructions — bindable via pushforward + GKR well-formedness proofs as described in "Twist and Shout via logup*", Wiese 2025). You understand that Poseidon1 and Poseidon2 are structurally distinct with non-transferable cryptanalysis, and that a GKR for the Poseidon1 circuit must faithfully represent the layered structure: full rounds (S-box x^3 on all 16 elements + MDS) and partial rounds (S-box on element 0 only + sparse MDS).

## The Vulnerability

A security audit found a critical soundness vulnerability in the h44+h55 optimizations on branch `pw8`. The same class of vulnerability affects h56 and h61.

**Root cause:** The AIR sumcheck's final oracle check evaluates one alpha-batched scalar equation. Any column excluded from the stacked PCS whose evaluation at the sumcheck point r_air is not independently verified becomes a free variable. With >= 1 free variable, the prover can always solve the equation — defeating the sumcheck soundness proof's base case.

**Affected optimizations:**

| ID | Optimization | Virtual columns | Free vars at oracle check | Severity |
|---|---|---|---|---|
| V-1 | h44: virtual Poseidon intermediates | 68 computation chain cols | 68 | CRITICAL |
| V-2 | h55: virtual Poseidon control flags | 4 flag cols | 4 | CRITICAL |
| V-3 | h56: bytecode-bound Execution instruction cols | 12 instruction cols | 12 | HIGH |
| V-4 | h61: memory-bound Poseidon+Extension value cols | 47 value cols | 47 | HIGH |

**PoC:** `zk-autoresearch/experiment_logs/leanMultisig/autoresearcher/pw8-mac/report/AttackPoCs/src/lib.rs` demonstrates the constraint function's surjectivity over free variables (102/102 distinct outputs for random settings).

## Implementation Plan

Execute phases sequentially. Commit after each phase passes verification. Do NOT `git push`.

---

### Phase 1: Commit Intermediates + Flags (Fixes V-1, V-2)

**Goal:** Reorder the Poseidon struct so flags and intermediates precede values, then raise N_COMMITTED to 77. This makes computation chain columns WHIR-verified.

**Current struct layout** (`crates/lean_vm/src/tables/poseidon/mod.rs`, struct at line 374):

```
cols 0-4:    multiplicity, nu_b, nu_c, addr_left_lo, addr_left_hi  [committed]
cols 5-20:   inputs[16]                                              [was committed, should be virtual]
cols 21-36:  out_lo[8], out_hi[8]                                    [was committed, should be virtual]
cols 37-40:  flag_short, flag_left, offset_left, flag_permute        [virtual, MUST commit]
cols 41-108: beginning_full_rounds, partial_rounds, ending_full_rounds [virtual, MUST commit]
```

**Target struct layout:**

```
cols 0-4:    multiplicity, nu_b, nu_c, addr_left_lo, addr_left_hi  [committed]
cols 5-8:    flag_short, flag_left, offset_left, flag_permute        [committed — MOVED UP]
cols 9-76:   beginning_full_rounds, partial_rounds, ending_full_rounds [committed — MOVED UP]
cols 77-108: inputs[16], out_lo[8], out_hi[8]                        [virtual, Shout-bound]
N_COMMITTED = 77
```

**Changes required:**

1. **Struct field reorder** in `Poseidon1Cols16<T>` — move flags and intermediates before inputs/outputs. The struct is `#[repr(C)]` so field order = column order.

2. **Update column index constants** (same file, lines 99-113):
   - `POSEIDON_COL_FLAG_SHORT = 5` (was 37)
   - `POSEIDON_COL_FLAG_LEFT = 6` (was 38)
   - `POSEIDON_COL_OFFSET_LEFT = 7` (was 39)
   - `POSEIDON_COL_FLAG_PERMUTE = 8` (was 40)
   - `POSEIDON_COL_INPUT_START = 77` (was 5)
   - `POSEIDON_COL_OUT_LO = 77 + WIDTH` = 93 (was 21)
   - `POSEIDON_COL_OUT_HI = 77 + WIDTH + WIDTH/2` = 101 (was 29)
   - `N_COMMITTED_COLS_POSEIDON_16 = 77` (was 5)

3. **Verify downstream code is name-based, not index-based:**
   - `memory_bound_columns()` (line 302) — uses named constants, should auto-update
   - `bus_interactions()` (line 148) — uses named constants
   - `eval_poseidon1_16` (line 397+) — accesses struct fields by name (cols.inputs, cols.flag_permute)
   - Trace generator (`crates/lean_vm/src/tables/poseidon/trace_gen.rs`) — assigns struct fields by name
   - `padding_row()` (line 182) — check if uses raw indices or named constants; update if raw

4. **nu_a and domainsep** — defined as `num_cols_poseidon_16()` and `+1`. `num_cols_poseidon_16()` uses `size_of::<Poseidon1Cols16<u8>>()`. Same struct size (same fields, just reordered). No change needed.

5. **Compilation** — `compilation.rs` reads `n_committed_columns()` dynamically. No manual changes. Recursion bytecode auto-rebuilds.

**Verification:**

- `cargo build` — clean compile
- `cargo test` — all pass, especially `committed_columns_cover_bus_referenced_columns`, `shift_columns_are_committed`, `ensure_no_overflow_in_logup`, `ensure_not_too_big_commitment_surface`
- The PoC test `h44_count_degrees_of_freedom` should now show n_free = 0 for virtual-only columns (the 32 value columns are memory-bound, not "free" in the same sense — they remain a V-4 concern but don't break Poseidon computation soundness)

**Impact:** nv = 26. Stacked offset ~38.5M. Values remain virtual (V-3/V-4 still open but Poseidon computation chain is now WHIR-verified — the prover cannot fake intermediates or flags).

---

### Phase 2: Shout via logup* (Fixes V-3, V-4)

**Goal:** Replace the current bytecode binding (h56) and memory Shout binding (h61) with the construction from "Twist and Shout via logup*" (Wiese, Powdr Labs, Oct 2025). Paper: https://powdr.org/papers/twist_shout_logup_star.pdf

This eliminates all remaining free variables at the AIR oracle check by having the verifier DERIVE value/instruction evaluations from the pushforward, rather than trusting prover-supplied evaluations.

**Why the current implementation is unsound:** The d=2 product sumcheck proves `<Q_lo, M_slice> = weighted_batched_val`, which includes an `eq_s_hi` weighting factor. This quantity is algebraically incompatible with the unweighted `val(r_air)` that the AIR sumcheck needs. The eq_s_hi factor cannot be removed (it's what makes the d=2 factorization work) and cannot be bridged (the weighted and unweighted sums are different polynomials of the per-bucket values).

**The paper's key insight (Section 4, eq. 5):** For a matrix M with one-hot rows, its multilinear extension equals the pushforward evaluated at the column point: `M_tilde(r_row, r_col) = P_tilde(r_col) = <P, eq_{r_col}>`. The pushforward P has size sqrt(K) for d=2 decomposition. The GKR proves P's well-formedness. The verifier derives val evaluations via a dot product — no prover-supplied virtual evaluations needed.

**Protocol flow (post-implementation):**

```
1.  Stacked PCS commit (committed cols including intermediates, flags, split addresses)
2.  LOGUP-GKR -> initial_sum
3.  AIR sumcheck -> r_air, prover sends column evaluations
4.  -- Shout via logup* at r_air --
    a. Prover computes pushforward P = addr_dense * eq_{r_air}  (size sqrt(K))
    b. Prover sends P in clear
    c. GKR proves P well-formedness (paper Section 4, using existing prove_gkr_quotient_ext)
    d. Verifier derives: val_k(r_air) = <P, memory_col_k>
    e. Verifier substitutes derived evals into AIR constraint check
5.  WHIR verification
```

**Key implementation steps:**

1. **Protocol reorder:** Move binding protocols AFTER the AIR sumcheck. The pushforward P = addr_dense * eq_{r_air} depends on r_air, which is only known after the AIR sumcheck completes. This means the Fiat-Shamir transcript ordering changes: the binding data (pushforward, GKR rounds) comes after the AIR sumcheck round polynomials and column evaluations. Update both the native verifier (`crates/lean_prover/src/prove_execution.rs` and `verify_execution.rs`) and the recursion circuit (`recursion.py`).

2. **Address decomposition:** For each lookup group, split the address column into lo/hi. For bytecode (size 2^18): PC_lo (9 bits), PC_hi (9 bits). For memory (size 2^22): addr_lo (11 bits), addr_hi (11 bits). Add committed columns for the decomposed addresses. Add AIR constraints: `addr = addr_hi * sqrt(K) + addr_lo`.

3. **Pushforward computation (prover):** For each lookup group at r_air: `P[j] = Sigma_{i: addr_dense[i]=j} eq_{r_air}[i]`. Size sqrt(K) per group. Batch across groups per paper Section 4.1 (one concatenated P, one GKR).

4. **GKR for pushforward well-formedness:** Reuse existing `prove_gkr_quotient_ext` / `verify_gkr_quotient` infrastructure in `crates/sub_protocols/src/quotient_gkr/mod.rs`. The GKR proves P is the correct pushforward of eq_{r_air} along addr_dense.

5. **Verifier value derivation:** `val_k(r_air) = <P, memory_col_k>` — a dot product of the verified pushforward against the committed memory polynomial (or public bytecode columns). The verifier computes this and substitutes into the AIR constraint check, replacing the prover-supplied evaluations for virtual value columns.

6. **Remove current binding protocols:** Delete the d=2 product sumcheck code in `crates/sub_protocols/src/memory_binding.rs`, P_hi computation/absorption in `prove_execution.rs`, the current bytecode binding GKR section, and the corresponding recursion circuit code in `recursion.py` lines 311-363.

7. **Recursion circuit update:** The pushforward P (sent in clear) replaces the P_hi absorption. For bytecode: 512 EF elements = 2,560 base field elements (~320 Poseidon perms, ~3ms). For memory: 2,048 EF elements = 10,240 base field elements (~1,280 Poseidon perms, ~12ms). Total ~15ms vs current 80ms P_hi absorption. Add GKR verification (~30ms). Net recursion: ~-35ms.

**Per-table changes:**

| Table | Current | New | Pushforward size |
|---|---|---|---|
| Execution | Bytecode GKR at r_gkr | Paper's Shout at r_air | 2^9 = 512 EF elems |
| Poseidon | d=2 product sumcheck | Paper's Shout at r_air | 2^11 = 2048 EF elems |
| Extension | d=2 product sumcheck | Paper's Shout at r_air | 2^11 = 2048 EF elems |

**Verification:**

- All Phase 1 tests still pass
- Prover/verifier produce matching proofs (test_aggregation or equivalent)
- Recursion circuit produces valid recursive proofs
- The PoC test should show 0 free variables at the oracle check for ALL tables

---

### Phase 3: GKR for Poseidon Circuit (Optimization, Optional)

**Goal:** Remove committed intermediates from stacked PCS by proving Poseidon computation via GKR, potentially recovering nv=25.

**Mechanism:** The GKR protocol proves evaluation of layered arithmetic circuits. Poseidon IS a layered circuit: S-box (x^3) -> MDS (linear) -> add constants, repeated ~28 times. The GKR starts from the committed output evaluation (WHIR-verified) and reduces layer-by-layer to the committed input evaluation (WHIR-verified). Intermediate values are handled internally by the GKR — the verifier never needs their explicit evaluations.

**Poseidon1 circuit structure (KoalaBear, t=16):**
- 4 beginning full rounds: each round = 16 parallel S-boxes (x^3) + dense MDS (16x16 matrix) + round constant addition
- 20 partial rounds: each round = 1 S-box (element 0 only) + sparse MDS + round constant addition
- 4 ending full rounds: same as beginning

**GKR layer mapping:**
- Each S-box is degree 3 (x^3 = x * x * x, 2 multiplications)
- MDS is linear (degree 1, handled as wiring)
- Round constant addition is linear (wiring)
- Full round: 16 parallel S-boxes = 1 GKR layer (width 16, depth 2 for the squaring chain)
- Partial round: 1 S-box + 15 identity = 1 GKR layer
- Total: ~28 rounds * ~2 layers = ~56 GKR layers

**Impact:** n_committed_poseidon drops from 77 to 9 (5 addresses + 4 flags). Stacked offset: 9 * 2^18 + other tables ~ 12M. With Phase 2's address splitting (8 address cols instead of 4): ~13M. Either way, nv=25 (under 2^25 = 33.5M).

**Key considerations:**
- The GKR operates on 2^18 Poseidon instances (one per trace row). The initial sumcheck layer has 2^18 + 4 = 22 variables.
- Recursion cost: ~56 GKR layer verifications, each with a sumcheck of ~22 rounds. This is substantial (~100-150ms estimated).
- The tradeoff: ~100ms GKR recursion vs ~saved stacking cost from nv=26->25.
- Poseidon1's S-box is x^3 (alpha=3 for KoalaBear). The GKR must use this specific exponent.

**Verification:**

- GKR output matches committed input/output evaluations
- Full prover/verifier roundtrip
- Recursion circuit handles the GKR layer verifications
- Benchmark: total prove + recursion time vs Phase 1+2 baseline

---

## Key File Map

| What | Where |
|---|---|
| Poseidon table AIR + struct | `crates/lean_vm/src/tables/poseidon/mod.rs` |
| Poseidon trace generator | `crates/lean_vm/src/tables/poseidon/trace_gen.rs` |
| Execution table AIR | `crates/lean_vm/src/tables/execution/air.rs` |
| Extension table AIR | `crates/lean_vm/src/tables/extension_op/air.rs` |
| Table structural tests | `crates/lean_vm/src/tables/table_enum.rs` |
| Stacked PCS | `crates/sub_protocols/src/stacked_pcs.rs` |
| Memory binding (Shout) | `crates/sub_protocols/src/memory_binding.rs` |
| Bytecode binding | `crates/sub_protocols/src/bytecode_binding.rs` |
| GKR quotient | `crates/sub_protocols/src/quotient_gkr/mod.rs` |
| LOGUP | `crates/sub_protocols/src/logup.rs` |
| AIR sumcheck | `crates/sub_protocols/src/air_sumcheck.rs` |
| Prover | `crates/lean_prover/src/prove_execution.rs` |
| Verifier | `crates/lean_prover/src/verify_execution.rs` |
| Recursion circuit | `crates/rec_aggregation/zkdsl_implem/recursion.py` |
| Compilation (constants) | `crates/rec_aggregation/src/compilation.rs` |
| PoC tests | `zk-autoresearch/experiment_logs/leanMultisig/autoresearcher/pw8-mac/report/AttackPoCs/` |

## Constraints

- Target repo: `zk-autoresearch/leanMultisig`, branch `pw8`
- Do NOT `git push`. Coordinator pushes after review.
- Commit per phase on the experiment branch. Failed iterations get `git revert`, not `git reset`.
- Do not modify code outside the target repo. Tests go in `AttackPoCs/`.
- `compilation.rs` reads table traits dynamically — do NOT hardcode constants there.
