# Plonky3 — Bug Hunter 2 (Boundary-Value SIMD Testing)

## Role
You are a systems engineer writing boundary-value tests for Plonky3's SIMD field
arithmetic. Your goal: find bugs where packed (AVX-512/AVX2) implementations diverge
from scalar references on edge-case inputs, AND leave behind clean regression tests
that prevent future bugs.

You do NOT do analytical code review. You write tests, run them, and let the results
speak.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Context: Why This Matters

Three bugs were recently found in Plonky3's NEON (ARM) SIMD implementations:
- **#1580:** `add_asm` didn't canonicalize input — two non-canonical inputs caused wrong output
- **#1591:** `sub_asm` same bug — `sub_asm(0, P+1)` returned `2^64 - 1` instead of `P - 1`
- **#1600:** Missing carry-critical dot_product regression tests

All three bugs were invisible to proptests because uniform random sampling hits the
non-canonical band `[P, 2^64)` with probability ~2^-32. They were only found by
deliberately testing boundary values.

**The x86_64 AVX-512 and AVX2 paths have NOT been systematically tested with the same
boundary methodology.** They may harbor analogous bugs. Your job is to apply that
methodology here.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| Plonky3 | `~/zk-autoresearch/Plonky3` | `bug-hunter-2` (branch from latest `main`) | Target |

**Setup:** Before starting, pull latest upstream and create branch:
```bash
cd ~/zk-autoresearch/Plonky3
git checkout main && git pull origin main
git checkout -b bug-hunter-2
```

## Methodology: SIMD vs Scalar Oracle with Boundary Inputs

For every SIMD primitive, the test is:
1. Define `EDGE_VALUES` for the field (see below)
2. Run the packed operation on all pairs/triples of edge values
3. Compare each lane against the scalar reference
4. Any divergence is a bug

### Edge Values for Monty31 Fields (BabyBear, KoalaBear)

Internal representation is Montgomery form, but the values that matter for boundary
testing are the raw `u32` values that the SIMD intrinsics operate on:
```
0, 1, P-2, P-1, P, P+1, 2*P-1, 2*P, u32::MAX-1, u32::MAX
```
Where P is the field prime. Values ≥ P are "non-canonical" — some operations handle
them correctly, others don't. The bugs hide in the ones that don't.

For Goldilocks (u64): same pattern but with `u64::MAX`, `P`, `P+1`, `2*P`, etc.

For Mersenne31: `P = 2^31 - 1`, same boundary pattern.

### What Counts as a Finding

- **Bug found (test fails):** The packed result diverges from scalar. Write a fix.
  Commit test + fix together. Log as `found` with severity.
- **Coverage gap filled (test passes):** The test is still valuable — it prevents
  future regressions. Commit the test. Log as `coverage`.

**Do NOT revert passing tests.** Every boundary test you write is a deliverable,
whether it finds a bug or not. This is the key difference from bug-hunter-1.

## Scope: What to Test

### Priority 1: Packed Field Arithmetic (per-field, per-platform)

For each of: `baby-bear`, `koala-bear`, `mersenne-31`, `monty-31`, `goldilocks`
On each of: `x86_64_avx512`, `x86_64_avx2`

Test these operations with all edge-value pairs:
- `add` / `sub` / `neg` — the exact operation class that was buggy in NEON
- `mul` — Montgomery multiply boundary (product overflow, reduction edge cases)
- `interleave` / `pack` / `broadcast` — data movement correctness

### Priority 2: Compound Operations

- `dot_product` variants (already partially covered by #1600 — check what's missing)
- Poseidon2 `add_sum`, `diagonal_mul`, `sbox_layer` — these compose primitives and
  create non-canonical intermediates
- Poseidon2 internal/external round — full round with adversarial state (all edge
  values), compare against scalar reference

### Priority 3: Extension Field Packed Operations

- `BinomialExtensionField` packed mul/add/sub with edge-value coefficients
- Quintic extension packed operations (if they exist for x86_64)

## Test Organization (No Bloat)

Thomas's requirement: no duplicates, no 200 tests doing the same thing.

**Structure:**
- Add boundary tests to existing test modules in each crate, not new files
- Use the existing `field-testing/src/packedfield_testing.rs` infrastructure
  (it already has `boundary_u32_values` and `test_dot_product_boundary`)
- Extend that infrastructure with new boundary-pair test functions that cover
  add/sub/mul/neg, then call them from each field crate's test module
- One test function per operation class, parameterized by field/packing
- Pattern to follow: PR #1600's approach (shared infra in `field-testing`,
  thin wrappers in each crate)

**Do NOT:**
- Create standalone test files per hypothesis
- Duplicate the proptest coverage — proptests cover the random interior,
  your tests cover the deterministic boundary
- Add tests for operations that already have exhaustive boundary coverage

## Iteration Loop

1. Pick a field × platform × operation (e.g., BabyBear AVX-512 add).
2. Check if boundary tests already exist for it. If yes, skip.
3. Write boundary-pair test in the appropriate location.
4. `git commit` the test: `bh2-<id>: boundary test for <field> <platform> <op>`
5. Run: `RUSTFLAGS="-C target-cpu=native" cargo test -p <crate> --release 2>&1`
6. **Test passes:** Good — keep it. Log as `coverage` in findings.tsv.
7. **Test fails:** Bug found!
   a. Analyze the failing case.
   b. Write a fix.
   c. Amend or add a new commit: `bh2-<id>-fix: <description>`
   d. Re-run. Confirm it passes.
   e. Log as `found` in findings.tsv with severity.
8. Move to next operation.

After covering individual ops, test compositions (Poseidon rounds with adversarial state).

**Always use** `RUSTFLAGS="-C target-cpu=native"` — without it, AVX-512 paths don't execute.

**First build:** 10-15 minutes. Normal.

## Severity Classification

- **Critical** — Wrong field arithmetic that could produce incorrect proofs silently.
  (Like #1580/#1591 — the Poseidon permutation produces wrong output.)
- **High** — Divergence only on inputs that are outside the documented input contract,
  but that a caller might reasonably produce.
- **Medium** — Divergence only on inputs that no current caller produces, but could
  appear after a future optimization.
- **Coverage** — Test passes, no bug. Still committed as regression prevention.

## Logging — `findings.tsv`

Append to `~/zk-autoresearch/experiment_logs/Plonky3/bug_hunter_2/findings.tsv`:
```
id	field	platform	operation	result	severity	commit	notes
```

## NEVER STOP
Run autonomously until all Priority 1 and 2 operations are covered.
