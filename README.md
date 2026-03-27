# ZK Autoresearch — Plonky3 DFT Optimizer

Karpathy's autoresearch pattern applied to a production ZK prover.
An LLM agent autonomously optimizes Plonky3's NTT/DFT implementation via a
benchmark feedback loop — no human in the loop after launch.

**Target:** `coset_lde_batch` on BabyBear field, 2^20 rows × 256 columns, `Radix2DitParallel`
**Signal:** Criterion benchmark time (ms, lower is better)
**Model:** Claude Sonnet 4.6 via Anthropic API
**Hardware:** Hetzner CCX33 — AMD EPYC, AVX512, 8 cores

---

## Round 1 Results

6 improvements in 74 iterations. All gains from eliminating redundant work in the hot butterfly loop.

| Transform Size | Baseline | Optimized | Gain |
|----------------|----------|-----------|------|
| 2^14 (~16K)    | 58.7ms   | 51.9ms    | +10.4% |
| 2^16 (~64K)    | 177.2ms  | 173.5ms   | +2.5%  |
| 2^18 (~256K)   | 691.8ms  | 677.7ms   | +2.1%  |
| 2^20 (~1M) ★  | 2756ms   | 2699ms    | +2.1%  |
| 2^22 (~4M)     | 11925ms  | 11021ms   | +8.2%  |

★ target size — agent only optimized for 2^20, gains at other sizes are free.
All results statistically significant (p=0.00).

---

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     loop.py (outer loop)                    │
│                                                             │
│  1. Build prompt: current score + full experiment history   │
│  2. Call Claude API (fresh context every iteration)         │
│     └─ Agent reads .rs files, writes ONE targeted change    │
│  3. cargo test -p p3-dft       ← fast property tests (~30s)  │
│     cargo test -p p3-examples  ← end-to-end ZK proof tests  │
│  4. cargo bench -p p3-dft      ← measure improvement (~90s) │
│  5. improvement? → git commit  │  regression? → git revert  │
│  6. Log to experiments.jsonl                                │
│  7. Repeat                                                  │
└─────────────────────────────────────────────────────────────┘
```

Each iteration takes ~2–4 min (compile + test + bench). Expected throughput: **30–50 experiments/day**.

---

## Files

```
zk-autoresearch/
├── loop.py                        Main autoresearch loop
├── watch.py                       Live log monitor
├── CLAUDE.md                      Agent constraints + optimization target
├── requirements.txt               Python deps (anthropic only)
├── setup.sh                       One-shot server setup script
├── test_loop.py                   Unit tests for loop.py logic
└── experiment_logs/
    └── experiment_1/
        ├── experiments.jsonl      Full experiment log (74 iterations)
        └── experiments_kept.jsonl Kept improvements only
```

The target Plonky3 repo is cloned separately — see setup instructions below.

---

## Server Setup (run once)

```bash
# 1. Copy files to server
scp loop.py CLAUDE.md watch.py requirements.txt setup.sh \
    root@<server>:~/zk-autoresearch/

# 2. Clone Plonky3 into the working directory
ssh root@<server>
cd ~/zk-autoresearch
git clone https://github.com/Plonky3/Plonky3.git

# 3. Install Rust, Python venv, pre-compiles (~5 min)
bash setup.sh

# 4. Verify CPU features (AVX512 recommended)
grep -E "avx512f" /proc/cpuinfo | head -1

# 5. Sanity-check the benchmark runs cleanly
source .venv/bin/activate
cd Plonky3 && cargo bench -p p3-dft --features p3-dft/parallel --bench fft -- "coset_lde"
```

---

## Running the Loop

```bash
# On server, in a tmux session so it survives SSH disconnect
tmux new -s autoresearch
cd ~/zk_autoresearch
source .venv/bin/activate
export ANTHROPIC_API_KEY=sk-ant-...

