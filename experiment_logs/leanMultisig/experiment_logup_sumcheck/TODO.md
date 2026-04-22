# Experiment 3: Logup + Sumcheck + AIR — Setup TODO

## Done
- [x] Write program.md (with exp 2 dead ends, air constraints, 21 iteration directions)
- [x] Create iters.tsv with header
- [x] Experiment 2 finished (10 iters, 0 keeps, report written)
- [x] Bake experiment 2 dead ends + recommendations into program.md

## Before launch (on server)

### 1. Decide: isolated benchmark or e2e gating?
**Option A — Write isolated logup benchmark** (better signal, more setup)
- Add `bench_logup` to `leanMultisig-bench/`
- Benchmark full `prove_generic_logup` (data prep + GKR sumcheck + post-GKR eval)
- Need realistic setup: traces, tables, alphas at production sizes (1400 sigs)
- Then characterize noise floor (10 identical runs, set threshold = 2x sigma)

**Option B — Use e2e with existing gate** (no setup, weaker signal)
- Same `eval_gate.sh` as experiments 1+2
- 1.0% wallclock-only threshold for logup/air changes
- iai gate works for sumcheck-layer changes
- Can start immediately

**Recommendation:** Start with Option B to get first iterations running fast. Write
isolated benchmark as iter 0 if signal is too noisy on e2e.

### 2. Create branch
```bash
cd ~/zk-autoresearch
git checkout -b leanmsig_logup_sumcheck
git add experiment_logs/leanMultisig/experiment_logup_sumcheck/
git commit -m "experiment 3: logup + sumcheck + air combined setup"
git push --set-upstream origin leanmsig_logup_sumcheck
```

### 3. Pull on server
```bash
cd ~/zk-autoresearch
git fetch origin
git checkout leanmsig_logup_sumcheck
```

### 4. Profile air constraint surface (first thing agent does)
```bash
cd ~/zk-autoresearch/leanMultisig-bench
perf record -F 99 -g --call-graph=dwarf -o /tmp/perf_exp3.data -- \
    target/release/deps/xmss_leaf-* --bench xmss_leaf_1400sigs --profile-time 20
perf report -i /tmp/perf_exp3.data --no-children --sort=symbol --stdio | head -40
```
Focus on: ConstraintFolderPacked, assert_zero, alpha broadcasting, Air::eval

### 5. Launch agent
```bash
cd ~/zk-autoresearch
claude --dangerously-skip-permissions --model claude-opus-4-6
```
Then paste the experiment prompt pointing at `experiment_logup_sumcheck/program.md`.

## Key references
- `experiment_sumcheck_deep/report/report.md` — exp 2 final report with 3 recommendations
- `experiment_sumcheck_deep/iters.tsv` — 10 dead ends to avoid
- `leanMultisig/TODO.md` — Emile's roadmap
- `leanMultisig/crates/backend/air/` — NEW writable target (91% of sumcheck compute)
