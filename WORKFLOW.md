# ZK Autoresearch — Workflow Guide

A practical guide for running optimization experiments with the autoresearch loop. Written to capture hard-won lessons from Experiments 1–4.

---

## Overview

The loop runs Claude as an autonomous agent that reads Plonky3 source, proposes optimizations, benchmarks them, and keeps improvements. Each "experiment round" targets a specific file set. Rounds build on each other — **branch hygiene matters**.

---

## Folder Structure

```
experiment_logs/
  Plonky3/
    NTT/
      active/
        CLAUDE.md          ← agent instructions for the current run
      experiment_N/
        CLAUDE.md          ← snapshot of CLAUDE.md used during this experiment
        logs/              ← terminal.log, experiments.jsonl, report.md
      discarded/
        experiment_X/
          notes.md         ← why it was discarded
          logs/
```

**Rules:**
- `active/CLAUDE.md` is the live file the loop reads. Edit this, not the root one.
- When starting a new experiment, copy `active/CLAUDE.md` into the previous experiment's folder as a snapshot before modifying it.
- Discarded experiments are moved to `discarded/` with a `notes.md` explaining why.

> **TODO**: Update `loop.py` `CLAUDE_MD` path to point to `experiment_logs/Plonky3/NTT/active/CLAUDE.md`

---

## Pre-Run Checklist

Before starting a new experiment round:

### 1. Confirm previous PR is merged
```bash
# Check upstream main includes previous round's work
cd Plonky3 && git fetch origin && git log --oneline origin/main | head -10
```
**Do not start a new round until the previous round's PR is merged into upstream main.** Starting on an unmerged branch risks branch divergence (this cost us Experiment 2 and 4).

### 2. Pull fresh main
```bash
git checkout main && git pull origin main
```

### 3. Verify loop is on the correct branch
```bash
cd Plonky3 && git branch && git log --oneline -5
```
The Plonky3 repo should be on `main` (or the agreed starting branch). Check there are no uncommitted changes:
```bash
git status
```
The loop will now warn if dirty at startup — but prevention is better.

### 4. Snapshot and update CLAUDE.md
```bash
# Snapshot previous experiment's CLAUDE.md
cp experiment_logs/Plonky3/NTT/active/CLAUDE.md \
   experiment_logs/Plonky3/NTT/experiment_N/CLAUDE.md
```
Then update `active/CLAUDE.md` for the new round:
- Update "Current Codebase State" section to reflect merged improvements
- Update writable targets
- Move confirmed dead ends to the dead ends section
- Remove dead ends from previous rounds that no longer apply

### 5. Run pre-flight benchmark
```bash
cargo bench -p p3-dft --features p3-dft/parallel --bench fft \
  -- "coset_lde" --noplot --measurement-time 35
```
Record this as your baseline. If it differs significantly from the previous best, investigate before running the loop.

---

## Running the Loop

```bash
# Standard run
python3 loop.py --max-iter 20

# Fresh start (will prompt before discarding uncommitted changes)
python3 loop.py --start-fresh --max-iter 20

# Resume after interrupt (reuses baseline if Plonky3 commit unchanged)
python3 loop.py --max-iter 20
```

### Monitoring
```bash
# Graceful stop after current iteration completes
touch STOP

# Watch live
tail -f experiment_logs/Plonky3/NTT/active/terminal.log  # if tee'd
```

### When to intervene
- Agent is reading the same files repeatedly without writing → it's overthinking, check if it needs a nudge in CLAUDE.md
- Agent is targeting files outside the writable scope → check CLAUDE.md constraints
- Benchmark variance is high (>1.5%) → hardware contention, stop and retry later
- 3+ Anthropic 529 errors in one session → regional outage, stop and wait

---

## Post-Run Checklist

### 1. Review kept improvements
```bash
python3 -c "
import json
exps = [json.loads(l) for l in open('experiments.jsonl')]
kept = [e for e in exps if e.get('kept')]
for e in kept:
    print(f\"#{e['iteration']:03d} {e['improvement_pct']:+.2f}% p={e.get('bench_p_value','?')} — {e['agent_idea']}\")
"
```

### 2. Validate kept improvements cross-session
Any kept improvement with **p > 0.05** needs cross-session validation before committing upstream:
```bash
bash run_benchmark.sh  # compares all branches vs main in one Criterion session
```
Look for p=0.00 and "Performance has improved" verdict from Criterion.

### 3. Create experiment snapshot
```bash
mkdir -p experiment_logs/Plonky3/NTT/experiment_N/logs
cp experiments.jsonl experiment_logs/Plonky3/NTT/experiment_N/logs/
# Write report
```

