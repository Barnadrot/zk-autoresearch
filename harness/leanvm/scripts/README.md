# leanVM autoresearch — gate scripts

All scripts are leanVM-specific. They assume:
- leanVM repo at `~/zk-autoresearch/leanVM`
- bench crate at `~/zk-autoresearch/harness/leanvm/bench`
- AMD Zen 4 (Hetzner AX42-U) as the primary executor
- macOS Sequoia / Apple Silicon M2/M4 as secondary executors (env_preflight degrades cleanly)

Do not reuse on a different repo without re-calibration.

## Active scripts

### `env_preflight.sh` — environmental pre-flight
**Run before any wall-clock measurement.** Verifies the host is in a measurement-trustworthy state. Linux: checks CPU governor is `performance` and 1-min load is below `ENV_PREFLIGHT_LOAD_THRESHOLD` (default 1.0). macOS: no-op pass (governor concept doesn't apply).

```bash
bash env_preflight.sh           # default thresholds, human-readable + JSON
bash env_preflight.sh --json-only
```

Exit: 0 PASS, 1 FAIL with remediation hints, 2 infra error.

### `eval_paired.sh` — per-iter wall-clock gate (PRIMARY)
Paired prove_loop bench between two git refs. Builds both binaries (fat LTO, zk-alloc, `RUSTFLAGS=-C target-cpu=native`), runs N counterbalanced rounds, computes Welch's t-test on warm-proof samples, decides keep/discard.

**Measurement hardening** (post pw4 audit):
- **N=3 default** — 12 samples/side (3 rounds × 4 warm proofs). Previous N=1 had ~40% power to detect real 1% changes; N=3 gives ~85%.
- **Counterbalanced round ordering** — odd rounds run base→cand, even rounds cand→base. Eliminates systematic within-round position bias.
- **Core pinning** — `taskset -c $TASKSET_CORES` (default `0-7`, one thread per physical core). Eliminates SMT migration noise.
- **Page cache drop** — `drop_caches` between each side within a round. Both sides start from identical cache state.
- **A-vs-A noise floor** — before measurement, runs the baseline binary against itself. Records `noise_floor_pct` in the summary JSON. Soft-fail: flags `noise_reliable: false` if noise exceeds `NOISE_FLOOR_WARN_PCT` (default 0.5%) but does NOT abort the loop.

```bash
bash eval_paired.sh                                   # HEAD~1 vs HEAD, N=3
bash eval_paired.sh --baseline <ref> --candidate <ref> --n <int>
bash eval_paired.sh --n 5 --proofs 7                  # more samples per run
bash eval_paired.sh --skip-noise-check                # bypass A-vs-A noise floor
SKIP_PREFLIGHT=1 eval_paired.sh                       # bypass env_preflight
```

Output: `/tmp/eval_paired_summary.json` (full JSON incl. `noise_floor_pct`, `noise_reliable`). Exit: 0 keep, 1 discard, 2 infra error.

Decision rule (`config.env`): `delta_pct <= -KEEP_THRESHOLD_PCT AND p_value < 0.01`. Default threshold 1.0%.

**Methodology note** (per pw4 audit 2026-05-13):
Default baseline is `HEAD~1` (rolling). Per-iter deltas are marginal contributions, NOT cumulative. After a keep, use `eval_cumulative.sh` to anchor against `origin/main` for interpretable wall-clock-vs-main numbers.

### `eval_cumulative.sh` — cumulative anchor measurement
Wraps `eval_paired.sh` with `--baseline=origin/main --candidate=HEAD --n=5`. Runs `env_preflight.sh` first. Designed to be invoked automatically after a keep lands, or manually after any structural change, to record an interpretable cumulative-vs-main number.

```bash
bash eval_cumulative.sh                               # origin/main vs HEAD, N=5
bash eval_cumulative.sh --anchor <tag> --n 7          # different anchor or sample size
EXPERIMENT_DIR=experiment_logs/leanVM/foo bash eval_cumulative.sh   # archives to <dir>/report/cumulative_<ts>.json
```

Output: `/tmp/eval_cumulative_summary.json` + optional archived copy under `EXPERIMENT_DIR/report/`.

### `eval_revert_ab.sh` — marginal-keep confirmation (optional)
After a kept change, applies a temporary revert commit on top of HEAD and runs paired A/B. Expected: reverting reproduces at least `MIN_REPRODUCE_FRACTION × claim_pct` of the claimed improvement (default 50%). If not, the keep is a noise rider and the caller must unwind.

```bash
bash eval_revert_ab.sh 1.2     # claim_pct = 1.2% (magnitude of the keep being confirmed)
```

Exit: 0 confirmed, 1 noise rider, 2 infra error. Use when the kept delta is close to the threshold (within ~2x).

### `eval_ship_gate.sh` — Criterion slow-tier ship gate
Wraps `cargo bench --bench xmss_leaf` with Criterion's save-baseline / compare-baseline workflow. Use when you want bootstrap CIs, outlier detection, and Criterion's built-in regression-detection — typically before opening an upstream PR. Per-sample alternation and adaptive sample size are Criterion's defaults.

```bash
# Establish baseline at current HEAD (e.g., origin/main)
bash eval_ship_gate.sh --save-baseline origin_main

# Compare HEAD vs saved baseline
bash eval_ship_gate.sh --baseline origin_main

# Full paired cycle: save at <ref>, compare HEAD
bash eval_ship_gate.sh --paired origin/main
```

Output: `/tmp/eval_ship_gate_last.txt` (Criterion stdout), `/tmp/eval_ship_gate_summary.json`, plus `target/criterion/` HTML reports. Exit 0 = ship-eligible, 1 = regression, 2 = infra error.

Runtime: ~60-120s per run depending on `SHIP_GATE_MEASURE_SECS` (default 60). Significantly slower than `eval_paired.sh` (~5 min total for paired cycle); reserve for high-stakes keeps.

### `verify_post_experiment.sh` — manual post-experiment validation
Four-layer check: KoalaBear unit tests + WHIR integration + rec_aggregation (type-1 + type-2) + full multisignatures + **proof size invariant** via the `proof_size_check` binary (postcard-serialized type-1 aggregate, N_SIGS=100). Human-triggered, not part of the per-iter loop. Run before requesting external review.

```bash
bash verify_post_experiment.sh                  # run all four layers
bash verify_post_experiment.sh --save-baseline  # save proof size baseline (run once on clean origin/main)
```

Proof size baseline file: `/tmp/lm_proof_size_baseline.txt`. If proof size changes vs baseline, exit 1 with delta + percentage — typically signals a structural change (RATE/folding factor, sponge variant, etc).

### `eval_steady_state.sh` — steady-state measurement tier
Measures proof times at production steady-state (proof 200+) rather than fresh-warm (proofs 1-4). Captures the regime where zk-alloc RSS has plateaued and working-set exceeds L3 — the regime production actually operates in.

```bash
# Standalone with SHAs (builds prove_loop binaries)
bash eval_steady_state.sh --baseline <sha> --candidate <sha>

# With pre-built binaries (skips build, used by auto-chain)
bash eval_steady_state.sh --baseline-bin /tmp/base --candidate-bin /tmp/cand \
  --baseline <sha> --candidate <sha>

# Custom window
bash eval_steady_state.sh --baseline <sha> --candidate <sha> --proofs 300 --measure-last 100
```

Output: `/tmp/eval_steady_state_summary.json`. Exit: 0 = no regression, 1 = regression (>1%, p<0.05), 2 = infra error.

Runtime: ~$((250 * 2 * 2 / 60)) min with defaults (250 proofs × ~2s × 2 sides). Auto-chained on keeps exceeding `STEADY_STATE_THRESHOLD_PCT` (default 2.0%) — does NOT fire on typical sub-2% keeps.

### `config.env` — central thresholds
Edit here, not in individual scripts. Documents what each threshold means and why it's set where it is. Current settings reflect Zen 4 calibration on Hetzner.

## Hibernated scripts (`_legacy/`)

Four scripts retired on 2026-05-13. See `_legacy/README.md` for what they did, why they were hibernated, and how to reactivate. Summary:

- `eval_iai.sh` — instruction-count gate via callgrind. Wrong calibration class for current Poseidon (microarch-sensitive) work. Reactivate for next sumcheck-shape experiment.
- `eval_gate.sh` — broken orchestrator (iai → paired → revert-A/B). Reactivate alongside iai.
- `eval_e2e.sh` — legacy Criterion wrapper. Superseded by `eval_paired.sh`.
- `eval_poseidon.sh` — manual throughput print, no decision logic. Superseded by Criterion poseidon_permute bench.

## Per-iter pipeline (auto-chained on keep)

```
[change committed]
      │
      ▼
correctness.sh                                                       ← agent calls
      │  pass
      ▼
eval_paired.sh                                                       ← agent calls
      │  (env_preflight: governor + load check)
      │  (noise floor: A-vs-A calibration, soft-fail)
      │  (counterbalanced rounds, core-pinned, page-cache-dropped)
      │  (per-round drift abort if drift > DRIFT_ABORT_PCT)
      │
      ├─ discard → revert, next iter
      │
      └─ keep
          │
          ├─ AUTO_CUMULATIVE_ON_KEEP=1 (default)
          │      → eval_cumulative.sh anchors HEAD vs origin/main
          │
          ├─ AUTO_SHIP_GATE_ON_KEEP=1 (default)
          │      → eval_ship_gate.sh --paired origin/main (Criterion confirm)
          │      │
          │      ├─ PASS → keep confirmed
          │      └─ REGRESS → WARNING logged. Inspect, optionally eval_revert_ab.sh
          │
          └─ AUTO_STEADY_STATE_ON_KEEP=1 (default, |Δ| >= 2.0% only)
                 → eval_steady_state.sh (250 proofs, measure last 50)
                 │
                 ├─ no_change / improved → steady-state OK
                 └─ regression → WARNING logged. Fresh-warm may not transfer.
```

Agent-side invocation reduces to:

```bash
# 1. Make the change, commit it

# 2. Correctness
bash ~/zk-autoresearch/harness/leanvm/correctness/correctness.sh || exit 1

# 3. Fast gate (handles env preflight + auto-chain internally)
bash eval_paired.sh
# Exit 0 = keep (auto-chained cumulative + ship-gate already ran)
# Exit 1 = discard (next iter)
# Exit 2 = infra error (env preflight FAIL, drift abort, identical binaries, etc.)
```

The agent does NOT need to remember to call cumulative or ship gate — they auto-fire on keep. To disable for fast iteration: `AUTO_SHIP_GATE_ON_KEEP=0 bash eval_paired.sh`.

## Known gaps (tracked, not blocking)

- **Per-sample interleaving within a round.** Counterbalanced round ordering (odd=base→cand, even=cand→base) eliminates most systematic position bias but does not interleave individual proof samples within a round. Full interleaving (base-proof, cand-proof, ...) would further tighten variance but requires `prove_loop` to support single-proof mode with shared setup. Deferred — counterbalancing + page-cache-drop captures the majority of the benefit. (`eval_ship_gate.sh` gets per-sample interleaving for free via Criterion.)

## Loop orchestration

There is no single orchestrator script — the experiment's program.md tells the agent which scripts to call and in what order. Each experiment can override scripts by providing local replacements in its experiment directory (see `experiment_logs/<project>/<experiment>/`).
