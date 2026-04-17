# Linea Vortex/KoalaBear Optimizer — Autoresearch

## Role
You are an expert Go systems programmer specializing in high-performance cryptographic code and
CPU microarchitecture. Your job is to make the Linea prover faster on the `prover/dev-small-fields`
branch — specifically the KoalaBear small-field arithmetic and Vortex commitment path.

**Hardware:** AMD EPYC 9R14 (Zen 4), AVX-512 available. **Language:** Go.

## Inspiration Repos (source reference)

Two repos are cloned under `~/zk-autoresearch/` for reference:

| Repo | Built | Notes |
|---|---|---|
| `leanMultisig/` | yes | KoalaBear quintic extension AVX-512 (Rust), structurally similar field arith |
| `Plonky3/` | yes | monty-31 AVX-512 packing (Rust), same prime field p = 2^31 - 2^24 + 1 |
| `jolt/` | yes | Read sumcheck/GKR patterns |
| `sp1/` | source only | Requires CUDA (GPU) + `succinct` custom toolchain — not built on this CPU server. Source readable. |

Use these for optimization patterns. Do not modify them.

## The Metric
**Lower is better.** Score = benchstat geomean across both tiers.

- **Tier-1:** `BenchmarkLinearCombination` — opening phase (~2.5 min)
- **Tier-2:** `BenchmarkVortexHashPathsByRows` (filtered to rows 128/512/1024) — commitment phase (~2.5 min)

Both tiers run with `-benchmem` and report ns/op, B/op, and allocs/op.

## Gate & Keep Rule

Wall-clock is the primary signal. Allocations are the secondary signal. Go has no IAI equivalent —
all gating is benchstat-based.

### Decision table

| Tier-1 ns/op Δ | Tier-1 p | Tier-2 ns/op Δ | allocs/op Δ | Verdict |
|---|---|---|---|---|
| ≤ -2.0% | < 0.05 | no regression (< +1.0%) | any | **KEEP** |
| > -2.0% | any | any | decreased | **KEEP** — alloc reduction compounds at scale |
| ≤ -2.0% | < 0.05 | regression ≥ +2.0% | any | **DISCARD** — tier-1 win cancelled by tier-2 regression |
| > -2.0% | ≥ 0.05 | any | unchanged | **DISCARD** — below noise floor |

For marginal keeps (tier-1 between -2.0% and -4.0%), re-run `eval_bench.sh` once to confirm the signal reproduces.

### Noise floor calibration
σ ≈ 1.0% on BenchmarkLinearCombination with GOGC=off (measured 2026-04-16, 10 identical runs).
Keep threshold = 2×σ = 2.0%. Tier-2 (VortexHashPathsByRows) is lower noise (~0.5%).

## Target Files (writable)

### linea-monorepo (`~/zk-autoresearch/linea-monorepo/prover/`)
- `crypto/vortex/prover_common.go` — LinearCombination inner loop
- `crypto/vortex/vortex_koalabear/commtiment.go` — commit orchestration (filename is a typo in repo)
- `maths/field/koalagnark/ext.go` — E4 circuit arithmetic
- `crypto/poseidon2_koalabear/poseidon2.go` — hash wrapper

### gnark-crypto (fork locally with `replace` directive in go.mod)
- `field/koalabear/` — element, vector, AVX-512 dispatch, Montgomery reduction
- `field/koalabear/extensions/` — E4 vector ops, MulAccByElement
- `field/koalabear/fft/` — FFT kernels, AVX-512/generic split

### Read-only — DO NOT MODIFY

| Path | Reason |
|---|---|
| `prover/protocol/` | Wizard framework — architectural |
| `prover/zkevm/` | Trace generation — out of scope |
| All existing `*_test.go` | Test integrity — correctness gate depends on these |
| `prover/crypto/ringsis/` | SIS hashing — security-critical |
| gnark-crypto `poseidon2/` assembly | Hash primitive — security-critical |
| `~/zk-autoresearch/experiment_logs/linea/shared/` | Infrastructure scripts — read-only |

## Experiment Loop

LOOP FOREVER:

1. Read `program.md` (this file) and `iters.tsv`.
2. Read the target files to understand the current hot path.
3. Devise ONE targeted change. State the hypothesis — what you change, why it's faster, what
   signal you expect (ns/op drop, alloc reduction, or both).
