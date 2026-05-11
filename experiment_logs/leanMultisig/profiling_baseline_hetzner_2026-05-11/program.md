# leanMultisig — Comprehensive profiling baseline (Hetzner AVX-512)

## Role

You are a performance investigator. Your job: produce a single comprehensive profiling baseline of `leanMultisig prove_loop` on Hetzner Zen 4 + AVX-512, using **all 7 methodology variants** the brain side listed today. The deliverable is one report that lets the team rank optimization candidates against ground-truth attribution rather than regex-bucketed sample data.

You do NOT optimize. You measure, analyze, write up. No code changes to leanMultisig, no commits beyond what your own infrastructure (flamegraph script setup, perf scripts) needs.

You are running on Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512, single CCD).

## Context — what already exists, what's missing

Today's call-sites experiment (`experiment_logs/leanMultisig/poseidon_call_sites_2026-05-11/`) captured a perf.data on this machine. **Reuse that data where possible** (free — already on disk). Specifically:

- `/tmp/perf.data` may still exist on Hetzner from the call-sites run (verify; if gone, capture fresh)
- `experiment_logs/leanMultisig/poseidon_call_sites_2026-05-11/perf_report.txt` is the LEAF-symbol report — the limit of today's brain-side analysis

The brain side has identified these gaps in today's table:

- **Rayon misattribution**: `rayon::iter::plumbing::bridge_producer_consumer::helper` at 19.33% catches inlined parallel work, not actual scheduling overhead. Real rayon overhead is probably <5%.
- **No hierarchical call-graph attribution**: leaf symbols only. Inlined work (e.g., the post-PR-216 `compress_mut` 15.3 KB collapsed frame) loses its semantic identity.
- **No line-level attribution for hot symbols**: don't know within `compress_mut` whether MDS or S-box or Montgomery reduce eats the cycles.
- **No differential vs serial**: can't separate scheduling overhead from inlined-parallel-work.
- **No hardware counters beyond cycles**: no branch-miss / L1-miss / dTLB-miss data. Can't tell WHY each symbol is slow.
- **No per-thread breakdown**: don't know if rayon workers stall or balance evenly.
- **No per-crate aggregation**: regex-grouping is editorial; objdump-based attribution is cleaner.

## Repo & setup

| Repo | Path on Hetzner | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | branch from `origin/main` as `profile/baseline-2026-05-11` |
| Brendan Gregg FlameGraph tools | clone to `~/zk-autoresearch/tools/FlameGraph` if missing | `git clone https://github.com/brendangregg/FlameGraph ~/zk-autoresearch/tools/FlameGraph` |

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout origin/main
git checkout -b profile/baseline-2026-05-11

# FlameGraph tools (idempotent)
mkdir -p ~/zk-autoresearch/tools
test -d ~/zk-autoresearch/tools/FlameGraph || \
  git clone https://github.com/brendangregg/FlameGraph ~/zk-autoresearch/tools/FlameGraph
```

Build the non-instrumented binary used throughout:

```bash
cd ~/zk-autoresearch/harness/leanmultisig/bench
RUSTFLAGS="-C target-cpu=native -g" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_profile
```

The `-g` flag preserves DWARF debug info for line-level annotation. Workspace `[profile.release]` should also have `debug = true` or `debug = "line-tables-only"` — if the build doesn't have it, add it temporarily via `RUSTFLAGS="-C debuginfo=2"`.

## The 7 methodology variants — execute in order

### Phase 1 — Hierarchical call-graph attribution

```bash
cd ~/zk-autoresearch
perf record -F 997 --call-graph dwarf -o /tmp/perf_baseline.data -- /tmp/prove_loop_profile 3
perf report -i /tmp/perf_baseline.data --stdio --no-children --max-stack=20 > \
  experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/perf_leaf.txt
perf report -i /tmp/perf_baseline.data --stdio --children --max-stack=20 > \
  experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/perf_callgraph.txt
