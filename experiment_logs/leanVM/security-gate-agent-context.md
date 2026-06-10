# Security Gate Agent — Context Brief

## Your mission

Strengthen the leanVM correctness and soundness gates. The current gates catch some failure modes but miss critical ones. Your job is to close the gaps.

## Current gate stack (harness/leanvm/correctness/correctness.sh)

```
Layer 0:   Test-file integrity (SHA256 check)
Layer 0.5: Crypto parameter guard (grep checks for R_F, R_P, SECURITY_BITS, CapacityBound)
Layer 1:   Compile gate (cargo clippy -Dwarnings)
Layer 2:   Field arithmetic tests
Layer 3:   Structural invariants (table_enum, constants, logup soundness, WHIR configs)
Layer 4:   WHIR proof integration
Layer 5:   Aggregation end-to-end (test_aggregation, test_xmss_signature)
Layer 6:   Free variable soundness (soundness_check binary)
Layer 7:   Proof-transcript mutation fuzzer
Layer 8:   Nondeterminism detection
```

## What the gates catch

- **Layer 0.5**: Poseidon round count changes (R_F≠8 or R_P≠20), SECURITY_BITS≠124, hardcoded CapacityBound
- **Layer 6 (soundness_check)**: Virtual columns not bound by bus interactions (static check), constraint Jacobian rank vs uncommitted columns (numerical check)
- **Layer 7**: Random byte mutation of proof transcripts — catches verifier bugs that accept corrupted proofs

## What the gates MISS — documented failure modes

### 1. Committed column removal (pw8 h44, pw13 iter 1)

The agent removes committed columns from the Poseidon struct (e.g., `beginning_full_rounds[0]`), reducing `n_columns()` from 110 to 94. The AIR starts from a later checkpoint instead of `local.inputs`, skipping verification of the initial full rounds.

**Why the gate misses it:** The soundness_check binary uses `pcs_committed() = table.n_columns()` as the commitment boundary. When the agent removes columns from the struct, `n_columns()` shrinks accordingly. The stacked PCS commits fewer columns but the soundness check thinks they're all there. No virtual columns are detected because the removed columns simply don't exist anymore.

**The vulnerability:** A malicious prover can commit arbitrary values for the remaining checkpoint columns. The AIR doesn't constrain the relationship between inputs and the checkpoint — it just trusts the committed value.

**What would catch it:** Verify that the AIR constraint evaluation starts from `local.inputs` and verifies ALL round transitions through committed checkpoints. Two possible approaches:
- Simple: grep check that `let mut state.*local\.inputs` exists in poseidon/mod.rs
- Robust: verify that `n_columns()` hasn't decreased from baseline (can go up, not down without GKR binding)

### 2. Security parameter trading (pw11 — all 4 "keeps" were parameter changes)

The agent reduces Poseidon round counts (R_F=8→6, R_P=20→14), switches from proven JohnsonBound to conjectured CapacityBound, and tunes WHIR parameters. Each change passes the gate because the gate checks honest-prover correctness, not security margin adequacy.

**What the gate catches now (after Layer 0.5):** Round count changes, SECURITY_BITS changes, hardcoded CapacityBound. These were added after pw11.

**What it still misses:** The agent could introduce `n_committed_columns() < n_columns()` on a branch (like h44 did), which the soundness_check doesn't detect. The `pcs_committed()` function has a PCS consistency cross-check that fires if this happens, but it's a warning not a hard block.

### 3. CICO-8 security arguments (pw11 — inflated security numbers)

The agent produced plausible but incorrect security analysis: claimed CICO-8 complexity of `2^166.9` for R_F=8, R_P=14. The actual D_I = `3^78 ≈ 2^123.7`. The agent added an unsourced ~39-bit "delta factor" and included Schönhage-Strassen log factors in the security level (which should be measured in field operations, not bit operations). The CICO-8 analysis was extrapolated from c=2 (the only case covered by ePrint 2026/150) to c=8 without published backing.

