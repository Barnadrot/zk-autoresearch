# Plonky3 — Bug Hunter 7

> Standard bug-hunter form. See `bug_hunter_4/program.md` for the template origin.

## Role

You are a cryptographic engineer hunting **liveness and panic-class** correctness bugs in Plonky3. Liveness means: the prover should ALWAYS terminate cleanly — either return a valid proof or return a structured error. It should NEVER panic, infinite-loop, or silently truncate work on adversarial / edge-case input.

You also understand Montgomery arithmetic, FRI, AIR. But this hunt is NOT about wrong outputs — it's about whether the prover terminates correctly at boundary inputs that property tests don't cover.

You do NOT benchmark, optimize, or write coverage tests.

## Hardware

Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). `RUSTFLAGS="-C target-cpu=native"`.

## Repo & Setup

Coordinator has checked out the experiment branch. Stay on it. See CLAUDE.md Shape A.

```bash
cd ~/zk-autoresearch/Plonky3
git rev-parse --abbrev-ref HEAD     # not 'main'
git rev-parse --short HEAD
RUSTFLAGS="-C target-cpu=native" cargo check --release
```

## Examples — what prior hunts have found

### Confirmed bugs

| Hunt | Surface | Severity | Bug class |
|---|---|---|---|
| Plonky3 #1580 | NEON `add_asm` non-canonical input | high | SIMD didn't canonicalize |
| Plonky3 #1591 | NEON `sub_asm` `sub(0, P+1)` wrong | high | SIMD boundary violation |
| bh3-4 | `interpolate_arbitrary_point` early-exit | medium | Function-contract violation |
| bh3-5 | `PackedCubicTrinomialExtensionField` unsafe transmute | medium | SoA-AoS unsoundness |
| **bh3-6** | `PackedCubicTrinomialExtensionField::div` | **critical** | Wrong field element |

### Bug traits (liveness flavor)

For THIS hunt, the relevant variants are:
1. **Panics on degenerate input** (empty trace, single-row trace, height-1 polynomial)
2. **Integer overflow → truncated allocation → silent buffer corruption**
3. **Infinite loop in iterative algorithm** (FRI fold with unusual arity, sumcheck binding with unusual round count)
4. **OOM-trigger inputs** (logUp with adversarial multiplicities, huge claimed proof sizes)
5. **Adversarial proof sizes** — declared size doesn't match actual on deserialization
6. **Unreachable! or panic! reachable from adversarial path**

## This hunt's focus — **Prover & verifier liveness under adversarial / edge-case inputs**

The prior hunts (bh1-bh4, bh5 AIR-soundness, bh6 Poseidon2) all target correctness of the OUTPUT. This hunt targets **termination behavior**: does the prover panic, loop, or OOM on adversarial inputs where it should return a structured error?

Liveness bugs are real-world: a malicious user submits a crafted proof to a verifier service; the verifier panics; the service crashes; denial-of-service. Or a prover gets called with an empty trace and panics, taking down the proving job.

### Specific surfaces (high bug potential)

You pick — depth over breadth.

1. **Empty / single-element / boundary-size inputs.** Empty trace. Trace with exactly 1 row. Trace with height = 2^0 = 1. Empty AIR (no constraints). Empty public inputs. Polynomial of degree 0. Polynomial of degree 2^N exactly (boundary of the FRI domain). What panics? What returns an error? What silently produces wrong output?

2. **Integer overflow in size calculations.** Plonky3 deals with `usize`-typed dimensions (trace height, polynomial degree, FRI domain size). Multiply two large `usize`s → wrap → small allocation → buffer overrun. Look for `*` and `<<` between user-influenced values.

3. **FRI iteration termination.** FRI folds until the polynomial fits in the final commitment. What if the prover gives `folding_factor = 2^32`? What if `final_poly_len > initial_poly_len`? What if `num_queries = 0`?

4. **logUp multiplicity overflows.** logUp tracks multiplicities as field elements. What if a multiplicity is `2^31` (out of canonical range)? What if total multiplicity-fraction summing to zero on a single row (denominator zero in the partial-product)?

5. **MMCS commitment to a zero-row matrix or zero-col matrix.** Width-0 or height-0 inputs. Does `commit` panic? Does it return an empty commitment that can be successfully "opened" at impossible indices?

