# pw4 Poseidon Performance Research — Verdict (no PR drafted)

This experiment produced **no commits to ship**. All nine iterations across two sessions were discards. The most interesting finding (pw4-7, see below) is real and statistically rock-solid but does not cross the 1.0% gate alone, and three coordinated attempts to find a compounding companion failed.

If a future PR touches `crates/backend/koala-bear/src/poseidon1_koalabear_16.rs` — for any reason — fold in the 5-line diff from pw4-7. It's ~+0.7% wall-clock free, debug-asserted to catch future MDS changes, and bitwise-identical (`test_plonky3_compatibility` passes).

## The 5-line diff worth carrying forward

In `permute_simd`'s partial-round inner loop:

```rust
// Before:
let first_row = &simd.packed_sparse_first_row[r];
let first_row_hi: &[PackedKB; 15] = first_row[1..].try_into().unwrap();
let partial_dot = PackedKB::dot_product(s_hi, first_row_hi);
let s0_val = split.s0;
split.s0 = s0_val * first_row[0] + partial_dot;

// After (first_row[0] = mds[0][0] = MDS_CIRC_COL[0] = 1 by construction):
let first_row_hi: &[PackedKB; 15] = simd.packed_sparse_first_row[r][1..].try_into().unwrap();
let partial_dot = PackedKB::dot_product(s_hi, first_row_hi);
let s0_val = split.s0;
split.s0 = s0_val + partial_dot;
```

Plus a `debug_assert_eq!(MDS_CIRC_COL[0], KoalaBear::new(1))` in `default_koalabear_poseidon1_16`.

Measured: **−0.73%** wall-clock (p = 0.00081, 12 baseline / 12 candidate samples), bitwise-identical. See `verdict.md` for the full analysis, three failed-companion attempts, and recommendations for the next iteration.

## Reproduction

```bash
# Baseline + candidate prove_loop builds, paired Welch t-test
bash ~/zk-autoresearch/harness/leanmultisig/scripts/eval_paired.sh \
  --baseline 798d881e^ --candidate 798d881e --n 3
```

The pw4-7 commit (and the pw4-8/9 follow-ups, all reverted) live in the experiment branch's history for replay.
