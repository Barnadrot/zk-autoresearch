# Proposals for pw12-mac program.md — UPDATED with corrected profiling

## Corrected profiling data (exclusive self-time)

The M4-M profiling agent initially reported 89.6% for eval_eq — this was INCLUSIVE 
call-tree counts from sample(1). The corrected data from xcrun xctrace Time Profiler:

### M4-M (deployment target, NEON)
| Component | Explicit self% | Adjusted (incl. rayon share) |
|---|---|---|
| AIR constraint eval (Poseidon rounds) | 37% | **~50%** |
| Sumcheck/GKR protocol | 10% | ~14% |
| Native Poseidon hash | 9% | ~13% |
| Execution/other constraint | 6% | ~12% |
| Rayon overhead | 28% | (redistributed above) |
| Eq polynomial | 4.5% | ~3% |

### Hetzner (AVX-512, reference)
| Component | Exclusive self% |
|---|---|
| Poseidon native hash (permute_mut) | 25.7% |
| AIR constraint eval | 14.2% |
| Sumcheck inner loop | 14.1% |
| Rayon overhead | 17.1% |
| GKR quotient | 6.6% |
| Eq polynomial | 1.9% |

**Key insight:** The #1 bottleneck on M4-M is AIR constraint evaluation (~50% adjusted), 
not the sumcheck protocol itself (~14%). The functions eval_2_full_rounds_16 (11%) and 
eval_last_2_full_rounds_16 (7.5%) evaluate Poseidon AIR constraints at every sumcheck 
round for every row. ZeroCheck reduces evaluation points per round, directly cutting 
these functions.

## 1. Role — target AIR constraint evaluation, not "sumcheck"

```
You are an autonomous researcher targeting the AIR constraint evaluation 
cost in the leanVM prover. On M4-M, Poseidon AIR constraint evaluation 
(eval_2_full_rounds_16 at 11%, eval_last_2_full_rounds_16 at 7.5%, 
Poseidon16Precompile::eval at 4.2%) consumes ~50% of proving time when 
rayon trampoline attribution is accounted for.

Your goal: reduce the number of constraint evaluation points per sumcheck 
round, restructure the AIR evaluation to minimize extension-field 
multiplications, or find protocol-level changes that reduce the total 
constraint evaluation work.
```

## 2. Hard file restrictions

```
Do NOT modify these files (security-critical cryptographic parameters):
- crates/backend/koala-bear/src/poseidon1_koalabear_16.rs
- crates/lean_prover/src/lib.rs (constants: SECURITY_BITS, GRINDING_BITS, 
  MAX_NUM_VARIABLES_TO_SEND_COEFFS, WHIR_*, RS_DOMAIN_*, SecurityAssumption)
- crates/lean_prover/python-verifier/verifier.py (WHIR_CONFIGS)
```

## 3. Papers in dispatch prompt

```
read experiment_logs/leanVM/autoresearcher/pw12-mac/program.md and these papers:
- https://eprint.iacr.org/2024/108   (ZeroCheck — Gruen: reduces eval points from d+1 to d-1 per round)
- https://eprint.iacr.org/2026/587   (Speeding up sumcheck — Dao, Thaler: univariate skip, fused rounds)
- https://eprint.iacr.org/2024/1046  (Small-field sumcheck — Bagad, Domb, Thaler)
- https://eprint.iacr.org/2025/1117  (Improved small-field — Bagad, Dao, Domb, Thaler: SVO)
then start the experiment!
```

Twist & Shout is less relevant for this experiment — it targets the LogUp binding 
protocol, not the AIR constraint evaluation. The ZeroCheck and univariate skip papers 
are the direct targets.

## 4. Profiling data — give CORRECTED numbers upfront

```
## Known bottleneck (from profiling, exclusive self-time)

### M4-M (deployment target) — xcrun xctrace Time Profiler
| Function | Self% | Component |
|---|---|---|
| eval_2_full_rounds_16 | 11.0% | Poseidon AIR constraint eval |
| eval_last_2_full_rounds_16 | 7.5% | Poseidon AIR constraint eval |
| ExecutionTable::eval | 6.2% | Execution constraint eval |
| permute_mut | 4.7% | Native Poseidon hash |
| eval_eq_with_packed_output_dual | 4.5% | Sumcheck eq-MLE |
| Poseidon16Precompile::eval | 4.2% | Poseidon AIR dispatch |
| compress_mut | 2.4% | Native Poseidon hash / Merkle |

Adjusted for rayon trampoline redistribution:
- AIR constraint eval: ~50%
- Sumcheck/GKR: ~14%
- Native Poseidon hash: ~13%

The Poseidon AIR constraint evaluation runs at EVERY sumcheck round for 
EVERY row. Reducing evaluation points per round (ZeroCheck) or reducing 
the per-evaluation cost (algebraic simplification) directly targets this.
```

## 5. Writable files — scoped to AIR eval + sumcheck surface

```
## Writable files (changes outside this list require human approval)

- crates/backend/sumcheck/src/*.rs (sumcheck protocol)
- crates/backend/poly/src/*.rs (polynomial operations)
- crates/backend/air/src/*.rs (AIR builder, constraint folder)
- crates/sub_protocols/src/air_sumcheck.rs (AIR sumcheck session)
- crates/sub_protocols/src/quotient_gkr/*.rs (GKR sumcheck)
- crates/sub_protocols/src/logup.rs (LogUp protocol)
- crates/lean_vm/src/tables/poseidon/mod.rs (Poseidon AIR constraints ONLY — not round counts)
- crates/lean_vm/src/tables/execution/air.rs (constraint evaluation)
- crates/lean_vm/src/tables/extension_op/air.rs (constraint evaluation)
```

## 6. Anti-patterns from prior experiments

```
## What NOT to do

- Do not reduce Poseidon round counts (R_F, R_P). Security-critical, out of scope.
- Do not change WHIR parameters or soundness assumptions. Out of scope.
- Do not attempt packed sumcheck on the product sumcheck — pol_b is extension-field,
  ext×ext quadratic unavoidable (validated pw10 iters 10-11).
- Do not add columns to reduce degree without computing the stacked PCS impact first.
  pw11 iter 6 added 16 columns for degree 10→9: the +3.6% Merkle cost exceeded 
  the -1.5% sumcheck savings. Always compute: Δ_columns × rows × cost_per_cell.
```

## 7. What ZeroCheck actually gives on this codebase

Current AIR sumcheck evaluates constraints at d+1 points per round:
- Poseidon: degree 10, evaluates at 11 points per round
- Execution: degree 5, evaluates at 6 points per round

ZeroCheck (Gruen ePrint 2024/108) exploits the fact that AIR constraints vanish 
on the Boolean hypercube, allowing degree-(d-2) round polynomials:
- Poseidon: 11 evals → 9 evals = -18% per-round cost
- Execution: 6 evals → 4 evals = -33% per-round cost

At AIR constraint eval = ~50% of M4-M total:
- 20% reduction in constraint eval → ~10% total proving speedup
- 10% would bring M4-M from 693 XMSS/s to ~770 XMSS/s

The univariate skip technique (Dao-Thaler ePrint 2026/587) can further fuse 
k variables into one higher-degree evaluation, processing the first k sumcheck 
rounds in the base field. Combined with ZeroCheck, this could push to 15-20% 
total improvement.

## 8. Goldilocks experiment is separate

The goldilocks_ax42u experiment runs on Hetzner against the goldilocks branch.
Different field (p=2^64-2^32+1), different bottleneck profile, different target.
pw12-mac focuses exclusively on KoalaBear on M4-M.
