# Twist & Shout (d=2) vs LOGUP* for Memory Binding: Security & Recursion Assessment

Audited 2026-05-29. Branch `pw8`, commit `782b890e` (perf) + `5851269d` (balance fix).

## 1. Summary

The current d=2 Twist & Shout memory binding (h61) has a soundness vulnerability shared with all virtual column optimizations on pw8. When analyzed alongside its recursion cost (+80ms), the protocol performs worse than a corrected LOGUP\*-style GKR quotient approach on both axes: it is unsound AND slower in recursion.

A GKR quotient binding run at the AIR sumcheck evaluation point r_air fixes the soundness issue and is estimated to be ~50ms faster in recursion than the current Twist & Shout implementation.

---

## 2. The Vulnerability

### Root cause

The AIR sumcheck's final verification step checks one scalar equation:

```
Sigma_k alpha^k * C_k(committed_evals, virtual_evals) * eq(beta, r_air) = v_final
```

Any column excluded from the stacked PCS whose evaluation at r_air is not independently verified by the verifier becomes a free variable in this equation. With >= 1 free variable, the prover can always solve the equation, defeating the sumcheck's oracle check.

The standard sumcheck soundness proof requires the oracle check to be binding (all evaluations verified). Virtual columns make it non-binding.

### Impact on Twist & Shout

Twist & Shout virtualizes 47 value columns (32 Poseidon + 15 Extension). The Shout product sumcheck pins the value POLYNOMIALS (val[i] = memory[addr[i]+k] at every row on {0,1}^n), but does NOT verify evaluations at the AIR sumcheck point r_air. The prover can:

1. Send arbitrary round polynomials in the AIR sumcheck (satisfying `p_i(0)+p_i(1) = target` trivially)
2. At the endpoint r_air, solve for 47 fake value evaluations satisfying the batched constraint equation
3. The Shout protocol passes independently (it verifies committed memory, not prover-supplied evaluations)

PoC at `../AttackPoCs/src/lib.rs` demonstrates the constraint function's surjectivity over the free variables (102/102 distinct outputs for random settings).

### The eq_s_hi gap

A proposed fix — "run Shout at r_air, check `Sigma gamma^{gk} * val_{g,k}(r_air) == weighted_batched_val`" — does not work because the d=2 product sumcheck's `weighted_batched_val` includes an `eq_s_hi[hi_g[i]]` weighting factor (memory_binding.rs:84):

```
weighted_batched_val = <Q_lo, M_slice>
  = Sigma_{g,k} gamma^{gk} * Sigma_i eq_r[i] * eq_s_hi[hi_g[i]] * memory[addr_g[i]+k]
```

The verifier can compute `Sigma gamma^{gk} * val_{g,k}(r_air)` from the prover-supplied evaluations, but this is the UNWEIGHTED sum:

```
Sigma_{g,k} gamma^{gk} * Sigma_i eq_r[i] * val_{g,k}[i]
```

These differ by the `eq_s_hi` factor. The d=2 address decomposition — the mechanism that makes the product sumcheck efficient — prevents a direct bridge from the product sumcheck output to the val column evaluations at r_air.

---

## 3. Recursion Cost Analysis

### Current Twist & Shout (h61): +80ms recursion

From the security claim measurements:

| Component | Time |
|---|---|
| P_hi absorption (7 groups x 2^11 EF elements) | ~72ms |
| Product sumcheck verification (v=11, degree 2) | ~6ms |
| Endpoint checks + WHIR claim construction | ~2ms |
| **Total recursion overhead** | **~80ms** |

The dominant cost is P_hi absorption: 7 groups x 1,280 Poseidon permutations = 8,960 permutations at ~9us each = ~80ms. This absorption is cryptographically necessary for Fiat-Shamir non-adaptivity (P_hi must be committed before s_hi is sampled). It cannot be removed or reduced without protocol changes.

### LOGUP\* bytecode binding (h56): +30ms recursion

For comparison, the bytecode binding GKR adds ~30ms to recursion for 2 GKR quotient verifications (left: v=20, right: v=18).

---

## 4. Viable Fix: GKR Quotient at r_air

### Mechanism

Replace the d=2 product sumcheck with a GKR quotient binding, run AFTER the AIR sumcheck at the evaluation point r_air.

Protocol flow:
1. Stacked PCS commit
2. LOGUP-GKR -> initial_sum
3. AIR sumcheck -> r_air, prover sends column evaluations
4. **Memory binding GKR at r_air:**
   - Left quotient: `Sigma_i eq_{r_air}[i] / (c_mem - addr_g[i]) = left_q`
   - Right quotient: `Sigma_j -P_air[j] / (c_mem - j) = right_q`
   - Balance: `left_q + right_q = 0`
   - Pushforward: `P_air[j] = Sigma_{i: addr_g[i]=j} eq_{r_air}[i]`
5. **Verifier derives val evaluations:** `val_{g,k}(r_air) = Sigma_j P_air[j] * memory[j+k]`
6. Verifier checks derived values against prover-supplied evaluations (or substitutes them directly)
7. WHIR verification

