# leanMultisig — PR Benchmark: pw3 Performance Bundle

## Role
You are a benchmark engineer. Your job is to produce clean, reproducible A/B
performance data for a 5-commit PR to leanMultisig. You will test each commit
individually AND the full bundle, using the production workload.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Before You Start

1. Kill any competing processes:
```bash
# Check for other Claude sessions or benchmarks
ps aux | grep -E 'cargo|claude|bench' | grep -v grep
# Kill the pw3-security tmux session if still running
tmux kill-session -t pw3-security 2>/dev/null || true
```

2. Verify no background CPU load: `uptime` should show low load averages.

## Repo

```
cd ~/zk-autoresearch/leanMultisig
```

**Branch:** `pr/perf-bundle` (on remote `myfork`)

## Commits Under Test

The PR has 5 commits on top of `origin/main` (`19f1c774`):

| # | SHA | Description |
|---|-----|-------------|
| 0 | `19f1c774` | origin/main (baseline) |
| 1 | `a6b3e553` | InternalLayer16 copy elimination in permute_simd |
| 2 | `b3213c11` | Parallel stacked polynomial copy (4MB chunks) |
| 3 | `a2dc0cfe` | FFT MDS in AIR eval (50 mults vs Karatsuba 72) |
| 4 | `bdf43a62` | Sponge RATE=8→12 + zk-DSL RATE=12 port |
| 5 | `4175b20a` | MMO feedforward sponge (124-bit collision security) |

## Benchmark Command

The production benchmark is `fancy-aggregation`:

```bash
RUSTFLAGS="-C target-cpu=native" cargo run --release -- fancy-aggregation --json
```

This outputs a JSON line with per-node timing and proof sizes. To extract totals:

```bash
# Total time (sum of all node time_secs):
echo '<json>' | python3 -c "import json,sys; r=json.load(sys.stdin); print(sum(n['stats']['time_secs'] for n in r['nodes']))"

# Proof size per node:
echo '<json>' | python3 -c "import json,sys; r=json.load(sys.stdin); [print(f\"{n['path']}: {n['stats']['proof_kib']} KiB\") for n in r['nodes']]"
```

## What To Do

### Phase 1: Pre-build all 6 binaries

For each of the 6 SHAs (0 through 5), do a clean build and save the binary:

```bash
export RUSTFLAGS="-C target-cpu=native"
for sha in 19f1c774 a6b3e553 b3213c11 a2dc0cfe bdf43a62 4175b20a; do
  git checkout $sha
  cargo clean --release
  cargo build --release 2>&1 | tail -3
  cp target/release/lean-multisig /tmp/bench_${sha}
done
git checkout pr/perf-bundle  # restore
```

Verify all 6 binaries exist and are different:
```bash
md5sum /tmp/bench_*
```

### Phase 2: Benchmark each binary

For each binary, run `fancy-aggregation --json` **5 times** and record the JSON output.

```bash
for sha in 19f1c774 a6b3e553 b3213c11 a2dc0cfe bdf43a62 4175b20a; do
  echo "=== Benchmarking $sha ==="
  for run in 1 2 3 4 5; do
    /tmp/bench_${sha} fancy-aggregation --json 2>/dev/null >> /tmp/bench_results_${sha}.jsonl
  done
done
```

**IMPORTANT:** Run all 5 runs of ONE binary before moving to the next. Do NOT
interleave. The warmup built into `run_with_warmup` handles the first-run cache effect.

### Phase 3: Parse and compute results

Write a Python script that:

1. For each binary, reads the 5 JSON lines from `/tmp/bench_results_${sha}.jsonl`
2. Extracts:
   - `total_time_secs` = sum of all node `time_secs` per run
   - `leaf_xmss_per_sec` = for leaf nodes, `n_xmss / time_secs`
   - `total_proof_kib` = sum of all node `proof_kib` per run
   - `peak_rss` from stderr if available (or skip)
3. Computes per-binary: **mean**, **stddev**, **min**, **max** of total_time_secs
4. Computes per-commit deltas:
   - Commit 1 vs commit 0 (main)
   - Commit 2 vs commit 1
   - Commit 3 vs commit 2
   - Commit 4 vs commit 3
   - Commit 5 vs commit 4
   - Commit 5 vs commit 0 (full bundle)
5. For each delta: Δ% = (candidate_mean - baseline_mean) / baseline_mean * 100

### Phase 4: Outlier check

For each binary's 5 runs, if any run's total_time_secs is more than 2× stddev
from the mean, flag it. If flagged, do 3 additional runs and recompute with the
extended dataset (drop the single worst outlier if N >= 7).

### Phase 5: Write results

Write the final results to:
`~/zk-autoresearch/experiment_logs/leanMultisig/benchmark_pw3_pr/results.md`

Format — follow this structure exactly:

```markdown
# pw3 PR Benchmark Results

**Date:** YYYY-MM-DD
**Machine:** Hetzner AX42-U (Zen 4, AVX-512)
**Workload:** fancy-aggregation (production topology)
**Runs per binary:** 5

## Per-Binary Results

| SHA | Description | Mean (s) | Stddev (s) | Min (s) | Max (s) | Proof (KiB) |
|-----|-------------|----------|------------|---------|---------|-------------|
| 19f1c774 | main (baseline) | | | | | |
| a6b3e553 | InternalLayer16 elim | | | | | |
| b3213c11 | Parallel stacking | | | | | |
| a2dc0cfe | FFT MDS | | | | | |
| bdf43a62 | RATE=12 + zk-DSL | | | | | |
| 4175b20a | MMO feedforward | | | | | |

## Per-Commit Deltas

| Change | Baseline Mean (s) | Candidate Mean (s) | Δ% | Description |
|--------|-------------------|--------------------|----|-------------|
| 1 vs 0 | | | | InternalLayer16 copy elim |
| 2 vs 1 | | | | Parallel stacking |
| 3 vs 2 | | | | FFT MDS |
| 4 vs 3 | | | | RATE=12 |
| 5 vs 4 | | | | MMO feedforward |
| **5 vs 0** | | | | **Full bundle** |

## Proof Size Comparison (main vs bundle)

| Node | main (KiB) | bundle (KiB) | Δ% |
|------|------------|--------------|-----|
| (per-node rows) | | | |
| **Total** | | | |

## Raw Data

(Paste the per-run total_time_secs arrays for each binary)
```

Also write the raw JSON results to:
`~/zk-autoresearch/experiment_logs/leanMultisig/benchmark_pw3_pr/raw_results.json`

## Constraints

- **ALWAYS** use `RUSTFLAGS="-C target-cpu=native"` for builds.
- **Clean build** (`cargo clean --release`) for each binary. No incremental.
- **No competing workloads.** Kill other processes before starting.
- If ANY step fails (build error, runtime panic), stop and write the error to results.md.
- Do NOT modify any source code. You are read-only on the repo.
- Do NOT push anything. You are benchmarking only.

## NEVER STOP
Run all phases to completion. Do not stop until results.md is written.