python3 loop.py                    # run up to 100 iterations
python3 loop.py --max-iter 50      # stop after 50
python3 loop.py --start-fresh      # reset git + rename old log, then run

# Detach from tmux (loop keeps running):  Ctrl+B  then  D
# Reattach:  tmux attach -t autoresearch
# List sessions: tmux ls
```

**Graceful stop** (finishes the current iteration, then exits):
```bash
touch ~/zk-autoresearch/STOP
```

---

## Monitoring

From a second SSH session:

```bash
# Live table — updates as experiments complete
cd ~/zk_autoresearch
source .venv/bin/activate
tail -f experiments.jsonl | python3 watch.py

# Replay full log
python3 watch.py experiments.jsonl

# Quick summary
python3 -c "
import json
rows = [json.loads(l) for l in open('experiments.jsonl') if l.strip()]
kept = [r for r in rows if r.get('kept')]
print(f'Experiments: {len(rows)} | Improvements: {len(kept)}')
for r in kept:
    print(f\"  #{r['iteration']:03d} {r['improvement_pct']:+.2f}% — {r['agent_idea']}\")
"
```

---

## Experiment Log Format

`experiments.jsonl` — one JSON object per line, append-only.

```jsonc
{
  "iteration": 3,
  "timestamp": "2026-03-25T14:32:01Z",
  "kept": true,
  "reason": "improvement",          // improvement | regression | tests_failed | bench_failed | no_changes
  "score_ns": 1198800000,           // benchmark median, nanoseconds (null if bench failed)
  "baseline_ns": 1243200000,        // best score before this iteration
  "improvement_pct": 3.5714,        // positive = faster
  "agent_idea": "Cache-blocked twiddle access in dit_layer to reduce L2 misses",
  "agent_thinking": "The twiddle factors are accessed...",  // first 800 chars of agent reasoning
  "diff": "diff --git a/dft/src/...",   // full unified diff
  "diff_summary": "diff --git a/dft...", // first 600 chars
  "agent_time_s": 18.4              // seconds spent on API call
}
```

---

## Configuration

All tunable constants are at the top of `loop.py`:

| Constant | Default | Notes |
|----------|---------|-------|
| `MODEL` | `claude-sonnet-4-6` | Change to `claude-opus-4-6` for harder problems |
| `MAX_ITERATIONS` | `100` | Kill condition |
| `HISTORY_WINDOW` | `5` | Recent non-kept experiments shown; all kept improvements always shown |
| `BENCH_FILTER` | `coset_lde/.../1048576` | Criterion benchmark filter string |
| `WRITABLE` | `dft/src/, baby-bear/src/` | Files the agent can modify |

---

## Cost

Round 1 actual: **$80.76 for 74 iterations (~$1.09/iter)** on Claude Sonnet 4.6.
Higher than expected due to token waste on directory exploration — fixed in round 2.

| Item | Per Experiment | 100 Experiments |
|------|---------------|-----------------|
| Claude Sonnet 4.6 | ~$0.80–1.20 | ~$80–120 |
| Hetzner CCX33 | ~$0.005 | ~$0.50 |
| **Total** | | **~$80–120** |

---

## Security Notes

- The `ANTHROPIC_API_KEY` lives only in the process environment — never written to disk
- Rotate the key after the experiment run completes
- The agent cannot write outside `dft/src/` or `baby-bear/src/` (enforced in `loop.py`)
- The agent has no shell/bash tool — it can only read and write specific files
- All changes are tracked in git; `git revert` is automatic on regressions

---

## Prior Art

- Karpathy's autoresearch pattern: LLM + benchmark feedback loop for nanoGPT kernel optimization
- Gassmann et al. (2025): autotuned LLVM flags for SP1/RISC Zero → ~17% improvement
- **Gap this fills:** source-level autoresearch on a production ZK prover (first known application)

*Inspired by Karpathy's autoresearch pattern. First known application to a production ZK prover.*

## License

MIT
