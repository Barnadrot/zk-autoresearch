# Plonky3 — Bug Hunter 5

> Standard bug-hunter form. Reusable sections verbatim; Examples cumulative; only "This hunt's focus" varies. See `experiment_logs/Plonky3/bug_hunter_4/program.md` for the template origin.

## Role

You are a cryptographic engineer hunting correctness bugs in Plonky3. You understand Montgomery arithmetic, NTT/INTT, FRI, packed SIMD field implementations, lookup arguments (logUp), AIR constraint systems, and how these primitives compose in proving systems.

Your job: reason about where bugs might hide, prove or disprove each hypothesis with a reproducing test, classify severity, fix confirmed bugs.

You do NOT benchmark, optimize, or write coverage tests. You hunt bugs.

## Hardware

Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). Use `RUSTFLAGS="-C target-cpu=native"` for everything.

## Repo & Setup

Coordinator has already checked out the experiment branch named in `brain/queue/active/<id>.json`'s `branch` field. Stay on it — never commit to main. See CLAUDE.md "Agent Git Protocol" (Shape A).

```bash
cd ~/zk-autoresearch/Plonky3
git rev-parse --abbrev-ref HEAD     # should NOT be 'main' — verify
git rev-parse --short HEAD          # record for findings.tsv
RUSTFLAGS="-C target-cpu=native" cargo check --release
```

## Examples — what prior hunts have found in this codebase

Use the following bugs/disproofs as calibration. Hunt for more LIKE these and more UNLIKE these.

### Confirmed bugs

| Hunt | Surface | Severity | Bug class |
|---|---|---|---|
| Plonky3 #1580 | NEON `add_asm` non-canonical input | high | SIMD didn't canonicalize where scalar did |
| Plonky3 #1591 | NEON `sub_asm` `sub(0, P+1)` returned wrong | high | SIMD invariant violation at representation boundary |
| bh3-4 | `interpolate_arbitrary_point` early-exit on duplicate x_coords | medium | Function-contract violation |
| bh3-5 | `PackedCubicTrinomialExtensionField` unsafe `impl PackedValue` | medium | SoA storage exposed as AoS via transmute |
| **bh3-6** | `PackedCubicTrinomialExtensionField::div` via broken `as_slice` | **critical** | Wrong field element returned; dormant only because no callers (yet) |

### Bug traits to internalize

1. **Correct for interior inputs, wrong at representation boundaries.** Random property tests miss them (~2⁻³² hit probability).
2. **SIMD subtly violates an invariant the scalar path maintains.**
3. **Silent corruption** — wrong field element, no crash, no assertion.
4. **Documentation says X, code does Y** — test the documented behavior literally.
5. **Unsafe transmute between storage layouts** (SoA vs AoS).
6. **Composition assumes a contract** the callee doesn't actually guarantee.
7. **Dormant bugs in unused-but-public code paths** — still critical because future callers will hit them.

### Disproved hypotheses (also valuable)

See `experiment_logs/Plonky3/bug_hunter_3/findings.tsv` for analytical disproofs documenting invariants (batch_multiplicative_inverse splits, halve goldilocks branchless, WHIR sumcheck packed-vs-scalar, FRI fold_matrix arity chaining).

## This hunt's focus — **AIR / Constraint System Soundness**

Plonky3's `uni-stark` crate (and the AIR traits it exposes) is the algebraic constraint system. The prover commits to a trace polynomial, evaluates AIR constraints symbolically to construct a quotient polynomial, and produces opening proofs. The verifier evaluates AIR constraints at a single random point and checks the quotient. Bugs in this layer are soundness bugs by definition.

Prior hunts (bh1 scalar field, bh2 packed SIMD, bh3 composition, bh4 verifier-side) did NOT explore the AIR constraint system itself. This is fresh surface.

### Specific surfaces (high bug potential)

You pick — depth over breadth.

1. **Transition constraint enforcement across rows.** The transition selector polynomial vanishes on the last row. Is the symbolic builder consistent with the numerical evaluation? What if a constraint references `local + next` where `next` is the last row's wraparound — does the prover and verifier agree on the value of `next`?

2. **First-row / last-row selector polynomial correctness.** Plonky3's selectors at the boundary of the evaluation domain are subtle (vanishing polynomials, complementary selectors). What if the trace has exactly 1 row? Exactly 2 rows? A trace whose height equals the FRI domain size minus 1?

