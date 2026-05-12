# leanMultisig — main + PR #216 paired delta + profiling baseline on macOS M4-M (32 GiB)

## Role

You are a performance investigator running on **macOS Sequoia 15.6.1 on Apple M4 Pro with 32 GiB RAM** (Scaleway M4-M rental). Job: confirm PR #216's e2e delta on the 32 GiB M-series machine. This is a **direct fork of the M4-S 16 GiB experiment** (`profiling_macos_m4pro_pr216_2026-05-12`) — same chip class (M4 Pro Mac16,10), same 7-phase methodology — **with 2× the RAM**. The whole point is to isolate the effect of the 16 GiB pressure ceiling.

You measure. No code changes to leanMultisig.

## Hardware

- Apple **M4 Pro (Mac16,10)**: 10 cores (4 P-core + 6 E-core)
- **32 GiB RAM** — the differentiator vs M4-S 16 GiB. 2× memory headroom.
- 16 KiB native page, NEON 128-bit, ~273 GB/s memory bandwidth, ARMv9 SME
- macOS Sequoia 15.6.1 (build 24G90), Darwin 24.6.0 arm64 (kernel T8132)
- **No `perf`, no CLI PMU.** Profiling stack: `sample`, `xcrun xctrace`, `powermetrics`, `dtrace`.

## Context — the deciding hypothesis

This experiment is the SAME chip silicon as M4-S (`profiling_macos_m4pro_pr216_2026-05-12`) but with 2× RAM. The COMPARISON across these two runs answers a specific open question from the earlier debate (see `brain/report/pw3_debate/` and memory `project_memory_bandwidth_thesis`):

> Does the 16 GiB RAM ceiling absorb part of PR #216's optimization gain via memory pressure effects?

Anchored numbers from prior runs:
- **M2 Pro macOS (16 GiB)** PR #216 delta: −5.05% ± 0.89% (`profiling_macos_m2pro_pr216_2026-05-12`)
- **M2 Asahi Linux (16 GiB)** PR #216 delta: −6.64%
- **Hetzner Zen 4 AVX-512 (64 GiB)** PR #216 delta: −5.58%

**Primary hypothesis (the one to test):** the M4-M 32 GiB delta will be **LARGER (more negative)** than M2 Pro macOS −5.05% on the same workload. The mechanism: at 16 GiB on macOS, the prove_loop working set is competing with macOS background + Scaleway hypervisor for RAM, and some of PR #216's wall-clock gain is being absorbed by reduced pressure. At 32 GiB, that pressure is gone, the optimization lands cleanly.

