# leanMultisig — main + PR #216 paired delta + profiling baseline on macOS M2 Pro

## Role

You are a performance investigator running on **macOS Sequoia 15.6.1 on Apple M2 Pro** (Scaleway M2-L rental). Job: confirm PR #216's e2e delta on the macOS path (we have −6.64% on M2 Asahi already), AND produce a first-pass profiling baseline using macOS-native tools since `perf` doesn't exist here.

You measure. No code changes to leanMultisig.

## Hardware

- Apple M2 Pro (Mac14,12): 10 cores (6 P-core avalanche + 4 E-core blizzard, 6-wide P-decode)
- 16 GiB RAM, 16 KiB native page, NEON 128-bit
- macOS Sequoia 15.6.1 (build 24G90), Darwin 24.6.0 arm64
- **No `perf` tool, no `apple_avalanche_pmu` PMU events from CLI.** Profiling stack: `sample`, `xcrun xctrace`, `powermetrics`, `dtrace`.
- **No MAP_NORESERVE.** zk-alloc's large arena pretouch may behave differently than on Asahi (Asahi needed the raw-syscall fix in 687ec5cc).

## Context — the prediction worth testing

- M2 Asahi PR #216 delta (origin/main vs myfork/perf/poseidon-fft-mmo): **−6.64%** (5 rounds, range −5.59 to −8.81)
- Asahi pre-fix needed cherry-pick of MAP_NORESERVE syscall fix to avoid 120 GB virtual mmap crash on the zk-alloc path
- **Hypothesis:** macOS PR #216 delta is **similar to Asahi** (~−6 to −8%) because (a) both arm64, (b) the NEON instruction mix is the same, (c) PR #216's leverage is mostly the RATE 8→12 sponge rebalance which is architecture-portable
- **Counter-hypothesis:** macOS mach-vm semantics could either help or hurt zk-alloc's pretouch path, materially shifting the baseline numbers. The 12x M1 historical regression (memory: project_zk_alloc_macos_bug) lives here.

## Repo & setup

The setup script `scripts/setup/leanmultisig-macos.sh` has been run before your launch. Verify:

```bash
ls ~/zk-autoresearch
test -d ~/zk-autoresearch/leanMultisig
which cargo rustc
```

Branches:
- `origin/main` → baseline
- `myfork/perf/poseidon-fft-mmo` → PR #216
- Cherry-pick of `687ec5cc` (aarch64 MAP_NORESERVE fix) is **probably not needed on macOS** but verify by trying without it first; if `prove_loop` crashes with mach-vm errors, pick it.

## Phase 0 — Memory hygiene + smoke test

```bash
# Free up memory before benchmarks
sudo purge
```

