# ZK Autoresearch — Workflow Guide

A practical guide for running optimization experiments with the autoresearch loop. Covers both Plonky3 (loop.py-based) and leanMultisig (Claude CLI-based) experiments.

---

## Projects

| Project | Mode | Server | Primary Target |
|---------|------|--------|----------------|
| Plonky3 NTT | loop.py agent | AWS c7a.2xlarge (Zen 4, AVX-512) | monty-31 AVX-512 arithmetic |
| leanMultisig | Claude CLI agent | AWS c7a.2xlarge (Zen 4, AVX-512) | Poseidon2 arithmetic / sumcheck |

---

## Folder Structure

```
experiment_logs/
  Plonky3/
    NTT/
      active/
        CLAUDE.md          ← agent instructions for the current run
      experiment_N/
        CLAUDE.md          ← snapshot used during experiment
        logs/
      discarded/
        experiment_X/
          notes.md
  leanMultisig/
    shared/
      correctness.sh           ← two-layer: KoalaBear unit + WHIR integration
      eval_poseidon.sh         ← Poseidon microbench (primary signal for exp_1)
      eval_e2e.sh              ← Criterion xmss_leaf e2e (primary for exp_2, sanity for exp_1)
      verify_post_experiment.sh ← manual post-run verification before review
    experiment_1/
      program.md               ← Poseidon AVX-512 arithmetic target
      iters.tsv
    experiment_2/
      program.md               ← Sumcheck optimization target
      iters.tsv

leanMultisig-bench/
  benches/xmss_leaf.rs        ← Criterion bench (used by eval_e2e.sh)
```

**Rules:**
- `shared/` scripts are **read-only for the agent** — never modified during experiments
- Each experiment has its own `program.md` and `iters.tsv`
- `program.md` is the agent's instruction set — always read first by the agent

---

## AWS Server Setup

**Recommended:** AVX-512 capable instance (e.g. AMD Zen 4+, 8 vCPU, 16 GiB). Stop when not running experiments.
**User:** Run as the default user directly — do NOT create a separate agent user (breaks Claude CLI paste auth on some terminals).

```bash
ssh <your-instance>
```

**First-time setup on fresh instance:**
```bash
# System deps
sudo apt-get update -y && sudo apt-get install -y build-essential pkg-config libssl-dev clang

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Node + Claude CLI
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g @anthropic-ai/claude-code

# Repos
git clone https://github.com/Barnadrot/zk-autoresearch.git ~/zk-autoresearch
git clone https://github.com/Plonky3/Plonky3.git ~/zk-autoresearch/Plonky3
git clone https://github.com/leanEthereum/leanMultisig.git ~/zk-autoresearch/leanMultisig
cd ~/zk-autoresearch && git checkout infra/exp3-opus-ntt

# Pre-warm cargo
cd ~/zk-autoresearch/Plonky3 && cargo fetch
cd ~/zk-autoresearch/leanMultisig && cargo fetch
```

**Verify AVX-512:**
```bash
grep -o 'avx512[a-z]*' /proc/cpuinfo | sort -u
# Must show avx512f
```

**Claude CLI auth workaround (paste bug on AWS):**
If OAuth paste fails, use `CLAUDE_CODE_OAUTH_TOKEN` env var — generate token locally via `claude setup-token` then export on server.

---

## Running a leanMultisig Experiment

### 1. Pull latest main
```bash
cd ~/zk-autoresearch/leanMultisig && git checkout main && git pull origin main
```

### 2. Start Claude agent
```bash
cd ~/zk-autoresearch
claude --dangerously-skip-permissions
```

### 3. Give the agent its program
```
Read ~/zk-autoresearch/experiment_logs/leanMultisig/experiment_1/program.md and execute it.
The eval baseline is already saved — do not run --save-baseline again unless explicitly told to.
```

