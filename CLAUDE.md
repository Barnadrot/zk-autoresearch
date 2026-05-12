# zk-autoresearch

Automated ZK prover optimization research across multiple proving systems.

## Repo Map

```
harness/                          Benchmark + correctness tooling (per target repo)
├── plonky3/
│   ├── bench/                    Rust crate: Poseidon1, Poseidon2, Keccak benchmark bins
│   ├── correctness/              Rust crate: bitwise-identical DFT validator
│   └── scripts/                  eval.sh, correctness.sh
├── leanmultisig/
│   ├── bench/                    Rust crate: prove_loop binary + Criterion benchmarks
│   ├── correctness/              correctness.sh, test_integrity.sha256
│   └── scripts/                  eval_paired.sh, eval_gate.sh, eval_iai.sh, config.env
├── vortex/
│   ├── correctness/              correctness.sh
│   └── scripts/                  eval_bench.sh, noise_floor.sh, config.env
└── gnark-crypto/                 Placeholder (benchmarked indirectly via Vortex)

experiment_logs/                  Audit trail — append-only
├── Plonky3/NTT/                  NTT/DFT butterfly + Montgomery arithmetic experiments
│   ├── active/CLAUDE.md          Current agent instructions for Plonky3 experiments
│   └── experiment_*/             Completed experiment data
├── leanMultisig/                 Sumcheck, Poseidon, LogUp, allocator experiments
├── linea/                        Vortex/KoalaBear experiments
└── zk-alloc/                     Arena allocator research (cross-prover)
    ├── multi-prover-bench/       Results: Plonky3, leanMultisig, Jolt
    └── report/                   Analysis docs (future_optimum.md, multiprover-sunday.md)

scripts/
├── setup/                        Server provisioning scripts
│   ├── server.sh                 Base: Rust, build tools, Claude CLI
│   ├── zk_alloc.sh              zk-alloc experiments: cgroups, reference repos
│   ├── leanmultisig.sh          leanMultisig: clone, build, bench crate
│   └── linea.sh                 Linea/Vortex: clone, Go toolchain
├── run_benchmark.sh              Cross-branch Criterion comparison (CRITICAL: uses -C target-cpu=native)
└── watch.py                      Live experiment monitor (reads iters.tsv or experiments.jsonl)

.github/workflows/
└── ci.yml                        Build all harness crates on push/PR
```

## External Repos (gitignored, cloned locally)

These are the target repos being optimized. They are NOT part of this repo — clone them per setup scripts.

| Directory | Repo | Purpose |
|-----------|------|---------|
| `plonky3/` | Plonky3/Plonky3 | ZK proving framework (BabyBear, FRI) |
| `leanMultisig/` | maceip/leanMultisig | XMSS aggregation prover (Plonky3/WHIR) |
| `jolt/` | a16z/jolt | Jolt zkVM (sumcheck/Dory, BN254) |
| `zk-alloc/` | Barnadrot/zk-alloc | Bump+reset arena allocator crate |
| `mimalloc/`, `snmalloc/`, `glibc-malloc/` | — | Reference allocator source for study |
| `sp1/` | succinctlabs/sp1 | SP1 zkVM (future target) |

## Agentic ZK Development Principles

1. **Commit-eval-decide.** Make one change, commit it, run correctness then performance gates, keep or revert. Every commit is either a kept improvement or a reverted attempt — no uncommitted experiments.
2. **Profile before optimizing.** Every assumption skipped profiling on was wrong.
3. **Negative results are results.** A null result on the right system validates the theory as much as a positive result.
4. **Cross-system validation.** Test the same idea on multiple provers. One prover is an anecdote, three is a pattern.
5. **The bottleneck determines the approach.** Memory-bound vs compute-bound dictates everything. Identify which before choosing a strategy.
6. **Measure, don't assume.** Every received wisdom gets a benchmark.
7. **One change per iteration.** Isolation is critical for attribution.
8. **Correctness is non-negotiable.** Always verify proofs cryptographically.
9. **Ship incrementally.** Feature flag first, default later.
10. **Don't chase convergence.** If optimizing X makes your system look like Y, you're rebuilding Y poorly. Find the local optimum for your architecture.

## Experiment Structure

Each experiment lives under `experiment_logs/<project>/<experiment_name>/` and contains:

- **`program.md`** — Agent instructions: role, hardware, baseline, target files, writable scope, constraints, eval gates. This is the prompt fed to Claude Code.
- **`iters.tsv`** — Tab-separated iteration log: iter number, delta %, decision (keep/discard), commit hash, rationale. Append-only.
- **Experiment-specific scripts** — e.g., `reproduce_prod.sh`, `reproduce_iter18.sh`. These stay with the experiment.

