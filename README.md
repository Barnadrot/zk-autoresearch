# zk-autoresearch

Automated ZK prover optimization research. Profile-guided experiments across multiple proving systems, using Claude as the optimization agent.

**Method:** For each target, an agent receives a focused program (constraints, eval gates, writable scope), proposes one change per iteration, and keeps it only if it passes correctness + performance gates. All iterations are logged.

**Hardware:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 64GB DDR5), Hetzner CCX33 (AMD EPYC, 8C, AVX512), and AWS c7a.2xlarge (AMD EPYC Genoa, 8 vCPU, AVX512).

---

## Results

*The tables below report optimization gains measured and merged in upstream repos. If you believe any measurement methodology could be improved, please [open an issue](../../issues) with a suggested adjustment.*

### Plonky3

Target: [Plonky3](https://github.com/Plonky3/Plonky3) — ZK proving framework. Optimization target: `coset_lde_batch` NTT/DFT on BabyBear 2^20 × 256, `Radix2DitParallel`.

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| [NTT butterfly (PR #1492)](https://github.com/Plonky3/Plonky3/pull/1492) | Butterfly micro-optimizations for Radix2DitParallel | **2.1%–10.4%** across sizes | **Merged** |
| [Bench fix (PR #1575)](https://github.com/Plonky3/Plonky3/pull/1575) | `iter_batched` to exclude clone cost from DFT measurement | 42% of measured time was `Vec::clone`, not FFT | **Merged** |
| [AVX-512 Montgomery + butterfly (PR #1555)](https://github.com/Plonky3/Plonky3/pull/1555) | `vpminud` reduction, drop `confuse_compiler`, manual unroll | **~3.3%** faster `coset_lde_batch` on Zen 4 | *Pending* |

### leanMultisig

Target: [leanMultisig](https://github.com/maceip/leanMultisig) — XMSS signature aggregation prover (Plonky3/WHIR-based, BabyBear field).

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| [Inline quintic extension (PR #197)](https://github.com/leanEthereum/leanMultisig/pull/197) | `#[inline(always)]` on quintic field arithmetic | **-3.6%** on `xmss_leaf_1400sigs` | **Merged** |
| [Degree-split AIR sumcheck (PR #202)](https://github.com/leanEthereum/leanMultisig/pull/202) | Skip partial-round constraints at high z-points | **-7.64%** on `fancy-aggregation` (Hetzner AX42-U) | **Merged** |
| [Alloc contention + STIR tiling (PR #203)](https://github.com/leanEthereum/leanMultisig/pull/203) | Eliminate alloc contention, L2-tiled STIR equality | **-10.3%** on `fancy-aggregation` (3/4 changes merged as independent commits) | **Merged** |
| [zk-alloc arena allocator (PR #205)](https://github.com/leanEthereum/leanMultisig/pull/205) | Bump+reset arena allocator | **-27% warm proof** (3.3s → 2.3s) | *Pending* |

### Vortex / gnark-crypto

Target: [Linea Vortex prover](https://github.com/Consensys/linea-monorepo) (KoalaBear field) and [gnark-crypto](https://github.com/Consensys/gnark-crypto) (Go, upstream dependency).

| Experiment | Optimization | Result | Status |
|-----------|-------------|--------|--------|
| [LinearCombination + commitment hashing (PR #2898)](https://github.com/Consensys/linea-monorepo/pull/2898) | MulAccByElement, eliminate copy, MDHasher buffer reuse, Compressx16 SIMD | **-72%** LinearCombination, **-17%** commitment hashing, **-99.9%** allocs | **Merged** |
| [FFT kernels + SIS LimbIterator (gnark-crypto PR #834)](https://github.com/Consensys/gnark-crypto/pull/834) | Unrolled FFT64/128 kernels, inline small-m stages, LimbIterator devirtualization | **-56%** SIS ns/op, **-98%** SIS allocs | *Pending* |

*Vortex results are microbenchmark measurements on AWS c7a.2xlarge (8 vCPU, 16GB). Production infrastructure operates at significantly larger scale and was not available for end-to-end benchmarking; actual production impact may differ.*

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
