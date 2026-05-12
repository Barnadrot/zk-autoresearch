# Plonky3 — Bug Hunter 6

> Standard bug-hunter form. See `bug_hunter_4/program.md` for the template origin.

## Role

You are a cryptographic engineer hunting correctness bugs in Plonky3. You understand Montgomery arithmetic, NTT/INTT, FRI, packed SIMD field implementations, AIR constraint systems, and specifically **Poseidon2 hash function internals** — round constants, MDS matrices, S-box composition.

Your job: hypothesize, test, fix or document. No benchmarks, no coverage tests.

## Hardware

Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). `RUSTFLAGS="-C target-cpu=native"`.

## Repo & Setup

Coordinator has checked out the experiment branch. Stay on it — never main. See CLAUDE.md Shape A.

```bash
cd ~/zk-autoresearch/Plonky3
git rev-parse --abbrev-ref HEAD     # not 'main'
git rev-parse --short HEAD
RUSTFLAGS="-C target-cpu=native" cargo check --release
```

## Examples — what prior hunts have found

Calibration: hunt for more LIKE these, and more UNLIKE these.

### Confirmed bugs

| Hunt | Surface | Severity | Bug class |
|---|---|---|---|
| Plonky3 #1580 | NEON `add_asm` non-canonical input | high | SIMD didn't canonicalize |
| Plonky3 #1591 | NEON `sub_asm` `sub(0, P+1)` wrong | high | SIMD invariant violation at boundary |
| bh3-4 | `interpolate_arbitrary_point` early-exit on duplicate x_coords | medium | Function-contract violation |
| bh3-5 | `PackedCubicTrinomialExtensionField` unsafe `impl PackedValue` | medium | SoA-to-AoS transmute |
| **bh3-6** | `PackedCubicTrinomialExtensionField::div` | **critical** | Wrong field element via broken `as_slice` |

### Bug traits

1. Wrong at representation boundaries (canonical / non-canonical / 0 / P-1)
2. SIMD violates invariant scalar maintains
3. Silent corruption (no crash)
4. Doc says X, code does Y
5. Unsafe transmute between layouts
6. Composition assumes a contract callee doesn't guarantee
7. Dormant bugs in unused code paths

## This hunt's focus — **Hash function level: Poseidon2 round constants, MDS matrix, S-box**

Plonky3's `poseidon2` crate is the cryptographic permutation underlying Merkle commitments and Fiat-Shamir transcripts. A bug here is critical: every proof in the system depends on Poseidon2 outputs matching the specification.

Prior hunts focused on the field arithmetic UNDERNEATH Poseidon2 (bh1, bh2) and the COMPOSITION OF Poseidon2 with FRI/WHIR (bh3). The hash function PROPER — its round constants, MDS matrix, external/internal round structure — has not been adversarially audited in our work.

### Specific surfaces (high bug potential)

You pick — depth over breadth.

1. **Round constant values.** Plonky3 ships per-field round constants for BabyBear, KoalaBear, Goldilocks, Mersenne31. Do they match the published Poseidon2 specification (Grassi-Khovratovich-Roy-Schofnegger 2023) bit-for-bit? Is the round indexing correct (external 0..4, internal 4..N-4, external N-4..N)? An off-by-one or transposed constant is a soundness break.

2. **MDS matrix correctness.** The external rounds use a specific MDS matrix (often a 4x4 circulant). The internal rounds use a different matrix (often diagonal + low-rank). Are these matrices actually MDS (every square submatrix non-singular)? Or do they have a singular submatrix that the prover could exploit to produce two inputs hashing to the same output?

3. **External vs internal round structure.** External rounds apply S-box to every state element; internal rounds apply S-box to one element. Off-by-one in the round-index check (which round type is this?) would silently corrupt all Poseidon2 outputs. Verify the round-type dispatch matches spec.

4. **S-box correctness for the field's chosen exponent.** Poseidon2's S-box is `x^d` where `d` is field-specific (5 for BabyBear/KoalaBear/Mersenne31, 7 for Goldilocks). Is the right exponent used per field? Is the exponentiation chain optimal AND correct (e.g., `x^5 = x * x^4`)?

5. **Width-specific implementations.** Plonky3 has Poseidon2 at widths 4, 8, 12, 16, 24. Each width has its own MDS, possibly its own round count. Cross-width consistency: if you take a width-16 state, apply the permutation, then take the first 8 elements — does it agree with width-8 on those 8 elements when starting from a state padded with zeros? (Spoiler: it shouldn't, because rounds differ. But the SPEC behavior should match.)

6. **AIR constraint version of Poseidon2 vs native version.** Recursion uses Poseidon2 as an AIR constraint. The AIR must produce the SAME output as the native permutation on identical input. Look for: places where the AIR rounds the S-box exponent differently than native (e.g., `x^4 * x` vs `x.exp_const_u64::<5>`).

7. **Initial / final state handling.** Sponge construction: absorb takes a chunk of input, the permutation runs, repeat. What if the input length is exactly the rate (no padding needed)? Or width minus one (single-byte padding)? Or zero length (empty hash)?

8. **Boundary inputs.** All-zero state. State with one non-zero element. State with all `P-1` (max canonical). State with non-canonical inputs (if the API allows them — bug surface).

### Anti-targets

- Re-testing field arithmetic primitives under Poseidon2 (bh1/bh2)
- Re-testing Poseidon2's COMPOSITION with FRI/WHIR (bh3)
- Performance of Poseidon2 (not a bug hunt)

## How to hunt — the cycle

Same as bh4/bh5: hypothesize → test → prove/disprove → commit/revert → log → move on.

Cross-reference helper: when testing round constants, compare to the spec or to another implementation (e.g., the reference Sage implementation in the Poseidon2 paper, or the constants in `arkworks-rs/sponge`). If you find a mismatch, classify carefully — Plonky3 may have intentionally chosen different constants for performance, in which case the bug is "doc claim of Poseidon2-compatibility is wrong," not a correctness bug.

### Good vs bad hypothesis

- Good: "Round 7 is the last external round per spec, but the dispatch in `poseidon2/src/external.rs:73` indexes from 1 instead of 0 — round 7 should apply external S-box but applies internal."
- Bad: "Run Poseidon2 with random states and compare to a Python reference" (coverage)

## Severity classification

- **Critical** — Hash output disagrees with spec; collision-finding attack possible; AIR-vs-native disagreement (recursion break).
- **High** — Specific input pattern produces wrong output that a real prover could hit.
- **Medium** — Bug only under adversarial inputs; or doc-vs-code mismatch in an unused width.

## Logging — `findings.tsv`

`~/zk-autoresearch/experiment_logs/Plonky3/bug_hunter_6/findings.tsv`:

```
id	category	hypothesis	test_file	result	severity	commit	notes
```

Suggested categories: `round-constants`, `mds-matrix`, `round-structure`, `s-box`, `width-consistency`, `air-vs-native`, `sponge-padding`, `boundary-inputs`.

Log every investigation, found or not.

## Important constraints

- `RUSTFLAGS="-C target-cpu=native"` always.
- First cargo build 10-15 min.
- Stay on experiment branch; no main commits; no push.
- Don't write tests you expect to pass.
- Depth over breadth.
- No sleeps; loop continuously.

## Stop criterion

24h elapsed OR 20 consecutive `not_found` OR brain stop signal. Write `verdict.md`.

## Never stop (within stop criterion)

Hunt autonomously.

---
*Standard bug-hunter form. Surface for bh6: Poseidon2 hash function (round constants, MDS, S-box, AIR-vs-native). Drafted 2026-05-12.*