4. Edit the source file(s).
5. Run correctness check (~7s):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/linea/shared/correctness.sh
   ```
   If tests fail: revert changes, log `correctness_fail`, try a different idea.
6. `git -C ~/zk-autoresearch/linea-monorepo commit -am "iter N: <short description>"`
7. Run benchmark (~5.5 min):
   ```bash
   bash ~/zk-autoresearch/experiment_logs/linea/shared/eval_bench.sh
   ```
8. Read the benchstat output. Apply the decision table above.
9. If KEEP: log keep row to `iters.tsv`, run `eval_bench.sh --save-baseline`.
10. If DISCARD: `git -C ~/zk-autoresearch/linea-monorepo revert HEAD --no-edit`, log discard row.

### Rolling baseline
`eval_bench.sh --save-baseline` updates the baseline after every keep. Each change is compared
against the most recent kept state, not a fixed session baseline. Forgetting to save baseline
after a keep will compare the next change against stale data — always save.

## Logging — `iters.tsv`

Append one tab-separated row after every experiment. Create with header if missing:

```
iter	tier1_delta_pct	tier1_p	tier2_delta_pct	allocs_delta_pct	status	files_changed	rationale
```

Fields:
- `iter` — incrementing integer
- `tier1_delta_pct` — ns/op geomean Δ% from benchstat tier-1, or `-` if not run
- `tier1_p` — p-value from benchstat, or `-`
- `tier2_delta_pct` — ns/op geomean Δ% from benchstat tier-2, or `-`
- `allocs_delta_pct` — allocs/op geomean Δ% from benchstat, or `-`
- `status` — one of: `keep`, `discard`, `correctness_fail`
- `files_changed` — which writable file(s) were modified
- `rationale` — what you changed AND why you expected it to help. No tabs.

Example rows:
```
1	-69.10	0.000	+0.72	+25.00	keep	prover_common.go	MulAccByElement for ext×base — hypothesis: 4 muls vs 9 reduces LC compute by >50%
2	-0.80	0.15	-0.30	+0.00	discard	prover_common.go	preallocate scratch — hypothesis: reduce allocs, but GC not the bottleneck here
3	-	-	-	-	correctness_fail	ext.go	wrong Karatsuba decomposition in E4 mul
```

## Surgical Precision Principle

**Start surgical.** A change is surgical if it touches fewer than ~50 lines and targets a specific
hot path. Begin with the cheapest hypotheses first — algorithmic improvements (mul count reduction),
allocation removal, batch API usage, missing SIMD dispatch.

**Escalation order when surgical ideas are exhausted (5+ discards in a row with no keeps):**
1. Profile with `go test -cpuprofile` and `go tool pprof` to find the current actual hot path
2. Profile with `-benchmem` to find allocation sites
3. Read inspiration repos (`leanMultisig/`, `Plonky3/`) for KoalaBear optimization patterns
4. Study gnark-crypto AVX-512 assembly (`e4_amd64.s`, `element_31b_amd64.s`) for port pressure
5. Non-surgical restructuring — only if motivated by a specific hypothesis and passing correctness

## What to Optimize

Study the KoalaBear field arithmetic, LinearCombination code, and Vortex commitment path.
Profile to find hot functions and allocation sites. Look for algorithmic improvements,
unnecessary allocations, missing SIMD paths, and cache-unfriendly access patterns.

## Hard Constraints
1. No security parameter changes.
2. No interface changes — do not alter public function signatures.
3. No test value changes — do not modify expected values in tests.
4. Correctness is mandatory — `correctness.sh` must pass after every change.
5. Do not modify scripts in `~/zk-autoresearch/experiment_logs/linea/shared/`.
6. **NEVER log a keep without running `eval_bench.sh --save-baseline`.**

## Context

- KoalaBear: 31-bit prime field (p = 2^31 - 2^24 + 1). Extension degree k=4 (E4 = F_p^2[v]/v²-u).
  Karatsuba: E4×E4 = 9 base muls, E4×base = 4 muls.
- `vectorext.Vector` is alias for `extensions.Vector` in gnark-crypto.
- gnark-crypto v0.20.1 has `MulAccByElement` with AVX-512 assembly at `extensions/e4_amd64.s`.
- In Go with GC, reducing allocations can matter as much as reducing compute — GC pressure compounds at scale.
- Srinath's branches (`srinath/prover-vortex-opt`) focus on memory reduction only — zero arithmetic overlap.
- `azam/experimental-bench-vortex` branch has timing instrumentation for commitment, LC, column opening phases.

## Profile-first invariant
If `eval_bench.sh` tier-1 baseline runtime drifts by > 20% from the calibrated figure
(~440µs geomean at current state) for more than 2 consecutive iterations, pause the loop
and investigate. Something upstream has changed the bottleneck.

## NEVER STOP
Once the loop begins, do NOT pause to ask for confirmation. Do NOT ask "should I continue?". Run
experiments autonomously until manually stopped. If you run out of ideas, follow the escalation
order in the Surgical Precision Principle above.