### 4. Monitor
- Agent commits each iter to leanMultisig repo — check `git log` to track progress
- Agent appends to `iters.tsv` — check for `correctness_fail` rows
- Stop if 3+ correctness failures in a row

### 5. Post-experiment verification (manual, before any review)
```bash
bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/verify_post_experiment.sh --save-baseline  # once on clean main
bash ~/zk-autoresearch/experiment_logs/leanMultisig/shared/verify_post_experiment.sh                  # after experiment
```
All four layers must pass before opening a PR or requesting external review.

---

## Running a Plonky3 Experiment

### 1. Pre-run checklist
```bash
cd ~/zk-autoresearch/Plonky3 && git checkout main && git pull origin main
git status  # must be clean
```

### 2. Start agent
```bash
cd ~/zk-autoresearch
claude --dangerously-skip-permissions
```
Point at `experiment_logs/Plonky3/NTT/experiment_2_monty_B_CLI/program.md`.

### 3. Benchmark methodology
- Primary: `eval.sh` using Criterion `--baseline` comparison
- Keep threshold: improvement > 0.20% AND p < 0.05
- Cross-session: run `eval.sh` 3 times back-to-back; all 3 must meet threshold before opening PR

---

## Correctness Hierarchy (leanMultisig)

| Check | When | Who runs it |
|-------|------|-------------|
| `correctness.sh` | After every agent change | Agent (automatic) |
| `eval_poseidon.sh` / `eval_e2e.sh` | After every iter | Agent (automatic) |
| `verify_post_experiment.sh` | After experiment, before PR | Human (manual) |
| External review | After verify passes | Open PR |

---


## Branch Hygiene

- **leanMultisig:** agent commits directly to main locally. Push to fork before opening PR.
- **Plonky3:** agent commits to main locally. Branch before pushing: `git checkout -b perf/expN-description`.
- Never push experiment branches to upstream origin.
- Always build on previous round's merged tip.

---

## Cost Management

| Model | Cost/iter (typical) |
|-------|-------------------|
| claude-sonnet-4-6 | $1–3 normal, $5–10 large file write |

- Always prefer Edit over Write for changes under ~100 lines
- If a single iter exceeds $10, agent is rewriting large files — check program.md constraints

---

## Known Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Claude CLI paste fails on AWS | Terminal paste bracketing bug (GH #47669) | Use `CLAUDE_CODE_OAUTH_TOKEN` env var |
| Agent user breaks paste | `sudo su - agent` drops terminal state | Run as ubuntu directly, no agent user |
| AVX-512 not active | Missing `RUSTFLAGS="-C target-cpu=native"` | Already set in all eval.sh scripts |
| Kept improvement later shows no gain | p-value borderline | Run 3 cross-session back-to-back runs |
| Agent modifies eval scripts | Scope not enforced | NEVER MODIFY constraint in program.md |
| Correctness pass but wrong output | Unit tests don't cover all edge cases | Run `verify_post_experiment.sh` |

---

## Experiment History

### Plonky3

| Experiment | Target | Result | Status |
|------------|--------|--------|--------|
| 1 | dft/src/ butterflies + DIT parallel | ~2.7% (74 iters) | Merged → Round1 PR |
| 2 | dft/src/ layer fusion | Invalid branch base | Discarded |
| 3 | dft/src/ continued | Wrong branch base | Discarded |
| 4-monty | monty-31 AVX-512 | 0.41% (p=0.23, weak) | Needs validation |
| exp2_monty_B_CLI | monty-31 AVX-512 port pressure | vpminud→vpcmpgeud: regression on Zen 4 | PR closed |
| exp2_monty_B_CLI | monty-31 AVX-512 arithmetic | In progress (Zen 4, c7a) | Running |

### leanMultisig

| Experiment | Target | Result | Status |
|------------|--------|--------|--------|
| 1 | Poseidon2 KoalaBear AVX-512 | — | Infrastructure ready, pending upstream merge |
| 2 | batched_air_sumcheck | — | Infrastructure ready |
