# Plonky3 — Bug Hunter 8

> Standard bug-hunter form. This hunt is methodologically different from bh1-bh7: it hunts for **cross-prover regressions** in Plonky3 that break downstream consumers (leanMultisig, Jolt, SP1). See `bug_hunter_4/program.md` for the template origin.

## Role

You are a cross-prover regression hunter. Plonky3 is the substrate that leanMultisig, Jolt, and SP1 build on. When Plonky3 changes (commits to main, refactors, API churn), downstream provers can break silently:
- Compilation breaks (API change without semver bump)
- Behavior changes (returns different output for the same input, breaks downstream tests)
- Performance regressions (downstream wall-clock gets worse, no Plonky3 test catches it)
- Trait re-export changes that downstream relied on

Your job: identify Plonky3 main commits over the recent window that could have broken downstream, write tests on the downstream side that detect the regression, fix or escalate.

This is NOT a Plonky3-internal correctness hunt (that's bh1-7). This is **integration regression hunting**.

## Hardware

Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). `RUSTFLAGS="-C target-cpu=native"`.

You will need:
- `~/zk-autoresearch/Plonky3` (target — Plonky3 main)
- `~/zk-autoresearch/leanMultisig` (downstream consumer)
- `~/zk-autoresearch/jolt` (downstream consumer)
- `~/zk-autoresearch/sp1` (downstream consumer, if cloned — verify)

All should be cloned per `scripts/setup/leanmultisig.sh` (Hetzner setup).

## Repo & Setup

Coordinator has checked out the experiment branch on zk-autoresearch (NOT on Plonky3 itself — Plonky3 stays on its main).

```bash
cd ~/zk-autoresearch
git rev-parse --abbrev-ref HEAD     # not 'main' on zk-autoresearch
ls Plonky3 leanMultisig jolt 2>&1   # verify downstream consumers cloned
ls sp1 2>&1 || echo "(sp1 not cloned — skip its part)"
```

## Examples — what prior hunts have found

Cross-prover regressions have NOT been hunted directly in our work, but related observations:
- The 2026-05-11 macOS Mach-VM bug (`project_zk_alloc_macos_bug` historical entry) was a downstream-only effect: zk-alloc compiled and tested fine in isolation; only leanMultisig integration on macOS surfaced the 12× regression. **This is exactly the class of bug bh8 hunts.**
- bh3-5 `PackedCubicTrinomialExtensionField::div` is "dormant" — no current Plonky3 callers. But future downstream provers WILL adopt the type, and the bug becomes critical at adoption time. bh8 detects this earlier by running each downstream's full prove-loop against Plonky3 main.

### Bug traits to internalize

1. **Plonky3 main passes its own tests but the downstream prover's full-proof-cycle fails.** API contract changed; Plonky3 doesn't test the integration.
2. **Compilation breaks downstream without semver hint.** A `pub fn` becomes `pub(crate) fn`, or a trait method signature shifts argument order.
3. **Behavior shifts silently.** Plonky3 changes the order of operations in FRI fold; the new order is mathematically equivalent on Plonky3's tests but produces a different transcript on leanMultisig's tighter parameters.
4. **Performance regresses on downstream but not on Plonky3 microbenches.** Plonky3 tests use small problem sizes; downstream uses real-scale, and the regression only manifests there.
5. **Cross-prover divergence.** Same Plonky3 change passes Jolt's tests but breaks leanMultisig (or vice versa) — different downstream provers depend on different invariants.

## This hunt's focus — **Cross-prover regressions: Plonky3 main vs downstream consumers**

The job has two parts: (A) identify SUSPECT Plonky3 commits, (B) test downstream against them.

### Part A — Identify suspect Plonky3 main commits

```bash
cd ~/zk-autoresearch/Plonky3
git log --oneline --since="2026-04-01" main | head -40
```

Look for commits whose message suggests:
- API churn ("rename", "refactor", "move", "extract trait", "split crate")
- Behavior change ("change order of", "switch to", "use X instead of Y")
- Optimization with subtle semantic implications ("inline", "remove allocation", "use unsafe", "specialize for")
- Removal ("remove deprecated", "delete unused")

These are your candidate commits. Pick 3-5 most suspicious — depth over breadth.

For each candidate, identify:
- The commit before it (the "baseline" version where downstream worked)
- The commit itself (the "candidate regression")

### Part B — Test downstream against each candidate

For each candidate Plonky3 commit:

1. Check out Plonky3 at the candidate commit. The downstream provers vendor Plonky3 either via Cargo dependency or vendored source. Identify how each downstream pulls Plonky3:
   - leanMultisig: check `Cargo.toml` for path/git/version of Plonky3 (or its forked `mt-*` crates)
   - Jolt: same check
   - SP1: same check
2. Update the downstream's Plonky3 reference to point at the candidate commit.
3. Run the downstream's main test suite or proof generation (e.g., leanMultisig `prove_loop 1`).
4. Compare result vs the baseline commit. If the downstream:
   - **Fails to compile** → API regression. `found`.
   - **Tests fail** → behavior regression. `found`. Identify which constraint or assertion broke.
   - **Tests pass but wall-clock significantly slower** (>10%) → performance regression. `found` with severity = high (not critical).
   - **Tests pass with same wall-clock** → not a regression. `not_found`. Document what the commit changed.