### Why this is sound

The GKR quotient proves pushforward well-formedness at r_air (same mechanism as h56 for bytecode). The pushforward P_air is anchored to the committed addr column (WHIR-verified at r_air) and committed memory. The verifier derives val evaluations from P_air and committed memory — no prover-supplied values. Zero free variables at the oracle check for value columns.

### Recursion cost estimate

| Component | Twist & Shout (current) | GKR quotient at r_air |
|---|---|---|
| P_hi absorption (8,960 Poseidon perms) | ~80ms | **0ms** (eliminated) |
| Product sumcheck (v=11, d=2) | ~6ms | **0ms** (eliminated) |
| GKR quotient verification (2 quotients, v~20+18) | 0ms | ~30ms (similar to h56) |
| Verifier val derivation (dot product) | 0ms | ~1ms |
| **Total recursion overhead** | **~80ms** | **~30ms** |
| **Net change** | — | **-50ms** |

The P_hi absorption — the dominant recursion cost of Twist & Shout — is eliminated entirely. The GKR quotient doesn't require absorbing per-group pushforwards into the FS transcript; it verifies the pushforward algebraically via the quotient balance.

---

## 5. Comparison: Twist & Shout vs GKR Quotient

| Property | Twist & Shout (d=2) | GKR quotient at r_air |
|---|---|---|
| Soundness | **Unsound** (val evals free at oracle check) | **Sound** (val evals derived by verifier) |
| Recursion overhead | +80ms | ~+30ms |
| Proof size contribution | +0.9KB (P_hi + product sumcheck) | ~+13KB (GKR coefficients + sumcheck rounds) |
| Proving overhead | 28ms | ~57ms (extrapolated from h56) |
| nv impact | Same (value cols virtual in both) | Same |
| Protocol complexity | Product sumcheck + P_hi absorption | GKR quotient (same as h56, different data) |

### Key tradeoff

The GKR quotient is sound and 50ms faster in recursion, at the cost of +12KB proof size and ~30ms more proving time. For a system where recursion is the bottleneck (recursion time ~3s >> prove time ~1.6s), the recursion savings dominate.

### Proving time breakdown

The h56 bytecode binding GKR takes 57ms for the prover (2 GKR proofs over 2^20 + 2^18 entries). A memory binding GKR would operate over similar sizes (execution: 2^20, poseidon: 2^18, extension: 2^15), with 7 groups instead of 1. Estimated: ~60-80ms proving. This is more than Twist & Shout's 28ms, but the recursion savings (-50ms) more than compensate in the full pipeline.

---

## 6. Impact on nv

Neither Twist & Shout nor the GKR quotient fix affects nv for value columns — both keep values virtual (not in the stacked PCS). The nv question is governed by the INTERMEDIATE column handling (V-1/V-2):

| Intermediate handling | N_COMMITTED (Pos) | Stacked offset | nv |
|---|---|---|---|
| All committed (baseline) | 109 | 59.9M | 26 |
| Intermediates + flags committed (fix V-1/V-2) | 77 | 38.5M | 26 |
| GKR for Poseidon circuit (Direction 1A) | 5-9 | 19.6-21M | **25** |

nv=25 requires a GKR-based approach for intermediates (Direction 1A) — committing them pushes stacked offset above 2^25 regardless of struct reorder.

---

## 7. Conclusion

Twist & Shout (d=2) was theorized to be the recursion-friendly alternative to LOGUP\*. The audit shows:

1. **It is unsound** — the d=2 product sumcheck pins value polynomials but doesn't verify evaluations at the AIR sumcheck point. The eq_s_hi weighting in the address decomposition prevents bridging from `weighted_batched_val` to `val(r_air)`.

2. **It is slower in recursion than the alternative** — the P_hi absorption (8,960 Poseidon permutations, ~80ms) dominates. A GKR quotient achieves ~30ms recursion overhead by eliminating P_hi entirely.

3. **The proof size increase is the only advantage** — Twist & Shout adds 0.9KB vs ~13KB for the GKR. This is marginal relative to the 150KB total proof size.

The GKR quotient approach (LOGUP\* for memory, run at r_air) is both sound and recursion-efficient. The original LOGUP\* was deprecated because it added +30ms to recursion when run at the GKR point. Running it at r_air adds the same ~30ms but replaces Twist & Shout's ~80ms, yielding a net -50ms improvement.

---

## References

- PoC: `../AttackPoCs/src/lib.rs` (demonstrates surjectivity of constraint function over free variables)
- Security claim: `../security_claim.md` (measurements and protocol description)
- Memory binding implementation: `leanMultisig/crates/sub_protocols/src/memory_binding.rs`
- AIR sumcheck verifier: `leanMultisig/crates/lean_prover/src/verify_execution.rs:225-253`
- Recursion circuit: `leanMultisig/crates/rec_aggregation/zkdsl_implem/recursion.py:320-363`
- Compilation constants: `leanMultisig/crates/rec_aggregation/src/compilation.rs:444-479`
