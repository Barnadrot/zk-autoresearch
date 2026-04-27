# zk-autoresearch

Automated ZK prover optimization research. Profile-guided experiments across multiple proving systems, using Claude as the optimization agent.

**Method:** For each target, an agent receives a focused program (constraints, eval gates, writable scope), proposes one change per iteration, and keeps it only if it passes correctness + performance gates. All iterations are logged.

**Hardware:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 64GB DDR5) and Hetzner CCX33 (AMD EPYC, 8C, AVX512).

---

## Results

### leanMultisig

Target: [leanMultisig](https://github.com/maceip/leanMultisig) — XMSS signature aggregation prover (Plonky3/WHIR-based, BabyBear field).

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| zk-alloc | Bump+reset arena allocator | **-27% warm proof** (3.3s → 2.3s) | PR open, under review |
| sumcheck_deep | Sumcheck inner loop optimizations | 10 iterations, no kept improvements | Completed |
| logup_sumcheck | LogUp + sumcheck optimizations | Multiple iterations | Completed |
| logup_sumcheck_v2 | LogUp v2 refined approach | Multiple iterations | Completed |
| poseidon_whir | Poseidon/WHIR optimization | Multiple iterations | Completed |
| poseidon | Poseidon permutation optimization | Multiple iterations | Completed |

### Plonky3

Target: [Plonky3](https://github.com/Plonky3/Plonky3) — ZK proving framework. Optimization target: `coset_lde_batch` NTT/DFT on BabyBear 2^20 × 256, `Radix2DitParallel`.

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| Round 1 (experiment_1) | AVX512 butterfly loop optimizations | **+2.1% to +10.4%** across sizes | 6 improvements in 74 iterations |
| Round 2 (experiment_2_monty) | Montgomery field arithmetic (AVX512) | Multiple iterations | Completed |

**Round 1 detail:**

| Transform Size | Baseline | Optimized | Gain |
|----------------|----------|-----------|------|
| 2^14 (~16K) | 58.7ms | 51.9ms | +10.4% |
| 2^16 (~64K) | 177.2ms | 173.5ms | +2.5% |
| 2^18 (~256K) | 691.8ms | 677.7ms | +2.1% |
| 2^20 (~1M) | 2756ms | 2699ms | +2.1% |
| 2^22 (~4M) | 11925ms | 11021ms | +8.2% |

### Vortex / gnark-crypto

Target: [Linea Vortex prover](https://github.com/Consensys/linea-monorepo) (KoalaBear field) and [gnark-crypto](https://github.com/Consensys/gnark-crypto) (Go, upstream dependency).

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| vortex_koalabear | Vortex prover optimizations | In progress | Active |

---

## Repository Structure

```
zk-autoresearch/
├── harness/                       Benchmark + correctness tooling per target
│   ├── plonky3/
│   │   ├── bench/                 Plonky3 benchmark crate (Poseidon1/2, Keccak)
│   │   ├── correctness/           Bitwise-identical DFT validation crate
│   │   └── scripts/               eval.sh, correctness.sh
│   ├── leanmultisig/
│   │   ├── bench/                 prove_loop + Criterion benchmarks
│   │   ├── correctness/           correctness.sh, test_integrity.sha256
│   │   └── scripts/               eval_paired.sh, eval_gate.sh, config.env, ...
│   ├── vortex/
│   │   ├── correctness/           correctness.sh
│   │   └── scripts/               eval_bench.sh, noise_floor.sh, config.env
│   └── gnark-crypto/              Placeholder (currently benchmarked via Vortex)
│
├── experiment_logs/               Audit trail — append-only, never delete
│   ├── Plonky3/NTT/              NTT/DFT optimization experiments
│   ├── leanMultisig/             Sumcheck, Poseidon, LogUp, allocator experiments
│   ├── linea/                    Vortex/KoalaBear experiments
│   └── zk-alloc/                 Arena allocator research (multi-prover)
│
├── scripts/
│   ├── setup/                    Server provisioning (server.sh, zk_alloc.sh, ...)
│   ├── run_benchmark.sh          Cross-branch Criterion comparison
│   └── watch.py                  Live experiment monitor (iters.tsv + jsonl)
│
└── .github/workflows/            CI: build harness crates, regression gates
```

### External repos (cloned locally, gitignored)

| Directory | Repo | Role |
|-----------|------|------|
| `plonky3/` | Plonky3/Plonky3 | Optimization target |
| `leanMultisig/` | maceip/leanMultisig | Optimization target |
| `jolt/` | a16z/jolt | Benchmarked (zk-alloc null result) |
| `zk-alloc/` | Barnadrot/zk-alloc | Standalone arena allocator crate |
| `mimalloc/`, `snmalloc/`, `glibc-malloc/` | Reference allocators | Study material |
| `sp1/` | succinctlabs/sp1 | Future target |

---

## Running Experiments

Experiments run via Claude Code CLI in a tmux session. Each experiment has:
- `program.md` — Agent instructions (role, target, constraints, eval gates)
- `iters.tsv` — Iteration log (hash, delta, decision, rationale)
- Eval scripts in `harness/<project>/scripts/`

```bash
# Start a tmux session for the experiment
tmux new-session -s autoresearch

# Run Claude Code with the experiment program
claude --prompt-file experiment_logs/<project>/<experiment>/program.md
```

Monitor from another terminal:
```bash
python3 scripts/watch.py experiment_logs/<project>/<experiment>/iters.tsv
```

---

## Development

Enable the pre-commit hook:
```bash
git config core.hooksPath .githooks
```

### Critical: RUSTFLAGS for benchmarking

Always set `RUSTFLAGS="-C target-cpu=native"` when benchmarking. Without it, no AVX-512 — measurements are silently 2x slower.