### 4. Commit Plonky3 improvements to a named branch
```bash
cd Plonky3
git checkout -b perf/dft-exp5-round5-improvements
git push myfork perf/dft-exp5-round5-improvements
```
**Never leave improvements as uncommitted changes on a detached HEAD.** This caused us to lose the exp-4 commit (recovered via reflog, but risky).

### 5. Open PR
- Target: upstream Plonky3 `main`
- Include: benchmark numbers from `run_benchmark.sh`, p-values, description of each change
- Reference: experiment log file for full history

---

## Benchmark Methodology

### Single-session comparison (authoritative)
```bash
bash run_benchmark.sh
```
Uses Criterion's `--save-baseline` + `--baseline main` to compare branches in the same session. This gives meaningful p-values. **This is the only benchmark result suitable for upstream PR claims.**

### Loop benchmark (relative, session-local)
The loop's internal benchmark compares each iteration against the previous best. It has ~1.4% session variance. Improvements below 0.5% at p > 0.10 are likely noise.

**Keep thresholds:**
- `improvement_pct > 0.20%` (MIN_IMPROVEMENT_PCT)
- `bench_p_value < 0.10` (P_VALUE_THRESHOLD)

Both must pass for a change to be kept.

### Cooling between runs
Do **not** add sleep between branch benchmarks in `run_benchmark.sh`. Cooling changes CPU frequency state and introduces systematic bias against improvements (observed: ~1% underreporting).

---

## Branch Hygiene

This is the most important section. Experiment 2 was wasted because of branch divergence.

### Rule: always build on the previous round's merged tip

```
main (after Round N PR merged)
  └── start new experiment here
```

Never start a new round from a branch that hasn't been merged. If you must start before merge, cherry-pick the exact tip commit and document it.

### Rule: verify cumulative correctness before benchmarking

```bash
# Check that your branch includes all expected improvements
git log --oneline origin/main..HEAD
```

### Rule: use myfork for all experiment branches

```bash
git push myfork perf/dft-expN-roundN-improvements
```

Never push experiment branches to `origin` (upstream Plonky3). Only push PRs to origin.

---

## CLAUDE.md Maintenance

CLAUDE.md is the agent's instruction set. It changes frequently. Key principles:

- **Dead ends**: Add confirmed dead ends after 3+ attempts with different implementations. One failed attempt is not enough to declare dead.
- **Proven techniques**: Remove these when the scope changes (e.g., when moving from dft/src/ to monty-31/, dft techniques are irrelevant).
- **Writable scope**: Be explicit. Mark everything else as read-only. The agent will drift to familiar code if scope is ambiguous.
- **False dead ends**: If a result was caused by token cutoff or incomplete implementation, mark it explicitly as "not a real test of this idea."
- **Trim regularly**: Ask at the start of each round whether CLAUDE.md needs trimming. Stale context wastes tokens.

---

## Cost Management

Typical costs per iteration (claude-sonnet-4-6):
- Normal iter (focused, edit_file): ~$1–3
- Large file write iter: ~$5–10
- Overthinking iter (29 min, 3 full-file rewrites): **$18.78** (Experiment 4, iter 3)

**edit_file tool**: Always prefer over write_file for changes under ~100 lines. Saves 5–10x tokens on large files.

**MAX_TOKENS**: Currently 40k. Do not reduce — agent needs headroom for large file context. Increasing further raises cost without clear benefit.

**Token budget alarm**: If an iteration exceeds $10, review the terminal log. The agent is almost certainly reconstructing a large file unnecessarily.

---

## Known Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent reads same file 10+ times | No edit_file, planning full rewrite | Ensure edit_file is deployed |
| Kept improvement later shows no gain | p-value was high (>0.10) | Run cross-session validation |
| New round benchmarks worse than expected | Branch divergence, missing previous improvements | Check `git log origin/main..HEAD` |
| Loop baseline drifts between runs | Session variance (~1.4%) | Use run_benchmark.sh for cross-session comparison |
| Agent targets wrong files | CLAUDE.md scope unclear | Tighten writable list, mark others explicitly read-only |
| $18+ single iteration | Agent writing full 1700-line file multiple times | edit_file tool; check it's deployed on server |
| 529 overload errors | Anthropic regional outage | Wait; loop has exponential backoff up to 240s |
| Uncommitted changes lost on --start-fresh | Loop silently reverted | Fixed: now prompts before discarding |

---

## Experiment History

| Experiment | Target | Result | Status |
|------------|--------|--------|--------|
| 1 | dft/src/ butterflies + DIT parallel | ~2.7% improvement (74 iters) | Merged → Round1 PR |
| 2 | dft/src/ layer fusion | Branched before exp-19/21, results invalid | Discarded |
| 3 | dft/src/ continued | Wrong branch base | Discarded |
| 4-monty | monty-31/src/x86_64_avx512/ | 0.41% kept (p=0.23, weak) | Needs validation |
| 5 | TBD — start from merged Round1 | — | Planned |
