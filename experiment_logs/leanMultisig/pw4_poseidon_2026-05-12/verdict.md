# pw4 Poseidon Performance Research — Verdict

**Branch:** `pw4-2026-05-12` (off `origin/main @ c868330c`)
**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64 GiB RAM, AVX-512
**Concurrent work (NOT in baseline):** PR #216 (FFT-MDS / RATE=12 sponge / MMO 124-bit feedforward / `#[inline]` thin-LTO).

## Cumulative Δ vs baseline: **0%** (no commits kept)

Nine iterations completed across the experiment; zero crossed the −1.0% wall-clock gate. The prior session contributed iters 1–6 (all discards); this session contributed iters 7–9 (all discards).

## The single robust finding

`sparse_first_row[r][0] = mds[0][0] = MDS_CIRC_COL[0] = 1` by construction across all 20 partial rounds. The SIMD partial-round inner loop's `s0_val * first_row[0] + partial_dot` is therefore an identity multiplication followed by an add.

**Measured impact (SIMD-only, pw4-7):**

| Metric | Value |
|---|---:|
| Wall-clock Δ | **−0.73%** |
| p-value | 0.00081 |
| Samples | 12 baseline / 12 candidate (3 paired rounds × 4 warm proofs) |
| Per-round Δ | −0.79 / −1.01 / −0.40 |

This is a real, statistically rock-solid optimization (p well below 0.01) that does **not** cross the 1.0% gate. The cost saved is 20 `vpmuludq` + Montgomery reduce per Poseidon1 permutation: one identity mul per partial round, on the critical chain immediately after sbox + round-constant add. The change is bitwise-identical (`test_plonky3_compatibility` passes scalar permutation against the Plonky3 reference vector).

## Three companion attempts — none compounded

| Iter | Companion | Measured Δ | p-value | Lesson |
|---|---|---:|---:|---|
| pw4-7 | (SIMD only — baseline for the bundle search) | **−0.73%** | 0.00081 | The real win; sub-gate. |
| pw4-8 | + same identity-mul removed in `sparse_mat_air_16` (AIR-eval path) | −0.34% | 0.126 | AIR-side actually *added* variance — the symbolic-builder codegen prefers `ZERO + accumulate(j=0..16)` over `state[0] + accumulate(j=1..16)`. Generic / extension-field paths are not parallel to SIMD here. |
| pw4-9 | + drop unused `[0]` slot of `packed_sparse_first_row` and `[15]` slot of `packed_sparse_v` from precomputed storage (−2.5 KiB / 40 cache lines of constant footprint) | −0.73% | 0.000364 | Identical to SIMD-only; **the layout-tightening contributes 0%** at wall-clock resolution. The 2.5 KiB removed is small relative to the 40 KiB partial-round constant footprint, and even with reduced L1D pressure (profile shows 10.36% miss rate), the win didn't widen. |

Three independent companion ideas, all sub-gate; pw4-7 remains an *orphan* sub-gate-real change with no compounding partner found in this session.

## What this teaches about the surface

1. **The mul-port-throughput ceiling is real and 20-mul-granular.** Removing 20 muls per perm out of ~700 total → −0.73% wall-clock. The conversion rate (~0.36% wall-clock per 1% mul-throughput) tracks the partial-round share of `compress_mut` cost. So the next algorithmic win would need to remove a similar quantum of muls (~50+) to clear the gate alone.

2. **Generic / symbolic / AIR codegen does *not* parallel the SIMD path.** The same algebraic identity that wins in `permute_simd` *regresses* when applied symbolically (pw4-8). When picking optimizations, the SIMD path's wins do not automatically transfer; future work should benchmark each path independently before bundling.

3. **Sub-1-KiB constant-array trimming is below detection threshold on this baseline.** Even though the profile shows 10.36% L1D miss rate, removing 40 cache lines (~2.5 KiB) of constant footprint from a 40-KiB working set didn't move wall-clock. The L1D pressure is concentrated elsewhere (state, leaf data, scratch).

4. **Source-order reorderings of the partial-round inner loop don't help.** PATH-A (sbox + rc) and PATH-B (dot product) are already independent; the OOO core schedules them in parallel regardless of source order. Confirms profile finding that pipeline is well-populated (serial IPC 1.29 ≈ mul-port ceiling).

5. **Identity multiplications hide in MDS sparse decompositions even after careful design.** `compute_equivalent_matrices` returns a sparse factorization where the *fixed* entry `m_i_returned[0][0] = mds[0][0] = MDS_CIRC_COL[0]` flows into `sparse_first_row[r][0]` for every round. When the MDS column starts with 1 (a natural choice for Plonky3 KoalaBear), this is dead code in the hot path. Generalizable lesson: audit *fixed* (non-data-dependent) entries in any sparse decomposition for residual identity values.

## Stop-criterion accounting

| Iter | Magnitude | Decision | Points |
|---|---|---|---:|
| 1–6 | mixed (4 micro, 2 medium) | discard | +4.5 (prior session) |
| 7 | micro | discard (sub-gate real) | +1.0 |
| 8 | micro | discard | +1.0 |
| 9 | micro | discard | +1.0 |
| **Total** | | | **7.5 / 12** |

Stopping below the 12-point ceiling because three coordinated attempts on the same surface (Tier 1 #5 + adjacent layout) all bottomed out at −0.73%. Continuing to mine micro variations on this axis would burn budget without informational yield. The next iteration should attack a structurally different surface (recommendations below).

## Recommendations for the next experiment

The remaining EV is concentrated in surfaces this experiment did NOT attack:

1. **Find a >1% structural win, then bundle pw4-7 with it.** The identity-mul removal is shovel-ready; any future commit that crosses the gate on its own should fold in the 3-line SIMD change for a ~+0.7% bonus. Specifically attractive companions:
   - Tier 1 #2 (delayed Montgomery reduction across the partial-round s0 chain) — predicted +3–6%, needs explicit overflow-bound derivation
   - Tier 2 jagged-PCS leaf packing — predicted uniform +4–8%, touches `stacked_pcs.rs`
   - Tier 2 first-Merkle-layer multi-leaf absorption — needs measurement first (count actual `precompute_zero_suffix_state` activation rate)

2. **Investigate the AIR-side regression mechanism.** The pw4-8 finding (AIR-side identity-mul *adds* variance) is interesting on its own. If `sparse_mat_air_16` becomes a hot path under post-PR-#216 conditions, understanding why `new_s0 = state[0] + …` codegen worse than `new_s0 = ZERO + …` could unlock a real fix. Hypothesis: the symbolic builder's expression-tree CSE is sensitive to the leading-zero pattern.

3. **Re-profile on top of PR #216.** Once #216 lands, the partial-round share of cycles shifts (MMO feedforward changes the chain depth; RATE=12 changes hash count per leaf). The current profiling baseline is anchored on origin/main; the next experiment's candidate ranking should be redone against the #216-merged tree.

4. **Mark the identity-mul removal as a "free with companion" change in brain.** If any future PR touches `permute_simd`, include the 5-line diff (drop `* first_row[0]`) automatically. Cost: one debug-assert and three line changes. Benefit: ~+0.7% guaranteed.

## Files / scope

- Writable scope used: `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` (all 3 iters); `crates/lean_vm/src/tables/poseidon_16/mod.rs` (iter 8 only)
- All commits reverted; working tree returns to `origin/main` cleanly
- Bench / correctness harness unchanged