Shared eval scripts (correctness gates, benchmark gates, config) live in `harness/<project>/scripts/`.

## Running an Experiment

```bash
# 1. Set up server (run once)
bash scripts/setup/server.sh
bash scripts/setup/<project>.sh

# 2. Start tmux session
tmux new-session -s autoresearch

# 3. Run Claude Code with the experiment program
claude --prompt-file experiment_logs/<project>/<experiment>/program.md

# 4. Monitor from another terminal
python3 scripts/watch.py experiment_logs/<project>/<experiment>/iters.tsv
```

## Eval Gate Convention

Every experiment defines correctness and performance gates:

1. **Correctness gate** — Must pass before any benchmark runs. Binary: pass or discard.
   - Plonky3: `harness/plonky3/correctness/` (Rust crate, bitwise comparison)
   - leanMultisig: `harness/leanmultisig/correctness/correctness.sh`
   - Vortex: `harness/vortex/correctness/correctness.sh`

2. **Performance gate** — Paired A/B wall-clock or IAI (instruction count) comparison.
   - Config thresholds in `harness/<project>/scripts/config.env`
   - `eval_paired.sh` for wall-clock, `eval_iai.sh` for instruction count
   - Two-tier gating: fast tier every iteration, slow tier on keeps only

## Key Conventions

- **Commit-eval-decide loop.** Every iteration follows the same discipline:
  1. Make one targeted change
  2. Commit it (clean hash in the audit trail)
  3. Run correctness gate, then performance gate
  4. If both pass: keep. Otherwise: `git revert` (not reset — the revert is also in the log)
  
  This produces a linear, reviewable history where every commit is either a kept improvement or a reverted attempt. No uncommitted experiments, no squash-and-pray.

- **RUSTFLAGS:** Always `RUSTFLAGS="-C target-cpu=native"` when benchmarking. Without it, no AVX-512 — measurements silently 2x slower.
- **cargo nextest** for Jolt (never cargo test). Standard cargo test for Plonky3 and leanMultisig.
- **Experiment logs are append-only.** Never delete or modify past experiment data.
- **One change per iteration.** Agent proposes one targeted change, eval gates decide keep/discard.
- **Reports stay local.** `report/` folders are gitignored — saved to Nextcloud manually, never committed.

## Agent Git Protocol (ABSOLUTE — applies to every dispatched experiment)

Two experiment shapes; different git discipline for each.

### Shape A — Optimization (commit-eval-decide loop)

The agent modifies source, evaluates, keeps or reverts. Commits ARE the audit trail.

1. **Find your branch name.** Read `brain/queue/active/<id>.json`'s `branch` field. That is the branch you commit on. Coordinator has already checked it out for you before launching claude.
2. **Never commit to `main`.** If `git rev-parse --abbrev-ref HEAD` returns `main`, you must `git checkout <branch>` before your first commit.
3. **Commit per iteration on the experiment branch.** That's the canonical audit trail. Failed iterations get `git revert`, not `git reset` — the revert is also in the log.
4. **Do NOT `git push`.** Brain pushes after reviewing the verdict.
5. **Leave Cargo.lock alone** unless the experiment explicitly tracks lockfile movement.

### Shape B — Profiling / measurement (read-only)

No source changes. The agent writes data files to the experiment dir; that's the artifact. **There is no commit-per-phase rule** — committing the data files is what caused the executor-divergence bug on 2026-05-12.

1. **Do not commit anything.** Not the program.md you read, not your phase output files, not Cargo.lock, not any branch checkout. Stay on `main` and never write a commit.
2. **Write your phase outputs as files in the experiment dir.** That's the audit trail: file contents and mtimes.
3. **Bulky raw data goes in `report/`.** Any single file >1 MB (perf.data, sample(1) txt output, xctrace .trace bundle and .xml export, powermetrics raw txt, flamegraph collapsed stacks, profile traces) MUST land in a `report/` subfolder of the experiment dir. The `experiment_logs/**/report/` path is gitignored — files there stay local; coordinator rsyncs them back to brain. Only summary `.md`, `.tsv`, and small logs (<200 KB) go in the top dir.
4. **Do NOT `git push`.** Brain commits the summary artifacts after reviewing your verdict.

### Both shapes

If the program.md contradicts this protocol (e.g., a profiling experiment that says "commit per phase"), treat that as a program.md bug — follow this protocol instead and note the conflict in your verdict.

Coordinator handles pre-dispatch sync: `git pull` and (for Shape A) `git checkout <branch>`. By the time claude starts, the tree is in the right state — you just do the work.
