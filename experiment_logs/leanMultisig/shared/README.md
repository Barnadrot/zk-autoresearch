# leanMultisig autoresearch — harness scripts

All scripts are leanMultisig-specific. They assume:
- leanMultisig repo at `~/zk-autoresearch/leanMultisig`
- bench crate at `~/zk-autoresearch/leanMultisig-bench`
- Criterion bench target `xmss_leaf`, filter `xmss_leaf_1400sigs`
- iai driver bin name `iai_driver` (see `leanMultisig-bench/src/bin/iai_driver.rs`)
- KVM-virtualized AMD Zen 4 on c7a.2xlarge (no CPU pinning knobs available)

Do not attempt to reuse these scripts on a different repo without re-calibration.

## Scripts

### `correctness.sh` (unchanged from original)
Runs `cargo test -p mt-koala-bear --release` and `cargo test -p mt-whir --release`.
~40 s. Exit 0 = pass.

### `eval_paired.sh` — Stage 2 wall-clock gate
Paired back-to-back criterion comparison between two git refs, same shell session, with burn-in. Replaces the original `eval_e2e.sh` fixed-baseline pattern.

- Default: HEAD~1 vs HEAD, N=1 (one paired comparison → keep/discard decision).
- Calibration/backtest mode: `--n 10` (or higher) → emits σ only, no decision.
- Handles the `main.py` runtime-load hazard by git-checkout-ing the working tree to match each binary being executed.
- Writes summary JSON to `/tmp/eval_paired_summary.json`.
- Exit: 0 = keep, 1 = discard, 2 = infra error.

```bash
bash eval_paired.sh                                      # loop-mode: HEAD~1 vs HEAD, N=1
bash eval_paired.sh --baseline 25de31b^ --candidate 25de31b --n 10  # backtest mode
```

Runtime: ~1 min/paired round + 60 s for two `cargo clean --release` + build cycles.
Per-round: ~235 s. Single-decision loop-mode: ~4–5 min.

### `eval_iai.sh` — Stage 1 instruction-count gate
Runs the `iai_driver` binary under `valgrind --tool=callgrind` at baseline and candidate, diffs per-symbol `Ir` counts for the sumcheck + adjacent hot-path namespaces.

- Default: HEAD~1 vs HEAD.
- Writes summary JSON to `/tmp/eval_iai_summary.json`.
- Tracked regex (see `TRACK_REGEX` in script): `mt_sumcheck|product_computation|sc_computation|quotient_computation|eq_mle|handle_gkr|fold_and_compute_product_sumcheck`.
- Exit: 0 = PASS (keep-eligible), 1 = FAIL (abort iter), 2 = infra error.

Runtime estimate: per binary, 50 sigs under callgrind ≈ a few minutes.

### `eval_revert_ab.sh` — Stage 3 marginal confirmation
After a marginal keep, applies a revert commit on top of HEAD, runs paired A/B (HEAD~1 = the keep, HEAD = reverted state). Expects Δ ≥ `MIN_REPRODUCE_FRACTION × claim_pct` (default 50 %).

Cleans up its revert commit before returning regardless of outcome. Exit 0 = keep confirmed, 1 = noise rider (caller must unwind the keep), 2 = infra error.

```bash
bash eval_revert_ab.sh 1.2    # claim_pct = 1.2% (magnitude of the kept win)
```

### `eval_e2e.sh` — legacy (kept for backward reference)
Original fixed-baseline bench. Superseded by `eval_paired.sh`. Do not use as a keep gate — it's drift-vulnerable (σ ≈ 1.0 %). Retained so old runs can be reproduced.

### `config.env`
Threshold and sample-size settings sourced by the scripts / loop orchestrator. Edit here, not in individual scripts. Current values reflect backtest calibration from 25de31b; re-calibrate if the sumcheck crate is refactored.

## Directories

- `report/` — output of diagnostic passes:
  - `noise_floor.md`, `noise_floor_v2.md` — σ characterization (idle, paired, pinned)
  - `bench_profile.md` — `perf record` profile confirming sumcheck is ≥30 % of inclusive time and no bench-setup artifacts dominate
  - `threshold_calibration.md` — `KEEP_THRESHOLD_PCT` derivation from backtest data

## Loop orchestration
The loop is driven by program.md instructions to the optimizer agent. There is no single orchestrator script — the agent calls these gates in sequence. See `experiment_sumcheck/program.md` "Experiment Loop" section.
