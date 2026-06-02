# leanMultisig — Comprehensive profiling baseline (M2 Asahi aarch64)

## Role

You are a performance investigator. Your job: produce a comprehensive profiling baseline of `leanMultisig prove_loop` on Apple Silicon M2 / Asahi Linux, using all 7 methodology variants (adapted for Apple Silicon's PMU limitations). Companion to the Hetzner baseline experiment (`profiling_baseline_hetzner_2026-05-11`).

You do NOT optimize. You measure, analyze, write up.

## Hardware

Apple Silicon M2 / Asahi Fedora 42, kernel 6.14.2-401.asahi.fc42.aarch64+16k:
- 10 cores: 6 P-core (avalanche, 8-wide decode, 128 KiB L1D, ~330-entry ROB) + 4 E-core (blizzard, 3-wide decode, 64 KiB L1D)
- 16 GiB RAM + 8 GiB swap (cycle swap + drop caches before benchmarks)
- 16 KiB native page size, 32 MiB THP
- NEON 128-bit SIMD only (no AVX-512, no AMX, no Metal)
- **PMU limitations**: cycles, instructions, branches, branch-misses exposed via apple_avalanche_pmu / apple_blizzard_pmu. **NO cache-references, NO cache-misses, NO LLC events, NO dTLB events.** Memory-side hardware counters are NOT available on this PMU. The Phase 5 hardware-counter step on Hetzner will produce richer data than the M2 equivalent.

## Context — the user's prediction worth testing

User-side prediction (worth testing explicitly): **Poseidon's true cycle share is 35-40%, not the 24.20% today's counter-based call-sites experiment reported.** Reasoning: counter-based attribution counts invocations, but the actual cycles get attributed by perf to whatever symbol the instruction pointer is in at sample time. **Inlined Poseidon cycles inside WHIR helpers, rayon bridges, sumcheck product computation, MLE eval, etc. would be attributed to those parent symbols, not to Poseidon.** Today's 24.20% is a floor.

The hierarchical call-graph attribution in Phase 1 catches this directly. Report whether the prediction holds.

## Baseline numbers from today (re-confirm before Phase 1)

Measured 2026-05-11 on M2 (clean memory state, N=5 paired):
- Glibc baseline: 2.7197 s avg warm proof
- zk-alloc baseline: 2.5581 s avg warm proof (Δ = −5.94%)
- IPC measured via `perf stat`: 3.72 P-core / 1.87 E-core / **2.93 weighted total**

Re-confirm these in Phase 0 before any other measurement.

## Repo & setup

| Repo | Path on M2 | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | branch from `origin/main` as `profile/baseline-m2-2026-05-11` |
| Brendan Gregg FlameGraph tools | `~/zk-autoresearch/tools/FlameGraph` if missing | clone if needed |

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout origin/main
git checkout -b profile/baseline-m2-2026-05-11

mkdir -p ~/zk-autoresearch/tools
test -d ~/zk-autoresearch/tools/FlameGraph || \
  git clone https://github.com/brendangregg/FlameGraph ~/zk-autoresearch/tools/FlameGraph
```

Build with debuginfo:

```bash
cd ~/zk-autoresearch/harness/leanmultisig/bench
RUSTFLAGS="-C target-cpu=native -C debuginfo=2" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_profile
```

## Phase 0 — Memory hygiene + baseline re-confirm

```bash
# Memory hygiene
SWAP_USED=$(free | awk '/^Swap:/{print $3}')
MEM_USED=$(free | awk '/^Mem:/{print $3}')
MEM_TOTAL=$(free | awk '/^Mem:/{print $2}')
if [ "$SWAP_USED" -gt 100000 ] || [ "$MEM_USED" -gt $((MEM_TOTAL * 75 / 100)) ]; then
    sudo sync && sudo swapoff -a && sudo swapon -a
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
fi

# IPC re-confirm
perf stat -e apple_avalanche_pmu/cycles/,apple_blizzard_pmu/cycles/,apple_avalanche_pmu/instructions/,apple_blizzard_pmu/instructions/,branches,branch-misses \
    /tmp/prove_loop_profile 3 \
    2> experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/phase_0_ipc_reconfirm.txt
```

Confirm 2.93 weighted IPC reproduces. If not, debug environment.

## The 7 methodology variants — adapted for Apple Silicon

### Phase 1 — Hierarchical call-graph attribution (THE LOAD-BEARING PHASE)

```bash
perf record -F 997 --call-graph dwarf -o /tmp/perf_m2.data -- /tmp/prove_loop_profile 3
perf report -i /tmp/perf_m2.data --stdio --no-children --max-stack=20 > \
  experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/perf_leaf.txt
perf report -i /tmp/perf_m2.data --stdio --children --max-stack=20 > \
  experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/perf_callgraph.txt
```

**This is the most important measurement of the experiment.** It directly tests the user's prediction that Poseidon is 35-40%, not 24.20%.

For the inclusive-attribution report (`perf_callgraph.txt`):
1. Sum every call path whose stack contains `compress_mut`, `permute_mut`, `eval_2_full_rounds_16`, `eval_last_2_full_rounds_16`, `Poseidon16Precompile::eval`, `mt_symetric::sponge`, `slice_hash_rtl`, or any other Poseidon-touching symbol.
2. Report total cycles attributed to ANY ancestor in the call stack that touches Poseidon — that's the true total Poseidon cycle share.
3. Compare to the leaf-attribution total (~22-24% expected, matching Hetzner pattern).

Specifically, identify:
- True Poseidon total (inclusive) — predict 35-40% per user; report measured
- Per-call-site inclusive cycle attribution for the top 10 inclusive-Poseidon paths
- Where `rayon::iter::plumbing::bridge_producer_consumer::helper` rolls up to (its true parent)
- Whether any non-Poseidon subsystem turns out to be dominant when inclusive-summed

Save findings to `phase_1_callgraph_findings.md`. The headline answer to the user's prediction goes in the first sentence.

### Phase 2 — Flamegraph

```bash
perf script -i /tmp/perf_m2.data > /tmp/perf_script_m2.out
~/zk-autoresearch/tools/FlameGraph/stackcollapse-perf.pl /tmp/perf_script_m2.out > /tmp/perf_collapsed_m2.txt
~/zk-autoresearch/tools/FlameGraph/flamegraph.pl /tmp/perf_collapsed_m2.txt > \
  experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/flamegraph.svg
```

Identify top 3 hot ridges. Write `phase_2_flamegraph_findings.md` (2-3 sentences per ridge). The flamegraph is also the artifact the team can pass to outside collaborators (Justin, Thomas, Emile) for cross-team discussion.

### Phase 3 — Per-symbol line-level annotation

For top 8 symbols by inclusive attribution from Phase 1:

```bash
perf annotate -i /tmp/perf_m2.data --stdio --no-source --symbol "<demangled>" > \
  experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/annotate_<short>.txt
```

For `compress_mut`-equivalent symbols on aarch64 (NEON path): which instructions dominate? Look for repeated patterns of multiply-accumulate, vpermq/vrev, lookup-style index ops, fmls/fmla (fused multiply-subtract/add). The aarch64 instruction mix tells you what's binding the latency chain on M2 (different from Hetzner's AVX-512 binding).

`phase_3_annotate_summary.md` writeup.

### Phase 4 — Differential profile (serial vs parallel)

```bash
RAYON_NUM_THREADS=1 /usr/bin/time -v /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/phase_4_serial.txt
/usr/bin/time -v /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/phase_4_parallel.txt
```

Compute:
- Wall-clock speedup from rayon (parallel time / serial time)
- True rayon scheduling overhead = (serial cycles) − (parallel cycles / NUM_THREADS)
- If serial is much slower than 10× parallel: rayon is delivering meaningful parallelism. If close to 10×: rayon is at the parallel ceiling. If under 5×: rayon is scheduling-bound or there's load imbalance.

Apple Silicon's heterogeneous P/E cores complicate this — rayon doesn't natively know about P-core vs E-core scheduling, so some work lands on E-cores and runs at half the IPC. Note this in the analysis.

`phase_4_rayon_decomposition.md`.

### Phase 5 — Hardware counters (limited set on Apple Silicon)

```bash
perf stat -e cycles,instructions,branches,branch-misses,apple_avalanche_pmu/cycles/,apple_avalanche_pmu/instructions/,apple_blizzard_pmu/cycles/,apple_blizzard_pmu/instructions/ \
    /tmp/prove_loop_profile 3 \
    2> experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/phase_5_hw_counters.txt
```

**Limitation:** no cache or TLB counters on this PMU. We can only classify on branch prediction + IPC.

Compute:
- IPC P-core, IPC E-core, weighted total
- Branch misprediction rate
- P-core vs E-core cycle share (what fraction of cycles ran on which core type)

Classify the workload on the limited PMU:
- If IPC > 2 and branch-miss rate < 1%: compute-bound, fully utilizing the wide OOO
- If IPC < 1 and branch-miss rate < 1%: latency-bound (dependency chains)
- If branch-miss rate > 1%: branch-bound

For memory/cache bottleneck classification, defer to the differential / synthetic-stress probe. Note the gap explicitly in the writeup — the team has cache/TLB hardware-counter data from Hetzner; M2 must rely on indirect inference.

`phase_5_workload_classification.md`.

### Phase 6 — Per-thread breakdown

```bash
perf stat --per-thread -e cycles,instructions /tmp/prove_loop_profile 3 \
    2> experiment_logs/leanMultisig/profiling_baseline_m2_2026-05-11/phase_6_per_thread.txt
```

Apple Silicon scheduling is complex. Identify:
- Are rayon workers landing on P-cores or E-cores?
- Load imbalance: max-min cycles across threads
- IPC variance across threads (high P-core IPC vs lower E-core IPC)
- Whether rayon's work-stealing is bridging the P/E gap

`phase_6_load_balance.md`.

### Phase 7 — Per-crate aggregation

```bash
objdump --syms /tmp/prove_loop_profile | grep "^[0-9a-f]" > /tmp/symbols_m2.txt
nm --demangle /tmp/prove_loop_profile > /tmp/symbols_m2_demangled.txt
```

Parse symbols by Rust crate prefix (`mt_koala_bear`, `mt_sumcheck`, `mt_whir`, `mt_poly`, `lean_vm`, `lean_compiler`, `xmss`, `rec_aggregation`, `rayon`, `rayon_core`, `std`, etc.). Cross-reference with cycle attribution from Phase 1's inclusive report. Produce a per-crate share table.

`phase_7_per_crate.md`.

### Phase 8 — Final synthesis

`profiling_baseline_m2_report.md` — same structure as Hetzner version but with Apple-Silicon-specific findings (P/E core split, NEON vs AVX-512 instruction-mix differences, missing memory-counter data).

**The headline finding the team is looking for:** the Phase-1 inclusive Poseidon attribution number. Compare:
- User prediction: 35-40%
- Today's leaf attribution: ~24%
- Measured: ???

This number anchors the next month of optimization ranking discussions.

### Phase 9 — Draft pr_body.md

Same shape as Hetzner experiment. The pr_body is the methodology documentation, not the perf report itself.

## Stop criterion

All Phase 0-9 deliverables exist.

## Hard constraints

- **No source changes.** Read-only.
- **Build with debuginfo=2.** Required for line-level annotation.
- **Memory hygiene before each measurement-bearing run.** Skip if state already clean.
- **Pre-empted by M2 v2 experiment if it's still running.** If the coordinator dispatches this while `zk-alloc-m2-asahi-v2-2026-05-11` is in active state on M2, escalate to brain via `queue/needs-decision/` rather than colliding on the perf slot.
- **Commit-per-phase.** Resilient to interruption.
- **No PR push.** Brain handles submission.

## Why this matters

Today's attribution data has 5-10pp uncertainty. The blind survey's predictions for Group J (7-10% → actual ~0%) and AIR Poseidon's framing (8.25% → really part of recursed Poseidon surface, not a separate Blake3-swap target) hinged on imprecise leaf attribution. This experiment closes the loop on M2-side ground truth, pairs with the Hetzner baseline for a defensible cross-arch attribution table, and tests the explicit user prediction (Poseidon = 35-40%, not 24%).

---
*Comprehensive M2 profiling baseline. Drafted 2026-05-11 alongside Hetzner equivalent. Brain reviews + decides whether to upstream methodology after both land.*