```

Compare `--no-children` (leaf attribution) vs `--children` (inclusive — child cycles roll up to parent). The children view solves the rayon-helper misattribution.

In the report, identify the top 10 INCLUSIVE callers (the actual top-of-call-stack hot paths). Specifically check:
- Where does `rayon::iter::plumbing::bridge_producer_consumer::helper` roll up to? What's its TRUE parent (the call site in leanMultisig code)?
- Is `compress_mut` mostly inlined, or does it have multiple distinct call paths?
- Are there call paths that the leaf view didn't surface (e.g., a 5% caller whose work is split across 10 child symbols each <0.5%)?

Save findings to `phase_1_callgraph_findings.md`.

### Phase 2 — Flamegraph rendering

```bash
perf script -i /tmp/perf_baseline.data > /tmp/perf_script.out
~/zk-autoresearch/tools/FlameGraph/stackcollapse-perf.pl /tmp/perf_script.out > /tmp/perf_collapsed.txt
~/zk-autoresearch/tools/FlameGraph/flamegraph.pl /tmp/perf_collapsed.txt > \
  experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/flamegraph.svg
```

Open the SVG (locally if needed) and identify the top 3 "hot ridges" — the call-stack paths that dominate. Write 2-3 sentences per ridge in `phase_2_flamegraph_findings.md`: what's the path, what's the share, what's the actual workload it represents.

### Phase 3 — Per-symbol line-level annotation

For the top 8 symbols by INCLUSIVE attribution from Phase 1, run:

```bash
perf annotate -i /tmp/perf_baseline.data --stdio --no-source --symbol "<demangled_symbol>" > \
  experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/annotate_<short_name>.txt
```

(For each of the 8 symbols, separate file.)

Annotation tells you, within a hot symbol, which instructions / lines eat the cycles. Specifically for `compress_mut` we want to know: MDS multiplies vs S-box mults vs Montgomery reduces vs round-constant adds. Write a one-paragraph summary per top symbol in `phase_3_annotate_summary.md`.

### Phase 4 — Differential profile (rayon overhead isolation)

Re-run `prove_loop` serially and capture cycles:

```bash
RAYON_NUM_THREADS=1 perf stat -e cycles,instructions /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/phase_4_serial_stats.txt
perf stat -e cycles,instructions /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/phase_4_parallel_stats.txt
```

Compute:
- Total cycles (parallel) − total cycles (serial) = false-attribution share that was actually inlined-parallel-work attributed to rayon helpers
- True rayon scheduling overhead ≈ cycles diff between (parallel total / NUM_THREADS) and (serial cycles)
- Wall-clock parallel vs serial = parallel speedup actually achieved

Write the analysis to `phase_4_rayon_decomposition.md` with numbers + interpretation.

### Phase 5 — Hardware counters (the "why is this slow" data)

Single perf stat run with multi-event capture:

```bash
perf stat -e cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses,dTLB-loads,dTLB-load-misses,LLC-loads,LLC-load-misses,cache-references,cache-misses \
  /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/phase_5_hw_counters.txt
```

Compute:
- IPC (instructions / cycles) — expect ~0.91-1.13 per prior measurements
- Branch misprediction rate (branch-misses / branches)
- L1D miss rate (L1-dcache-load-misses / L1-dcache-loads)
- dTLB miss rate (dTLB-load-misses / dTLB-loads)
- LLC miss rate

Classify the workload: compute-bound vs memory-bound vs branch-bound. The blind survey assumed leanMultisig is latency-bound by Montgomery dependency chains; the hardware counters confirm or refute. Write to `phase_5_workload_classification.md`.

### Phase 6 — Per-thread breakdown

```bash
perf stat --per-thread -e cycles,instructions /tmp/prove_loop_profile 3 \
  2> experiment_logs/leanMultisig/profiling_baseline_hetzner_2026-05-11/phase_6_per_thread.txt