If a candidate doesn't show in any downstream, that itself is fine — the commit was downstream-safe.

### Specific surfaces (high bug potential)

You pick depth-over-breadth — but here are calibration candidates worth checking:

1. **leanMultisig's `mt-*` forked primitives.** These are vendored copies of Plonky3 crates. If a Plonky3 main commit changed something that leanMultisig's `mt-*` fork doesn't yet have, the integration may diverge subtly. Specifically: does leanMultisig's `mt-koalabear` agree with Plonky3 `p3-koala-bear` on every Poseidon2 invocation?
2. **Jolt vs Plonky3 BN254 / Goldilocks.** Jolt uses BN254 and Goldilocks via Plonky3. Recent Plonky3 commits touching either field could break Jolt's prover.
3. **SP1 vs Plonky3 prover trait.** SP1 builds proving systems on top of Plonky3 traits. Trait-signature changes (or new default methods) propagate downstream.
4. **Build-system breaks.** Plonky3's `Cargo.toml` workspace structure changes; downstream `Cargo.lock` resolution breaks.

### Anti-targets

- Hunting bugs in Plonky3 itself (bh1-7 territory)
- Hunting bugs in downstream code that aren't related to Plonky3 (out of scope)
- Performance regression testing as the PRIMARY goal — that's a separate benchmark methodology

## How to hunt — the cycle

1. **Pick a candidate Plonky3 commit from Part A.**
2. **Hypothesize:** "Commit X changes Y in Plonky3, which leanMultisig depends on via Z. The change breaks Z because..."
3. **Test the hypothesis:** check out Plonky3 at X, point downstream's Plonky3-ref at X, run downstream's test suite or prove_loop.
4. **Evaluate:**
   - Downstream compiles + tests pass → not_found (commit is downstream-safe). Log with what changed and why downstream survived.
   - Downstream breaks → found. Identify mechanism (API, behavior, perf). Write a regression test in the DOWNSTREAM repo's test suite that exercises the broken path. The test ensures future Plonky3 bumps catch this class of break.
5. **Move on to next candidate.**

### Good vs bad hypothesis

- Good: "Plonky3 commit `abc123` renamed `Field::W` to `Field::WIDTH`; leanMultisig's `mt-koalabear` still references `Field::W`; integration breaks at compile time. Verify by checking out abc123, pointing leanMultisig at it, and running `cargo build`."
- Bad: "Run leanMultisig with Plonky3 main and see if it passes" (no specific hypothesis, just regression suite)

## Severity classification

- **Critical** — Plonky3 main passes its own tests but downstream prover produces wrong proofs that the downstream verifier still accepts. (Soundness break observed through downstream.)
- **High** — Downstream prover fails (compile error, panic, or test failure) on Plonky3 main HEAD. Production deploys downstream can't bump Plonky3.
- **Medium** — Wall-clock regression >10% on downstream when bumping Plonky3 main from one commit to another. Or: downstream needs a non-trivial fix to track Plonky3 main.
- **Low** — API renamed but downstream uses a stable alias; downstream still works but the rename should be documented in Plonky3 changelog.

## Logging — `findings.tsv`

`~/zk-autoresearch/experiment_logs/Plonky3/bug_hunter_8/findings.tsv`:

```
id	category	hypothesis	test_file	result	severity	commit	notes
```

Special `category` values for bh8: `api-rename`, `behavior-shift`, `perf-regression`, `trait-signature`, `vendored-divergence`, `cross-prover-disagreement`, `cargo-resolution`.

`commit` field for this hunt should be the **Plonky3 commit being tested**, plus a comma-separated test commit on the downstream side if any was added.

Log every investigation. Documenting "Plonky3 commit X is downstream-safe because Y" prevents re-testing it in future bh8 runs.

## Important constraints

- `RUSTFLAGS="-C target-cpu=native"` always.
- First cargo build is 10-15 min per repo (Plonky3, leanMultisig, Jolt, SP1) — plan accordingly.
- Stay on the zk-autoresearch experiment branch; downstream repos can be in detached-HEAD state for testing.
- Do NOT modify Plonky3 itself (that's bh1-7). Modify only downstream regression tests.
- No `git push` on any repo. Brain handles upstream patches.
- Don't run more than one downstream's full test suite simultaneously (compile contention; gives muddy results).
- Depth over breadth: 3-5 candidate Plonky3 commits, all four downstream provers tested per candidate, is better than 20 commits × one downstream.
- No sleeps; loop continuously.

## Stop criterion

Stop when one of:
- 24 hours wall-clock elapsed
- 3-5 candidate Plonky3 commits investigated against all available downstream provers
- Brain instructs you to stop

Write `verdict.md` summarizing: candidates investigated, regressions found (severity), downstream-safe commits documented, recommendations for Plonky3 CI (e.g., "add a smoke test for leanMultisig integration").

## Never stop (within stop criterion)

Hunt autonomously until a stop condition hits.

---
*Standard bug-hunter form, adapted for cross-prover integration. Surface for bh8: regressions in Plonky3 main that break leanMultisig / Jolt / SP1 downstream. Drafted 2026-05-12.*
