# pw4 attribution — per-keep A/B + drift root cause (Shape B, measurement only)

## Role
You are a measurement researcher. NO source changes, NO commits to leanMultisig source, NO PRs. Your only job is to measure and write a report.

## Hardware
Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). Brain just cleaned the box:
- CPU governor flipped from `powersave` → `performance` (was capping cores at ~3.88 GHz; now hitting 4.8-5.04 GHz)
- 7 stale tmux sessions killed (bench-pw3, bug-hunter-4, jolt-hzn, lm-poseidon-call-sites, lm-profile-hetzner, pw3, zk-alloc-sync)
- Working tree clean, no pw4-poseidon session

Before any measurement, confirm governor:
```
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do cat $c; done | sort -u
```
Should print `performance`. If anything else, stop and escalate.

## Background

The pw4 experiment landed 3 keeps:
- pw4-13 (`3af78c01`): scalar-bind 15 s_hi values across partial rounds + drop sparse_first_row[r][0]=1 identity mul (Tier 1 #3 + #5 bundle)
- pw4-15 (`5118989a`): scalar-bind state across initial full rounds + inline mds_fft butterflies with macro-expanded scalar ops
- pw4-19 (`3c61a81b`): fuse terminal-rounds scalar binding + compress_in_place final add into one chain

Per-iter measured deltas during pw4 (each candidate vs immediate-prior baseline): −1.25%, −2.13%, −2.85% respectively.

Direct HEAD-vs-origin/main paired bench measured cumulative as: **−1.61% on contaminated env (powersave + stale tmux), −1.78% on clean env (performance governor, sessions killed).**

The per-iter deltas DO NOT sum/compound to the cumulative number. Hypothesis: baseline drifted upward across pw4 sessions (warm-time 2.10 → 2.16 → 2.19s), so each iter measured larger deltas than its real contribution.

Your job is to attribute the actual cumulative contribution to each keep, and identify why the baseline drifted.

## Task 1 — Per-keep A/B contribution

Construct three test configurations on top of `origin/main` (c868330c on Hetzner; `git log -1 origin/main` to confirm):

| Config | Composition | Branch |
|---|---|---|
| A | origin/main + pw4-13 only | `attribution-13-2026-05-13` |
| B | A + pw4-15 | `attribution-15-2026-05-13` |
| C | B + pw4-19 | `attribution-19-2026-05-13` |

Build each via `git cherry-pick` from the pw4-2026-05-12 branch (which has all three keeps committed). If a cherry-pick conflicts, resolve minimally and note the resolution in the report. Confirm each candidate compiles + passes correctness (`bash ~/zk-autoresearch/harness/leanmultisig/correctness/correctness.sh`).

Run paired bench for each config vs `origin/main`:
```
bash ~/zk-autoresearch/harness/leanmultisig/scripts/eval_paired.sh --n 5
```
Default workload: prove_loop, 1550 sigs, log_inv_rate=1, fat LTO, zk-alloc, N=5 paired warm proofs. The harness alternates baseline/candidate to control for environmental drift within a single run.

For each config, record:
- delta_pct, p_value, t_stat
- per-round breakdown (the 3-5 round deltas)
- base_avg, cand_avg (raw seconds)

Per-keep contribution:
- pw4-13 = `delta(A vs origin/main)`
- pw4-15 = `delta(B vs origin/main) − delta(A vs origin/main)` (incremental)
- pw4-19 = `delta(C vs origin/main) − delta(B vs origin/main)` (incremental)

Sanity check: sum should be close to the −1.78% cumulative from the contaminated-then-cleaned full-stack measurement. If sum diverges materially (>0.5% gap), discuss possible causes in the report (non-additivity, codegen interactions, etc.).

## Task 2 — Drift root cause attribution

Three candidate causes from the pw4 post-mortem:
1. CPU governor `powersave` — capped cores at ~3.88 GHz under load
2. Stale tmux sessions (6 of them from prior experiments) — cache pressure, scheduler noise, kernel state
3. Thermal throttling — unmeasured during pw4
4. 19-day system uptime — kernel page tables, slab fragmentation, etc.

Measurements to run on the clean env:

### A) Fresh baseline measurement
Re-measure `origin/main` warm-time NOW (clean state). Run `eval_paired.sh --n 5` with both sides = origin/main, or just time a single prove_loop run with N=5 warm proofs. Compare to historical values:
- 2.10s — start of contaminated pw4 (clean-ish state, governor powersave still in effect)
- 2.19s — end of contaminated pw4 (after many runs accumulated cache/scheduler state)
- ? — clean state now (performance governor + no stale tmux)

If clean-now is significantly less than 2.10s, governor was the dominant factor. If close to 2.10s, then stale tmux + cumulative state contributed the 2.10→2.19 creep.

### B) Sustained-load drift test
Run prove_loop in a 30-min loop. Record warm proof time at minute 1, 5, 10, 20, 30. If wall time drifts upward during sustained load on clean env, that's thermal throttling (or some other in-session effect). If stable, the prior creep was governor + cross-session contamination.

Capture during the loop:
```
sensors 2>/dev/null | grep -E "Tctl|Tdie|Package"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | sort -u
uptime
```
Snapshot at the same intervals as the warm-proof timings.

### C) Conclude
Identify the dominant cause. Quantify each contributing factor where you can. If multiple factors were significant, give a rough breakdown ("governor ≈ 60% of the drift, stale tmux ≈ 30%, residual unknown ≈ 10%" or similar).

## Output (Shape B — all artifacts go in `report/`)

`report/per_keep_table.md` — table of per-keep contributions with deltas, p-values, raw seconds, per-round breakdowns
`report/drift_attribution.md` — fresh baseline measurement, sustained-load curve, sensors snapshots, root cause
`report/attribution_report.md` — synthesis: per-keep + drift, plus implications for pw4_2 methodology
`report/raw_gate_logs/` — save the raw `eval_paired.sh` outputs for each config (small files, OK in report/)

## Hard constraints

- **Shape B: no source changes.** You do not modify leanMultisig source. Your branches (`attribution-13-...`, etc.) are constructed via `git cherry-pick` only.
- **No git push.** Brain reviews and decides what (if anything) to push.
- **All output to `report/`** subdirectory of this experiment dir (gitignored per path policy; coordinator rsyncs back to brain).
- **No new optimizations.** If you spot something while reading code, note it in the report as a "future work" bullet. Do not implement.
- **No `cargo bench` shortcuts.** Use the production `eval_paired.sh` only — that's the methodology pw4 ran on.
- **`RUSTFLAGS="-C target-cpu=native"`** always. (eval_paired.sh sets this; verify before each run.)

## Stop
When `attribution_report.md` is written with both per-keep table and drift conclusion. Do NOT chase additional measurements beyond the scope above unless brain explicitly extends scope.