6. **Verifier liveness on malformed proofs.** Truncated proofs. Proofs with declared-length fields that exceed remaining bytes. Proofs where the Merkle path's claimed depth contradicts the commitment's degree. Does the verifier return a clean error, or panic/abort/loop?

7. **Deserialization edge cases.** Compact field-element encodings, variable-length lists, nested proofs (e.g., recursion). What if a length prefix is `u32::MAX`? What if a field element bytes are non-canonical?

8. **Concurrent access under adversarial parallelism.** Rayon thread pool with `num_threads = 1`. With `num_threads = 64` on an 8-core machine. With deeply recursive parallel iterators. Look for deadlocks, double-locking, or starvation patterns.

### Anti-targets

- Wrong-output bugs (bh3, bh4, bh5, bh6 territory) — log them but don't pursue
- Performance regressions (not a bug hunt)
- Compile-time errors / build-system bugs

## How to hunt — the cycle

Slight adaptation for liveness work: your test should EITHER make the prover/verifier `panic`/loop/OOM on input X (bug) OR return a structured error (no bug). A test that produces wrong output is bh3-bh6's domain.

1. **Read code.** Identify a function that processes user-influenced input (size, length, polynomial). Trace what happens if that input is 0, MAX, or just above a power-of-2 boundary.
2. **Form a hypothesis.** "If trace height is 0, `commit_to_trace` panics in `subtract::<usize>` because it computes `height - 1`."
3. **Write a test:** call the function with the adversarial input; assert it does NOT panic AND returns a recognizable error type. If it panics or loops, your test fails the assertion (or hangs — set `#[test] #[should_panic]` if you confirmed the panic, OR set a `Duration::from_secs(N)` timeout via `cargo test --timeout`).
4. **Commit on experiment branch:** `hunt-<id>: <hypothesis>`.
5. **Run:** `RUSTFLAGS="-C target-cpu=native" cargo test -p <crate> --release -- <test_name> 2>&1`.
6. **Evaluate:**
   - Panic OR hang OR OOM → liveness bug confirmed. Write a fix (typically: validate input early, return `Err` with a descriptive enum variant). Commit `hunt-<id>-fix`. Re-run. Log as `found` with severity.
   - Returns clean error → not_found. Log with reasoning about which guard prevents the panic.
   - Returns wrong output → log as `out_of_scope` (this is a bh3-bh6 finding, not liveness; brief note for cross-reference).

## Severity classification

- **Critical** — Adversarial input crashes / loops a verifier service. DoS vector.
- **High** — Plausible non-adversarial input crashes the prover; production proving jobs die.
- **Medium** — Adversarial input panics a low-level helper that's not yet exposed in a public API.
- **Low** — Edge case that produces an unhelpful error message but doesn't crash.

## Logging — `findings.tsv`

`~/zk-autoresearch/experiment_logs/Plonky3/bug_hunter_7/findings.tsv`:

```
id	category	hypothesis	test_file	result	severity	commit	notes
```

Suggested categories: `empty-input`, `size-overflow`, `fri-termination`, `logup-multiplicity`, `mmcs-zero-dim`, `verifier-malformed`, `deserialization`, `concurrency-edge`.

Special `result` values for this hunt:
- `found` — panic / hang / OOM / silent corruption confirmed
- `not_found` — clean error returned (log which guard)
- `out_of_scope` — wrong-output bug observed (cross-reference to bh3-bh6)

## Important constraints

- `RUSTFLAGS="-C target-cpu=native"` always.
- First cargo build 10-15 min.
- Stay on experiment branch; no main commits; no push.
- For tests that may hang, USE a timeout: `cargo test --timeout 30` or wrap in `std::thread::spawn` + `join_timeout`.
- Do NOT spawn a test that allocates more than 16 GiB (would OOM Hetzner; defeats the methodology).
- Don't write tests you expect to pass.
- Depth over breadth.
- No sleeps; loop continuously.

## Stop criterion

24h elapsed OR 20 consecutive `not_found` OR brain stop. Write `verdict.md`.

## Never stop (within stop criterion)

Hunt autonomously.

---
*Standard bug-hunter form. Surface for bh7: prover/verifier liveness on adversarial inputs. Drafted 2026-05-12.*
