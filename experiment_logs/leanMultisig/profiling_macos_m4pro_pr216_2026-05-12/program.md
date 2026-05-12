# leanMultisig — main + PR #216 paired delta + profiling baseline on macOS M4 Pro

## Role

You are a performance investigator running on **macOS Sequoia 15.6.1 on Apple M4 Pro** (Scaleway M4-S rental). Job: confirm PR #216's e2e delta on M4 Pro macOS. This is a **direct fork of the M2 Pro experiment** (`profiling_macos_m2pro_pr216_2026-05-12`) — same 7-phase methodology, same tooling, same reporting structure. Produce numbers we can drop directly into the cross-machine table alongside M2 Pro.

You measure. No code changes to leanMultisig.

## Hardware

- Apple **M4 Pro (Mac16,10)**: **10 cores (4 P-core + 6 E-core)** — note this is FLIPPED from M2 Pro which has 6P+4E. Different rayon scheduling behavior expected.
- 16 GiB RAM, 16 KiB native page, NEON 128-bit
- **~273 GB/s memory bandwidth** (vs M2 Pro's 200 GB/s) — newer LPDDR5X
- **ARMv9 SME (Scalable Matrix Extension)** available — first M-series chip with SME, may be relevant for future Poseidon work but NOT in the scope of this experiment
- macOS Sequoia 15.6.1 (build 24G90), Darwin 24.6.0 arm64 (kernel T8132)
- **No `perf` tool, no `apple_avalanche_pmu` PMU events from CLI.** Profiling stack: `sample`, `xcrun xctrace`, `powermetrics`, `dtrace`.
- **No MAP_NORESERVE.** zk-alloc's large arena pretouch is fine on macOS (M2 Pro experiment confirmed; M4 Pro should behave the same).

## Context — the predictions worth testing

Anchored numbers we want to compare against:
- **M2 Asahi PR #216 delta:** −6.64% (5 rounds, range −5.59 to −8.81)
- **M2 Pro macOS PR #216 delta:** −5.05% ± 0.89% (measured 2026-05-12, source: `experiment_logs/leanMultisig/profiling_macos_m2pro_pr216_2026-05-12/`)
- **Hetzner Zen 4 AVX-512 PR #216 delta:** −5.58%

**Primary hypothesis for M4 Pro:** delta similar to M2 Pro macOS (~−5 to −7%). PR #216's leverage is the RATE 8→12 sponge rebalance, which is architecture-portable; same NEON, same macOS path.

**Secondary hypothesis (worth testing):** M4 Pro's 4P+6E split shifts the rayon P/E heterogeneity tax. M2 Pro macOS measured 18.2% tax; M4 Pro with MORE E-cores and FEWER P-cores may show HIGHER tax (more work on slower cores) — or LOWER (M4 E-cores are individually closer to P-core performance than M2 generation). Empirical question.

**Tertiary observation worth flagging:** M4 has ARMv9 SME — first M-series chip with the matrix coprocessor. Out of scope for this experiment but flag if any SME usage shows up unexpectedly in the profile (`_sme_*` symbols, unusual matrix-coprocessor instructions).

## Repo & setup

The setup script `scripts/setup/leanmultisig-macos.sh` has been run before your launch (Xcode CLT preinstalled, brew, Rust, tmux, gh, claude, repos cloned, leanMultisig pre-built). Coordinator has already checked out the experiment branch. Verify:

```bash
ls ~/zk-autoresearch
test -d ~/zk-autoresearch/leanMultisig
which cargo rustc claude
git -C ~/zk-autoresearch rev-parse --abbrev-ref HEAD   # should be the experiment branch, NOT 'main'
```

Branches in leanMultisig (read-only):
- `origin/main` → baseline
- `myfork/perf/poseidon-fft-mmo` → PR #216

## Agent git protocol — Shape B (read-only profiling) per CLAUDE.md

This is a **read-only profiling experiment.** Do NOT commit anything. No `git add`, no `git commit`, no `git push`.

**Path policy (mechanical, no judgment required):**
- ALL experiment outputs go in `experiment_logs/leanMultisig/profiling_macos_m4pro_pr216_2026-05-12/report/`. Every phase output — summary mds, raw txt/xml files, logs, traces. Everything.
- The top dir of the experiment contains `program.md` ONLY. You do not write anything to the top dir.
- `report/` is gitignored. Coordinator rsyncs it to brain at experiment-stop. That's the audit channel.
- Create the `report/` subdir if it doesn't exist: `mkdir -p ~/zk-autoresearch/experiment_logs/leanMultisig/profiling_macos_m4pro_pr216_2026-05-12/report`

## Phase 0 — Memory hygiene + smoke test

```bash
# Free up memory before benchmarks
sudo purge
```

Build THREE binaries (PR #216 with zkalloc, main with zkalloc, main with system malloc):

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin && git fetch myfork || (git remote add myfork https://github.com/Barnadrot/leanMultisig.git && git fetch myfork)

cd ~/zk-autoresearch/harness/leanmultisig/bench

# 1. main with zk-alloc (for Phase 1a baseline + Phase 1b zkalloc binary)
(cd ~/zk-autoresearch/leanMultisig && git checkout origin/main)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_main
md5 /tmp/prove_loop_main

# 2. PR #216 with zk-alloc (for Phase 1a PR-side)
(cd ~/zk-autoresearch/leanMultisig && git checkout myfork/perf/poseidon-fft-mmo)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_pr216
md5 /tmp/prove_loop_pr216

# 3. main with SYSTEM MALLOC (Apple libsystem — NO zkalloc_global feature)
(cd ~/zk-autoresearch/leanMultisig && git checkout origin/main)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop
cp target/release/prove_loop /tmp/prove_loop_sysmalloc
md5 /tmp/prove_loop_sysmalloc
```

Smoke test each binary at N=1 (should complete in 2-4 s):

```bash
/tmp/prove_loop_main 1
/tmp/prove_loop_pr216 1
/tmp/prove_loop_sysmalloc 1
```

Confirm allocator banners: `prove_loop_main` and `prove_loop_pr216` should print `zkalloc_global — #[global_allocator] mode`; `prove_loop_sysmalloc` should NOT (uses Apple libsystem).

If any binary crashes with `mach_vm_allocate` errors, log it. Write findings to `report/phase_0_smoke.md`.

## Phase 1a — Paired N=5: main vs PR #216 (both with zk-alloc)

```bash
sudo purge

ROUNDS=5
ITERS=5
for r in $(seq 1 $ROUNDS); do
    if [ $((r % 2)) -eq 1 ]; then ORDER="main first"; A=/tmp/prove_loop_main; B=/tmp/prove_loop_pr216
    else                          ORDER="pr216 first"; A=/tmp/prove_loop_pr216; B=/tmp/prove_loop_main
    fi
    echo "=== Round $r ($ORDER) ==="
    A_TIME=$(/usr/bin/time -p "$A" $ITERS 2>&1 | awk '/real/{print $2}')
    sleep 1
    B_TIME=$(/usr/bin/time -p "$B" $ITERS 2>&1 | awk '/real/{print $2}')
    echo "A: $A_TIME, B: $B_TIME"
done | tee report/phase_1a_pr216_paired.log
```

Save log + compute delta per round + mean ± stddev → `report/phase_1a_pr216_paired.md`.

**Stop gate:** if mean delta is OUTSIDE [−12%, −2%] (vs M2 Pro macOS reference −5.05% and Asahi −6.64%), flag it in the headline and proceed — but the discrepancy itself is the finding.

## Phase 1b — Paired N=5: zk-alloc vs system malloc (both on origin/main)

This is the zk-alloc effectiveness measurement. Same methodology as Phase 1a, different binary pair. Reference: M2 Pro macOS measured zk-alloc Δ = **+9.24% ± 0.73 pp** on this workload (source: `experiment_logs/zk-alloc/zkalloc-vs-glibc-macos-m2-2026-05-12/verdict.md`).

```bash
sudo purge

ROUNDS=5
ITERS=5
for r in $(seq 1 $ROUNDS); do
    if [ $((r % 2)) -eq 1 ]; then ORDER="sysmalloc first"; A=/tmp/prove_loop_sysmalloc; B=/tmp/prove_loop_main
    else                          ORDER="zkalloc first"; A=/tmp/prove_loop_main; B=/tmp/prove_loop_sysmalloc
    fi
    echo "=== Round $r ($ORDER) ==="
    A_TIME=$(/usr/bin/time -p "$A" $ITERS 2>&1 | awk '/real/{print $2}')
    sleep 1
    B_TIME=$(/usr/bin/time -p "$B" $ITERS 2>&1 | awk '/real/{print $2}')
    echo "A: $A_TIME, B: $B_TIME"
done | tee report/phase_1b_zkalloc_paired.log
```

Compute Δ as `(zkalloc − sysmalloc) / sysmalloc`. Negative = zk-alloc faster.

Save log + per-round table + mean ± stddev → `report/phase_1b_zkalloc_paired.md`. Compare to:
- **M2 Pro macOS** (16 GiB): −9.24% (zk-alloc speedup over libsystem)
- **M2 Asahi Linux** (16 GiB): −3.93% (zk-alloc speedup over glibc)
- **Hetzner Zen 4** (Linux glibc): +25%
- (M4-M 32 GiB will be measured separately in `profiling_macos_m4m32_pr216_2026-05-12`; comparing 16 GiB to 32 GiB on the same chip is the headroom-ceiling test)

Headline question for Phase 1b: does zk-alloc deliver the same +9-10% on M4 Pro macOS as on M2 Pro macOS, or does the newer chip's faster compute / different memory subsystem change the allocator's relative win?

## Phase 2 — Hot symbol attribution via `sample`

```bash
# Launch PR #216 binary, immediately sample it
/tmp/prove_loop_pr216 3 &
PROVE_PID=$!
sleep 1  # let it warm up
sample $PROVE_PID 10 -file report/phase_2_sample_pr216.txt
wait $PROVE_PID

# Same for main
/tmp/prove_loop_main 3 &
PROVE_PID=$!
sleep 1
sample $PROVE_PID 10 -file report/phase_2_sample_main.txt
wait $PROVE_PID
```

The `sample` output is a call-tree similar to `perf report --children`. Parse:
1. Identify the top inclusive callers (Poseidon-touching symbols: `compress_mut`, `permute_mut`, `eval_*_full_rounds_16`, `Poseidon16Precompile`, etc.)
2. Estimate inclusive Poseidon cycle share — compare to **M2 Pro macOS 52.5% inclusive** (the closest baseline) and **M2 Asahi 57.85%** (Linux on same generation chip family). M4 Pro is expected close to M2 Pro macOS.
3. Note any symbols that appear on M4 Pro but not on M2 Pro macOS (`_sme_*`, anything M4-specific from ARMv9 extensions, libsystem allocator stalls)

Write `report/phase_2_hot_symbols.md`.

## Phase 3 — Time Profiler via xctrace (Instruments)

Time Profiler gives clean DWARF-resolved call trees, equivalent to `perf record --call-graph dwarf`.

```bash
xcrun xctrace record \
    --template "Time Profiler" \
    --output report/phase_3_time_profiler.trace \
    --launch /tmp/prove_loop_pr216 \
    -- 5
# Export top symbols to text
xcrun xctrace export --input report/phase_3_time_profiler.trace \
    --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' \
    > report/phase_3_time_profiler.xml 2>&1
```

If xctrace export fails (it's notoriously finicky), fall back to summarizing the sample-based attribution from Phase 2. Write `report/phase_3_call_tree.md` either way — note the data source used.

## Phase 4 — P/E core breakdown via powermetrics

```bash
sudo powermetrics --samplers cpu_power -i 500 -n 20 \
    --hide-cpu-duty-cycle --show-process-coalition --show-process-energy \
    > report/phase_4_powermetrics.txt 2>&1 &
POWER_PID=$!
sleep 1
/tmp/prove_loop_pr216 5
kill $POWER_PID 2>/dev/null || true
wait $POWER_PID 2>/dev/null || true
```

Parse: P-core vs E-core utilization, energy per cluster, did rayon land work on E-cores? Compare to:
- **M2 Pro macOS** (6P+4E split): 18.2% P/E heterogeneity tax (closest reference)
- **M2 Asahi Linux** (with rayon P-affinity hooks): ~13% tax

M4 Pro has flipped P/E split (4P+6E) — primary question for Phase 4 is whether the tax goes UP (more E-cores = more slow-tail work) or DOWN (M4 E-cores closer to P-core performance).

Write `report/phase_4_pe_breakdown.md`.

## Phase 5 — Cross-machine comparison

Pull reference numbers from:
- Hetzner: `experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/profiling_baseline_report.md`
- M2 Asahi Linux: `experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/profiling_baseline_m2_report.md`
- **M2 Pro macOS** (this experiment's parent): `experiment_logs/leanMultisig/profiling_macos_m2pro_pr216_2026-05-12/profiling_macos_m2pro_pr216_report.md`

Build a cross-machine table with M4 Pro as a new column:

| Metric | Hetzner (Zen 4 + AVX-512) | M2 Asahi Linux | M2 Pro macOS | **M4 Pro macOS (this)** |
|---|---|---|---|---|
| PR #216 paired Δ (Phase 1a) | −5.58% | −6.64% | −5.05% ± 0.89 | **???** |
| **zk-alloc Δ vs sysmalloc** (Phase 1b) | +25% (vs glibc) | −3.93% (vs glibc) | **−9.24% ± 0.73** (vs libsystem) | **???** (vs libsystem) |
| prove_loop warm-proof wall (main) | 2.002 s | 2.558 s | 2.50 s | **???** |
| prove_loop warm-proof wall (PR #216) | 1.890 s | 2.388 s | 2.38 s | **???** |
| Poseidon inclusive cycle share | ~38% | 57.85% | 52.5% | **???** |
| IPC | 0.91 weighted | 2.93 weighted | not CLI-measurable | **not CLI-measurable** |
| P/E heterogeneity tax | n/a (homogeneous SMT) | ~13% (P-affinity hooks) | 18.2% | **???** |
| P/E split | 8c/16t SMT | 6P+4E | 6P+4E | **4P+6E** |
| Memory bandwidth (peak) | ~83 GB/s | ~200 GB/s | ~200 GB/s | **~273 GB/s** |

Write `report/phase_5_cross_machine.md`. **Two specific questions to address:**
1. **Does the P/E flip (4P+6E vs 6P+4E) change the heterogeneity tax?** Compare to M2 Pro macOS 18.2%.
2. **Does the M4 chip generation change zk-alloc's relative win over libsystem?** M2 Pro macOS showed −9.24%; M4 Pro on same OS may differ if libsystem behavior or compute speed shifts the slice.

## Phase 6 — Synthesis report

Write `report/profiling_macos_m4pro_pr216_report.md`:

1. **Headline numbers:** Phase 1a PR #216 Δ AND Phase 1b zk-alloc Δ on M4 Pro macOS, vs M2 Pro macOS reference (−5.05% and −9.24%)
2. Three or four most surprising findings
3. Whether mach-vm path showed any regression (M2 Pro confirmed clean; verify on M4 Pro)
4. zk-alloc behavior on M4 Pro: confirms no regression, magnitude of speedup vs libsystem
5. **P/E scheduling tax on M4 Pro vs M2 Pro** (the 4P+6E vs 6P+4E flip — primary secondary-hypothesis finding)
6. Any SME-related symbols or instructions surfaced in the profile (tertiary hypothesis)
7. Implication for the 1000 XMSS/s M-series macOS target

## Phase 7 — Draft summary note

Write `report/summary_note.md`: tight 1-page summary suitable for sharing — headline numbers (both Phase 1a and 1b), cross-machine table, conclusion. Brain decides whether to surface anywhere; you just draft.

## Stop criterion

All phases (0, 1a, 1b, 2, 3, 4, 5, 6, 7) deliverables exist in `report/`.

## Hard constraints

- **No code changes to leanMultisig.** Read-only investigation.
- **No commits, no pushes.** Shape B per CLAUDE.md. Coordinator rsyncs `report/` to brain at stop.
- **N=5 paired with alternating order** for Phase 1.
- **Memory hygiene via `sudo purge` before each measurement-bearing run.**
- **Tight scope.** This is a fork of the M2 Pro experiment, not a redesign. Run the same phases the same way. If Phase 0 reveals zk-alloc is fundamentally broken on M4 Pro (which would be a real finding — wasn't broken on M2 Pro), stop and write a findings doc; don't try to fix it in this experiment.

## Why this matters

M4 Pro is the newest Apple Silicon generation. PR #216 on M4 Pro tells us whether the optimization transports forward to the production target hardware Justin's users will run. The P/E flip (4P+6E vs 6P+4E) is a real architectural change between generations — measuring its impact on rayon scheduling is the secondary contribution of this run. Combined with the M2 Pro reference, this gives us a 2-point trajectory in the Apple Silicon Pro line that the team can extrapolate to M3 Pro / M5 Pro decisions.

---
*Fork of `profiling_macos_m2pro_pr216_2026-05-12`. Drafted 2026-05-12 after Scaleway M4-S provisioned by auto-watcher.*