```

Identify:
- Per-rayon-worker cycle distribution
- Are some workers stalling (high cycles, low instructions) while others spin?
- Load imbalance across threads (max-min cycles spread)

Write to `phase_6_load_balance.md`.

### Phase 7 — Per-crate aggregation

Run `objdump --syms /tmp/prove_loop_profile` (or `nm --demangle`) and parse symbols by Rust crate prefix. Cross-reference with the perf cycle attribution to produce a per-crate cycle share table:

```
mt_koala_bear (Poseidon impl): X%
mt_sumcheck (sumcheck core): Y%
mt_whir (FRI/WHIR commit): Z%
mt_poly (MLE / eq-mle): W%
rayon / rayon_core (scheduling proper): V%
... etc
```

Less editorial than my regex grouping. Save to `phase_7_per_crate.md`.

### Phase 8 — Final synthesis report

Produce `profiling_baseline_report.md` with the canonical profile:

```markdown
# leanMultisig profiling baseline — Hetzner Zen 4 AVX-512 (2026-05-11)

## Method
<commands run, perf params, build flags, environment>

## Top-line numbers
- IPC: ...
- Workload classification: ...
- Wall-clock parallel: ...
- Wall-clock serial (RAYON_NUM_THREADS=1): ...
- Parallel speedup: ...

## Canonical cycle distribution table (per-crate)
| Crate / subsystem | % cycles | What it is |
|---|---|---|

## Inclusive call-graph top paths
1. ...
2. ...

## Hot-symbol line-level findings
- `compress_mut`: <which lines dominate>
- `eval_eq_with_packed_output`: ...
- ... (top 8)

## Hardware-counter findings
- Branch miss rate: ... → ...
- L1D miss rate: ... → ...
- dTLB miss rate: ... → ...
- LLC miss rate: ... → ...
- Bottleneck classification: compute-bound | memory-bound | latency-bound | branch-bound

## Rayon decomposition
- True scheduling overhead: ...
- Inlined parallel work (previously misattributed to bridge_helper): ...

## Implications for optimization ranking
<3-5 paragraphs ranking the surfaces by attack-vector × ground-truth-leverage, replacing today's regex-grouped table>
```

### Phase 9 — Draft pr_body.md per architecture convention

Architecture says experiment agents draft `pr_body.md` before exit, even when there's nothing to ship. For this experiment, `pr_body.md` is "here's the profiling baseline + how to reproduce it." Brain decides whether to upstream the methodology / commit any helper scripts.

## Stop criterion

All Phase 1-9 deliverables exist:
- `phase_1_callgraph_findings.md`
- `phase_2_flamegraph_findings.md` + `flamegraph.svg`
- `phase_3_annotate_summary.md` + 8 annotation files
- `phase_4_rayon_decomposition.md`
- `phase_5_workload_classification.md`
- `phase_6_load_balance.md`
- `phase_7_per_crate.md`
- `profiling_baseline_report.md` (final synthesis)
- `pr_body.md`

## Hard constraints

- **No leanMultisig source changes.** Read-only investigation. Branch is just for tracking.
- **Build with `-g` debuginfo enabled.** Required for line-level annotation.
- **Reuse existing perf.data if usable.** The call-sites experiment captured a perf.data — check `/tmp/perf.data` on Hetzner; if present and complete, re-use it for Phase 1-3 to save time. Otherwise capture fresh.
- **Commit-per-phase.** Phase 1 commit, Phase 2 commit, etc. Resilient to interruption.
- **No PR push.** Brain reviews + decides whether to commit helper scripts upstream.
- **Cap report at 8-10 pages rendered.** Tight per-finding writeups beat long ones.

## Why this is brain-side-valuable

Today's regex-grouped profile let the brain estimate optimization candidate magnitudes, but with caveats large enough that several candidates were over- or under-ranked. The deliverable here gives the team a defensible baseline to anchor against for at least the next month of Hetzner-side optimization work. Pairs with the M2-side profiling baseline (separate experiment, M2 Asahi).

---
*Comprehensive profiling baseline experiment. Drafted 2026-05-11 after today's call-sites + Group J discussion surfaced the methodology gap.*