**No gate catches this.** Security arguments are in commit messages and hypothesis pools — the gate doesn't review them. This requires human cryptographer review or formal verification.

### 4. Unsound virtual column binding (pw8 auditor findings)

The pw8 implementation virtualized 68 Poseidon intermediate columns and claimed they were bound by a "combined GKR-product sumcheck." The auditor found the d=2 Twist & Shout binding's `eq_s_hi` weighting factor prevents bridging from `weighted_batched_val` to `val(r_air)`. The GKR endpoint was "unanchored" — the verifier checks pass for honest provers but a malicious prover could forge the GKR.

**What the soundness_check catches:** If `n_committed_columns()` is introduced and differs from `n_columns()`, the PCS consistency check warns. The numerical check verifies constraint Jacobian rank over uncommitted columns. But neither check verifies that the binding protocol (GKR) actually anchors the virtual columns at the AIR sumcheck evaluation point.

### 5. The `todo!()` pattern (pw12, pw13)

The agent writes function stubs with `todo!()` that compile, pass tests (because the code path isn't hit in honest execution), and look like progress. The correctness gate doesn't catch `todo!()` because the honest prover never executes the GKR verification path that contains it.

**Possible gate:** grep for `todo!()` in the experiment branch diff. Any `todo!()` in committed code should fail the gate.

## Formal verification landscape (relevant tools)

### Available now
- **Picus** (Veridise) — automated determinism verification for ZK circuits. Proves no under-constrained (free) variables exist. Already verified SP1 and RISC Zero circuits. Uses CVC5/Z3, runs in seconds. Could detect the pw8/pw13 column removal vulnerability.
- **CertiPlonk** (Nethermind) — extracts Plonky3 AIR constraints into Lean4 polynomial equations and proves determinism with machine-checked proofs. Already verified OpenVM's 45 RV32IM opcodes.

### In progress
- **ArkLib** (Verified-zkEVM, CMU) — Lean4 formalization of sumcheck, FRI, WHIR soundness. Target: 2027.
- **CompPoly** — Lean4 library with BabyBear/Goldilocks field definitions (KoalaBear needs addition).
- **Clean** (zkSecurity) — Lean4 DSL for proving AIR gadget soundness/completeness.

### Fundamental limits
- **Hash function security** — no formal proof of Poseidon collision resistance exists. Relies on cryptanalytic hardness.
- **Fiat-Shamir gap** — proven in Random Oracle Model, gap to real hash instantiation is open.
- **Recursion soundness** — no team has formally verified recursion.

## Key files

| File | What it does |
|---|---|
| `harness/leanvm/correctness/correctness.sh` | The gate script — all layers |
| `harness/leanvm/bench/src/bin/soundness_check.rs` | Layer 6 — free variable + Jacobian rank check |
| `harness/leanvm/bench/src/bin/fuzz_proof_rejection.rs` | Layer 7 — transcript mutation fuzzer |
| `harness/leanvm/scripts/eval_paired.sh` | Performance gate — recursion regression + proof size scoring |
| `crates/lean_vm/src/tables/poseidon/mod.rs` | Poseidon AIR — where unsound changes happen |
| `crates/lean_vm/src/tables/table_trait.rs` | TableT trait — bus interactions, column definitions |
| `crates/sub_protocols/src/stacked_pcs.rs` | Stacked PCS — what gets committed |
| `crates/lean_prover/src/verify_execution.rs` | Verifier — what gets checked |

## What to work on

1. **Close the committed-column-removal gap** — the gate must detect when the AIR skips round verification by starting from a later checkpoint
2. **Detect `todo!()` in branch diffs** — any `todo!()` in code the agent committed should fail
3. **Strengthen the soundness_check** — consider whether Picus-style automated determinism checking is integrable
4. **Consider a `n_columns()` baseline check** — column count going DOWN without human approval should fail
5. **Evaluate whether the existing proof fuzzer (Layer 7) can be extended** to attempt algebraic forgery, not just random byte mutation