Build both binaries:

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin && git fetch myfork || (git remote add myfork https://github.com/Barnadrot/leanMultisig.git && git fetch myfork)

cd ~/zk-autoresearch/harness/leanmultisig/bench

# main
(cd ~/zk-autoresearch/leanMultisig && git checkout origin/main)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_main
md5 /tmp/prove_loop_main

# PR #216
(cd ~/zk-autoresearch/leanMultisig && git checkout myfork/perf/poseidon-fft-mmo)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_pr216
md5 /tmp/prove_loop_pr216
```

Smoke test each binary at N=1 (should complete in 2-4 s):

```bash
/tmp/prove_loop_main 1
/tmp/prove_loop_pr216 1
```

If either crashes with `mach_vm_allocate` errors, log it and try the 687ec5cc cherry-pick. If still crashing: write findings to `phase_0_smoke.md` and escalate via `experiment_logs/leanMultisig/profiling_macos_m2pro_pr216_2026-05-12/queue/needs-decision/`.

Save the smoke test wall-clocks to `phase_0_smoke.md`.

## Phase 1 — Paired N=5 main vs PR #216

```bash
# Memory hygiene
sudo purge

# Paired N=5 with alternating order
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
done | tee phase_1_paired.log
```

Save phase_1_paired.log + compute delta per round + mean ± stddev → `phase_1_paired.md`.

**Stop gate:** if mean delta on M2 macOS is OUTSIDE [−12%, −2%] (i.e., far from the Asahi −6.64% reference), flag it in `phase_1_paired.md` headline and proceed — but the discrepancy itself is the finding.

## Phase 2 — Hot symbol attribution via `sample`

```bash
# Launch PR #216 binary, immediately sample it
/tmp/prove_loop_pr216 3 &
PROVE_PID=$!
sleep 1  # let it warm up
sample $PROVE_PID 10 -file phase_2_sample_pr216.txt
wait $PROVE_PID

# Same for main
/tmp/prove_loop_main 3 &
PROVE_PID=$!
sleep 1
sample $PROVE_PID 10 -file phase_2_sample_main.txt
wait $PROVE_PID
```

The `sample` output is a call-tree similar to `perf report --children`. Parse:
1. Identify the top inclusive callers (Poseidon-touching symbols: `compress_mut`, `permute_mut`, `eval_*_full_rounds_16`, `Poseidon16Precompile`, etc.)
2. Estimate inclusive Poseidon cycle share — compare to **Asahi inclusive 57.85%** and the user's prediction of 35-40% (Asahi disproved it upward; macOS verifies cross-OS)
3. Note any symbols that appear on macOS but not Asahi (mach-vm related, libsystem allocator stalls, etc.)

Write `phase_2_hot_symbols.md`.

## Phase 3 — Time Profiler via xctrace (Instruments)

Time Profiler gives clean DWARF-resolved call trees, equivalent to `perf record --call-graph dwarf`.

```bash
xcrun xctrace record \
    --template "Time Profiler" \
    --output phase_3_time_profiler.trace \
    --launch /tmp/prove_loop_pr216 \
    -- 5
# Export top symbols to text
xcrun xctrace export --input phase_3_time_profiler.trace \
    --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' \
    > phase_3_time_profiler.xml 2>&1
```

If xctrace export fails (it's notoriously finicky), fall back to summarizing the sample-based attribution from Phase 2. Write `phase_3_call_tree.md` either way — note the data source used.

## Phase 4 — P/E core breakdown via powermetrics

```bash
sudo powermetrics --samplers cpu_power -i 500 -n 20 \
    --hide-cpu-duty-cycle --show-process-coalition --show-process-energy \
    > phase_4_powermetrics.txt 2>&1 &
POWER_PID=$!
sleep 1
/tmp/prove_loop_pr216 5
kill $POWER_PID 2>/dev/null || true
wait $POWER_PID 2>/dev/null || true
```

Parse: P-core vs E-core utilization, energy per cluster, did rayon land work on E-cores? Compare to Asahi's findings (~13% P/E heterogeneity tax).

Write `phase_4_pe_breakdown.md`.

## Phase 5 — Comparison table macOS vs Asahi vs Hetzner

Pull the Asahi numbers from `experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/profiling_baseline_m2_report.md` and Hetzner from `experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/profiling_baseline_report.md`.

Build a cross-machine table:

| Metric | Hetzner (Zen 4 + AVX-512) | M2 Asahi Linux | M2 macOS |
|---|---|---|---|
| PR #216 paired Δ | −5.58% | −6.64% | ??? |
| prove_loop main wall (5 iters) | ??? | 2.65 s | ??? |
| Poseidon inclusive cycle share | ~38% | 57.85% | ??? |
| IPC | ??? | 2.93 weighted | ??? (limited PMU) |
| P/E heterogeneity tax | n/a | ~13% | ??? |

Write `phase_5_cross_machine.md`.

## Phase 6 — Synthesis report

`profiling_macos_m2pro_pr216_report.md`:

1. Headline: macOS Δ vs Asahi reference
2. Three or four most surprising findings
3. Whether mach-vm path showed any regression (relevant for #41)
4. Whether zk-alloc worked at all (relevant for #59) — confirm no crashes, no 12x slowdown
5. P/E scheduling tax on macOS (different from Asahi's rayon affinity result)
6. Implication for the 1000 XMSS/s M2 macOS target

## Phase 7 — Draft pr_body.md

Tight pr_body summarizing methodology + numbers. Brain submits or files. Do NOT push.

## Stop criterion

All phase_0 through phase_7 deliverables exist in this experiment directory.

## Hard constraints

- **No code changes to leanMultisig.** Read-only investigation.
- **N=5 paired with alternating order** for Phase 1.
- **Memory hygiene via `sudo purge` before each measurement-bearing run.**
- **No PR push.** Brain handles submission decisions.
- **Commit-per-phase.** Resilient to interruption.
- **Tight scope.** This is the "quick" cross-OS comparison experiment, not a deep dive. If Phase 0 reveals zk-alloc is fundamentally broken on macOS, stop and write a findings doc — don't try to fix it in this experiment.

## Why this matters

This is the first measurement of leanMultisig on the production target OS (macOS Sequoia). All prior macOS data is from Justin's irregular access on M1 16 GiB. This experiment establishes a defensible baseline for the macOS path and confirms whether PR #216 delivers on the production target.

---
*Drafted 2026-05-12 after Scaleway M2-L provisioned and Asahi reference numbers were locked in.*
