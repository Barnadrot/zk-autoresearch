# `_legacy/` — hibernated gate scripts

These scripts were retired from the active gate set on 2026-05-13 after the pw4 post-mortem. They are preserved (not deleted) because they may be useful again for future experiments of a different shape. See parent `../README.md` for the current active set.

## Why hibernated

| Script | Reason |
|--------|--------|
| `eval_iai.sh` | Wrong calibration class for current Poseidon work. Catches sub-noise Ir reductions on sumcheck/multilinear kernels but blind to microarch-sensitive wins (register pressure, scheduling, AVX-512-specific paths). Also broken on disk: references `iai_driver` binary at the old `~/zk-autoresearch/leanVM-bench` path; current bench crate is `~/zk-autoresearch/harness/leanvm/bench` and doesn't include the driver. |
| `eval_gate.sh` | Orchestrates iai → paired → revert-A/B. Two problems: (1) reads `eval_paired.sh` JSON as `deltas_pct[0]` / `p_values[0]` / `median_pct` — older schema that no longer exists (current is `delta_pct` / `p_value`). (2) Depends on iai which is hibernated. Effectively broken until both are repaired. |
| `eval_e2e.sh` | Legacy Criterion wrapper on `xmss_leaf_1400sigs`. Its own README header says "do not use as keep gate — drift-vulnerable (σ ≈ 1.0%)". Superseded by `eval_paired.sh`. Retained for reproducing pre-pw3 experiments. |
| `eval_poseidon.sh` | Wraps `cargo test ... benchmark_poseidons --ignored` for throughput numbers. No comparison, no decision logic. Superseded by the Criterion `poseidon_permute` bench in the experiment-specific bench crates. |

## When to reactivate

### `eval_iai.sh` + `eval_gate.sh`
Worth reactivating for the next **sumcheck-shape experiment** — when the bottleneck shifts to `mt_sumcheck` (12% Hetzner) or `mt_poly` (6% Hetzner) and algorithmic Ir reductions become the dominant optimization axis (Karatsuba ↔ FFT MDS, round-count reduction, quintic-extension mul fusion, etc).

To reactivate:
1. Port `iai_driver` bin into `harness/leanvm/bench/src/bin/iai_driver.rs` (small wrapper around the hot kernel). Reference: the old leanVM-bench fork has the template.
2. Fix `eval_iai.sh`'s `BENCH_CRATE` default to `~/zk-autoresearch/harness/leanvm/bench`.
3. Update `TRACK_REGEX` per experiment — it's currently sumcheck-tuned. For a Poseidon-shape experiment use `compress_mut|permute_simd|mds_fft|partial_round|dft_layer|compress_layer` etc.
4. Fix `eval_gate.sh` JSON parsing to match current `eval_paired.sh` schema (`delta_pct` / `p_value` singular, not arrays).
5. Move both back up to `harness/leanvm/scripts/` and update parent README.

### `eval_e2e.sh`
Only if reproducing a pre-pw3 experiment that originally ran against this baseline. Fix the bench path (`~/zk-autoresearch/leanVM-bench` → `~/zk-autoresearch/harness/leanvm/bench`) before running.

### `eval_poseidon.sh`
Probably never — the Criterion `poseidon_permute` bench supersedes it cleanly. If you need it, the script is short enough to rewrite from scratch.