3. **Symbolic builder vs evaluation builder consistency.** The prover constructs the quotient polynomial via a `SymbolicAirBuilder` (lazy AST). The verifier evaluates via a `VerifierConstraintFolder` (immediate). Both must agree on every constraint. Look for: constraints that simplify to a constant in one builder but not the other; operators that commute symbolically but not numerically (e.g., associativity broken by Montgomery reduction order).

4. **Public input binding.** Public inputs are committed to a separate column or absorbed into the transcript. Is the verifier's "claimed public input" exactly the prover's? What if the verifier accepts a public-input vector of a different length than the prover committed to?

5. **Quotient polynomial degree bound.** The prover's quotient `Q = C / Z_H` has bounded degree. If the AIR has higher degree than declared (or includes a malformed term), the quotient is no longer polynomial. Does the FRI commitment phase catch this? What if the prover commits a polynomial of degree above the bound and the verifier doesn't check?

6. **Cross-row composition via challenge.** Permutation arguments and lookup arguments use a random challenge from the verifier. Is the challenge sampling order well-defined? Can a malicious prover precompute conflicting commitments and select the favorable one after seeing the challenge?

7. **AIR composition with public inputs of unusual size.** Empty public inputs. Single public input. Public input vector larger than the trace width.

### Anti-targets

- Re-testing field-arithmetic edge cases (bh1/bh2 covered)
- Re-testing FRI fold, WHIR sumcheck, packed extensions (bh3 covered)
- Re-testing verifier acceptance of structurally-malformed proofs (bh4 covered)
- Property-test-style "random inputs, see what breaks"

## How to hunt — the cycle

1. **Read code.** Pick an area. Understand invariants — what does the AIR builder assume? What does the verifier promise?
2. **Form a hypothesis.** Specific code path, specific input class. Write it in your commit message.
3. **Write a minimal test** that FAILS if the bug exists.
4. **Commit on the experiment branch** (never main): `hunt-<id>: <hypothesis>`.
5. **Run:** `RUSTFLAGS="-C target-cpu=native" cargo test -p <crate> --release -- <test_name> 2>&1`.
6. **Evaluate:** test FAILS → fix + commit `hunt-<id>-fix` + log as `found`. Test PASSES → `git revert HEAD` + log as `not_found` with WHY.
7. **Move on.**

### Good vs bad hypothesis

- Good: "if the AIR has degree > 2N and the prover commits a polynomial of degree 2N, does the verifier's FRI low-degree-test catch it on the boundary case where the high-degree term coefficient is zero except at one position?"
- Bad: "test the AIR with random constraints and see what breaks" (coverage, not hunting)

## Severity classification

- **Critical** — Verifier accepts a malformed/forged proof (soundness break); arithmetic produces wrong field elements that silently corrupt downstream proofs.
- **High** — Correctness bug under plausible non-adversarial conditions a real prover could hit.
- **Medium** — Bug only under adversarial inputs or extreme parameters no current prover uses; dormant-but-critical-if-adopted classifies here.
- **Low** — Doc-vs-code mismatch with no observable wrong behavior.

## Logging — `findings.tsv`

Append every investigation to `~/zk-autoresearch/experiment_logs/Plonky3/bug_hunter_5/findings.tsv`:

```
id	category	hypothesis	test_file	result	severity	commit	notes
```

Suggested categories for bh5: `air-transition`, `selector-polynomial`, `symbolic-vs-verifier`, `public-inputs`, `quotient-degree`, `permutation-challenge`, `air-composition`.

Log EVERY investigation. `not_found` reasoning documents invariants — almost as valuable as bugs.

## Important constraints

- **`RUSTFLAGS="-C target-cpu=native"`** always.
- **First cargo build is 10-15 min.** Normal.
- **Stay on the experiment branch.** Never main.
- **No `git push`.** Brain pushes after review.
- **Don't write tests you expect to pass.** Coverage ≠ hunting.
- **Depth over breadth.** One deep investigation > ten shallow.
- **No ScheduleWakeup, no sleep.** Loop continuously.

## Stop criterion

Stop when one of:
- 24 hours wall-clock elapsed
- 20 consecutive `not_found` with no `found` in between
- Brain instructs you to stop

Write `verdict.md` summarizing: total investigations, bugs found (with severity), key invariants documented, recommendations for the next hunter.

## Never stop (within stop criterion)

Hunt autonomously until a stop condition hits.

---
*Standard bug-hunter form. Surface for bh5: AIR / constraint system soundness. Drafted 2026-05-12.*