- **Confirmation:** M4-M Δ ≈ −7 to −8% (the "true" architecture-relative gain, free of pressure ceiling)
- **Refutation:** M4-M Δ ≈ −5% (no headroom effect, 16 GiB wasn't a real ceiling at this workload scale)

**Secondary hypothesis:** main warm-proof wall-clock on 32 GiB should also be lower than on 16 GiB M4-S, again due to less pressure. The PR #216 wall should match the M4-S PR #216 wall MORE CLOSELY than the main walls do (PR #216 is less pressure-sensitive because it does less allocator work per sig).

**Tertiary:** P/E heterogeneity tax on 4P+6E should be the same as M4-S (it's chip-architectural, not RAM-dependent).

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
- ALL experiment outputs go in `experiment_logs/leanMultisig/profiling_macos_m4m32_pr216_2026-05-12/report/`. Every phase output — summary mds, raw txt/xml files, logs, traces. Everything.
- The top dir of the experiment contains `program.md` ONLY. You do not write anything to the top dir.
- `report/` is gitignored. Coordinator rsyncs it to brain at experiment-stop. That's the audit channel.
- Create the `report/` subdir if it doesn't exist: `mkdir -p ~/zk-autoresearch/experiment_logs/leanMultisig/profiling_macos_m4m32_pr216_2026-05-12/report`

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

# 1. main with zk-alloc
(cd ~/zk-autoresearch/leanMultisig && git checkout origin/main)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_main
md5 /tmp/prove_loop_main

# 2. PR #216 with zk-alloc
(cd ~/zk-autoresearch/leanMultisig && git checkout myfork/perf/poseidon-fft-mmo)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_pr216
md5 /tmp/prove_loop_pr216

# 3. main with SYSTEM MALLOC (Apple libsystem — NO zkalloc_global)
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

Confirm allocator banners. If any binary crashes, write findings to `report/phase_0_smoke.md`.

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

**Primary headroom-hypothesis check:** is this delta materially larger than the M4-S 16 GiB delta (will be measured in `profiling_macos_m4pro_pr216_2026-05-12`)? If yes, the 16 GiB pressure ceiling absorbed optimization gain.

## Phase 1b — Paired N=5: zk-alloc vs system malloc (both on origin/main)

The zk-alloc effectiveness measurement. Reference: M2 Pro macOS measured zk-alloc Δ = **−9.24% ± 0.73 pp** at 16 GiB (`experiment_logs/zk-alloc/zkalloc-vs-glibc-macos-m2-2026-05-12/verdict.md`).

**The headroom-on-allocator test:** at 16 GiB, libsystem may be under pressure that zk-alloc avoids; at 32 GiB, pressure is gone and the allocator's relative advantage should SHRINK. Predicted M4-M Δ: less negative than −9.24% (e.g., −5 to −7%). If the M4-M number is still ~−9%, allocator advantage is NOT pressure-driven, it's intrinsic to libsystem's behavior on this workload.

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
- **M2 Pro macOS 16 GiB**: −9.24% (libsystem under pressure?)
- **M4 Pro 16 GiB** (M4-S, parallel experiment): TBD — the same-chip 16 GiB baseline
- **M2 Asahi 16 GiB Linux/glibc**: −3.93%
- **Hetzner 64 GiB Linux/glibc**: +25%

Headline question for Phase 1b on this box: does zk-alloc's macOS advantage SHRINK at 32 GiB, supporting the pressure-driven hypothesis? Or does it hold at ~−9%, indicating the advantage is intrinsic to libsystem's allocation pattern?

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
2. Estimate inclusive Poseidon cycle share — compare to **M2 Pro macOS 52.5% inclusive** and **M4-S 16 GiB** (parallel experiment, TBD). M4-M 32 GiB should match M4-S 16 GiB closely (same chip).
3. Note any symbols that appear on M4-M but not on M2 Pro macOS or M4-S (anything that's specifically a 32 GiB-only effect: less libsystem allocator stalls, fewer page-faults, etc.)

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
- **M2 Pro macOS** (6P+4E split): 18.2% P/E heterogeneity tax
- **M4-S 16 GiB** (same chip as this run, 4P+6E split): TBD — the closest reference
- **M2 Asahi Linux** (with rayon P-affinity hooks): ~13% tax

Expected: M4-M 32 GiB P/E tax should match M4-S 16 GiB closely (same chip, P/E is chip-architectural not RAM-driven). If they diverge, that's a finding.

Write `report/phase_4_pe_breakdown.md`.

## Phase 5 — Cross-machine comparison

Pull reference numbers from:
- Hetzner: `experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/profiling_baseline_report.md`
- M2 Asahi Linux: `experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/profiling_baseline_m2_report.md`
- M2 Pro macOS: `experiment_logs/leanMultisig/profiling_macos_m2pro_pr216_2026-05-12/profiling_macos_m2pro_pr216_report.md`
- **M4 Pro 16 GiB macOS** (the same-chip 16 GiB reference): `experiment_logs/leanMultisig/profiling_macos_m4pro_pr216_2026-05-12/report/profiling_macos_m4pro_pr216_report.md`

Build a cross-machine table with M4-M (32 GiB) as a new column. **The critical comparison is M4-M (32 GiB) vs M4-S/M4 Pro 16 GiB — same chip, different RAM.**

| Metric | Hetzner (Zen 4) | M2 Asahi 16 | M2 Pro macOS 16 | M4 Pro macOS 16 (M4-S) | **M4 Pro macOS 32 (this)** |
|---|---|---|---|---|---|
| PR #216 paired Δ (Phase 1a) | −5.58% | −6.64% | −5.05% ± 0.89 | TBD | **???** |
| **zk-alloc Δ vs sysmalloc** (Phase 1b) | +25% (vs glibc) | −3.93% (vs glibc) | **−9.24% ± 0.73** (vs libsystem) | TBD | **???** |
| prove_loop warm-proof wall (main) | 2.002 s | 2.558 s | 2.50 s | TBD | **???** |
| prove_loop warm-proof wall (PR #216) | 1.890 s | 2.388 s | 2.38 s | TBD | **???** |
| Poseidon inclusive cycle share | ~38% | 57.85% | 52.5% | TBD | **???** |
| P/E heterogeneity tax | n/a | ~13% | 18.2% | TBD | **???** |
| P/E split | 8c/16t SMT | 6P+4E | 6P+4E | 4P+6E | **4P+6E** |
| RAM | 64 GiB | 16 GiB | 16 GiB | 16 GiB | **32 GiB** |
| Memory bandwidth | ~83 GB/s | ~200 GB/s | ~200 GB/s | ~273 GB/s | **~273 GB/s** |

Write `report/phase_5_cross_machine.md`. **Address three specific questions:**

1. **The headroom hypothesis for PR #216:** is M4-M's PR #216 Δ (32 GiB) materially larger than M4-S's PR #216 Δ (16 GiB, same chip)? If yes, 16 GiB on macOS was absorbing optimization gain via memory pressure. If no, the 16 GiB ceiling wasn't real at this workload scale.

2. **The headroom hypothesis for zk-alloc:** is the M4-M zk-alloc-vs-sysmalloc Δ (32 GiB) SHALLOWER than the M2 Pro macOS −9.24% (16 GiB)? If yes, libsystem was struggling under pressure on 16 GiB and zk-alloc was winning the pressure race. If no, zk-alloc's advantage is intrinsic to libsystem's allocation pattern at this workload, regardless of RAM.

3. **The cross-generation gap:** is M4 Pro 16 GiB PR #216 Δ (M4-S) materially different from M2 Pro 16 GiB Δ (−5.05%)? If yes, M4 silicon changes the PR #216 leverage. If no, the optimization is silicon-generation-portable.

These three answers together disentangle three distinct effects (RAM headroom × PR #216, RAM headroom × zk-alloc, chip generation) that the naive cross-platform table conflates.

## Phase 6 — Synthesis report

Write `report/profiling_macos_m4m32_pr216_report.md`:

1. **Headline (two numbers):** Phase 1a PR #216 Δ on 32 GiB vs M4-S 16 GiB and M2 Pro 16 GiB; Phase 1b zk-alloc Δ on 32 GiB vs M2 Pro macOS 16 GiB −9.24%. The headroom-ceiling answer for BOTH optimizations is the primary contribution.
2. Three or four most surprising findings
3. Whether mach-vm path showed any regression (M2 Pro confirmed clean at 16 GiB; verify on M4 Pro 32 GiB)
4. zk-alloc behavior on 32 GiB: confirms no regression, magnitude of speedup vs libsystem, headroom-vs-intrinsic verdict
5. **The PR #216 headroom-ceiling answer** — does the 16 GiB Δ vs 32 GiB Δ gap on the same chip prove memory pressure was absorbing optimization gain?
6. **The zk-alloc headroom-ceiling answer** — does zk-alloc's relative advantage shrink at 32 GiB?
7. Implication for the 1000 XMSS/s M-series macOS target — should we recommend 32 GiB+ as the production target, or is 16 GiB close enough?

## Phase 7 — Draft summary note

Write `report/summary_note.md`: tight 1-page summary — headline numbers (both Phase 1a and 1b), cross-machine table, headroom-ceiling verdict, conclusion. Brain decides whether to surface anywhere; you just draft.

## Stop criterion

All phases (0, 1a, 1b, 2, 3, 4, 5, 6, 7) deliverables exist in `report/`.

## Hard constraints

- **No code changes to leanMultisig.** Read-only investigation.
- **No commits, no pushes.** Shape B per CLAUDE.md. Coordinator rsyncs `report/` to brain at stop.
- **N=5 paired with alternating order** for Phase 1.
- **Memory hygiene via `sudo purge` before each measurement-bearing run.**
- **Tight scope.** This is a fork of the M2 Pro experiment, not a redesign. Run the same phases the same way. If Phase 0 reveals zk-alloc is fundamentally broken on M4 Pro (which would be a real finding — wasn't broken on M2 Pro), stop and write a findings doc; don't try to fix it in this experiment.

## Why this matters

This is the first 32 GiB Apple Silicon measurement we have. Every prior M-series PR #216 measurement was on 16 GiB hardware (M2 Asahi, M2 Pro macOS, M4 Pro macOS/M4-S). The 32 GiB box is what isolates "headroom" from "chip" — a question that was hanging open since the memory-bandwidth-thesis discussion earlier today, and that affects how we frame ship recommendations for production users (who mostly have ≤16 GiB or ≥32 GiB, with sharply different operating points).

Combined with M4-S (same chip, 16 GiB) and M2 Pro macOS (older chip, 16 GiB), this experiment gives a 2×2 (chip × RAM) design that lets the team attribute PR #216 wins cleanly to chip-portability vs RAM-headroom effects.

---
*Fork of `profiling_macos_m4pro_pr216_2026-05-12`. Drafted 2026-05-12 after Scaleway M4-M provisioned manually.*
