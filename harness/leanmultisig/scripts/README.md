# leanMultisig autoresearch — gate scripts

All scripts are leanMultisig-specific. They assume:
- leanMultisig repo at `~/zk-autoresearch/leanMultisig`
- bench crate at `~/zk-autoresearch/harness/leanmultisig/bench`
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
Paired prove_loop bench between two git refs. Builds both binaries (fat LTO, zk-alloc, `RUSTFLAGS=-C target-cpu=native`), runs N alternating rounds, computes Welch's t-test on warm-proof samples, decides keep/discard.

```bash
bash eval_paired.sh                                   # HEAD~1 vs HEAD, N=1
bash eval_paired.sh --baseline <ref> --candidate <ref> --n <int>
bash eval_paired.sh --n 5                             # 5 paired rounds
```

Output: `/tmp/eval_paired_summary.json` (full JSON). Exit: 0 keep, 1 discard, 2 infra error.

Decision rule (`config.env`): `delta_pct <= -KEEP_THRESHOLD_PCT AND p_value < 0.01`. Default threshold 1.0%.

**Methodology caveats** (per pw4 audit 2026-05-13):
- Default baseline is `HEAD~1` (rolling). Per-iter deltas are marginal contributions, NOT cumulative. After a keep, use `eval_cumulative.sh` to anchor against `origin/main` for interpretable wall-clock-vs-main numbers.
- Block-design alternation within rounds: each round runs the full baseline binary first, then the full candidate. With many rounds (N >= 5), drift is averaged out; with N=1 the block design is exposed to minute-scale drift. Use `--n 5` or higher for keep-decisions on borderline cases.

### `eval_cumulative.sh` — cumulative anchor measurement
Wraps `eval_paired.sh` with `--baseline=origin/main --candidate=HEAD --n=5`. Runs `env_preflight.sh` first. Designed to be invoked automatically after a keep lands, or manually after any structural change, to record an interpretable cumulative-vs-main number.

```bash
bash eval_cumulative.sh                               # origin/main vs HEAD, N=5
bash eval_cumulative.sh --anchor <tag> --n 7          # different anchor or sample size
EXPERIMENT_DIR=experiment_logs/leanMultisig/foo bash eval_cumulative.sh   # archives to <dir>/report/cumulative_<ts>.json
```

Output: `/tmp/eval_cumulative_summary.json` + optional archived copy under `EXPERIMENT_DIR/report/`.

### `eval_revert_ab.sh` — marginal-keep confirmation (optional)
After a kept change, applies a temporary revert commit on top of HEAD and runs paired A/B. Expected: reverting reproduces at least `MIN_REPRODUCE_FRACTION × claim_pct` of the claimed improvement (default 50%). If not, the keep is a noise rider and the caller must unwind.

```bash
bash eval_revert_ab.sh 1.2     # claim_pct = 1.2% (magnitude of the keep being confirmed)
```

Exit: 0 confirmed, 1 noise rider, 2 infra error. Use when the kept delta is close to the threshold (within ~2x).

### `verify_post_experiment.sh` — manual post-experiment validation
Layered correctness check (cargo test on `mt-koala-bear`, `mt-whir`, `rec_aggregation`, full `test_multisignatures`). Human-triggered, not part of the per-iter loop. Run before requesting external review.

```bash
bash verify_post_experiment.sh
```

### `config.env` — central thresholds
Edit here, not in individual scripts. Documents what each threshold means and why it's set where it is. Current settings reflect Zen 4 calibration on Hetzner.

## Hibernated scripts (`_legacy/`)

Four scripts retired on 2026-05-13. See `_legacy/README.md` for what they did, why they were hibernated, and how to reactivate. Summary:

- `eval_iai.sh` — instruction-count gate via callgrind. Wrong calibration class for current Poseidon (microarch-sensitive) work. Reactivate for next sumcheck-shape experiment.
- `eval_gate.sh` — broken orchestrator (iai → paired → revert-A/B). Reactivate alongside iai.
- `eval_e2e.sh` — legacy Criterion wrapper. Superseded by `eval_paired.sh`.
- `eval_poseidon.sh` — manual throughput print, no decision logic. Superseded by Criterion poseidon_permute bench.

## Recommended invocation pattern (per-iter)

```bash
# 1. Verify env is healthy before any measurement window starts
bash env_preflight.sh || exit 1

# 2. Make the change, commit it

# 3. Run correctness gate (separate crate, see harness/leanmultisig/correctness/)
bash ~/zk-autoresearch/harness/leanmultisig/correctness/correctness.sh

# 4. Run the wall-clock gate
bash eval_paired.sh
EXIT=$?

# 5. On keep, anchor cumulative against origin/main
if [[ $EXIT -eq 0 ]]; then
  bash eval_cumulative.sh
fi
```

## Known gaps (tracked, not blocking)

- **Per-sample alternation inside a round.** Current eval_paired.sh runs the full baseline binary first then full candidate within each round. Per-sample interleaving (base-proof, cand-proof, base-proof, cand-proof, ...) would tighten the variance further. Requires modifying `prove_loop` to support single-proof mode. Tracked for pw4_2 methodology work.
- **Auto-recheck on keep inside eval_paired.sh.** Currently the recommendation is "run eval_cumulative manually after keep." Could be folded into eval_paired.sh as a side-effect on keep decisions. Tracked.
- **Criterion-based slow-tier gate.** For high-stakes keeps (e.g., ship gate before opening PRs), a Criterion bench in `harness/leanmultisig/bench` with bootstrap CIs would tighten the inference further. Tracked as a separate workstream.

## Loop orchestration

There is no single orchestrator script — the experiment's program.md tells the agent which scripts to call and in what order. Each experiment can override scripts by providing local replacements in its experiment directory (see `experiment_logs/<project>/<experiment>/`).
