# pw3 PR Benchmark Results

**Date:** 2026-05-08
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, Zen 4, 8c/16t, 64GB RAM, AVX-512)
**Workload:** `fancy-aggregation --json` (production topology, 12 nodes)
**Runs per binary:** 5
**Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release` (clean per binary)

Total time = sum of all node `time_secs` per run; proof size = sum of all node `proof_kib`.

## Per-Binary Results

| SHA | Description | Mean (s) | Stddev (s) | Min (s) | Max (s) | Proof (KiB) |
|-----|-------------|---------:|-----------:|--------:|--------:|------------:|
| `19f1c774` | main (baseline) | 16.8620 | 0.0091 | 16.8482 | 16.8733 | 2572.8 |
| `a6b3e553` | InternalLayer16 elim | 16.8702 | 0.0187 | 16.8516 | 16.8979 | 2572.4 |
| `b3213c11` | Parallel stacking | 16.9000 | 0.0107 | 16.8847 | 16.9138 | 2572.6 |
| `a2dc0cfe` | FFT MDS | 17.3634 | 0.0152 | 17.3487 | 17.3866 | 2572.0 |
| `bdf43a62` | RATE=12 + zk-DSL | 17.6726 | 0.1436 | 17.5603 | 17.8688 | 2577.6 |
| `4175b20a` | MMO feedforward | 19.1933 | 0.0255 | 19.1709 | 19.2266 | 2623.0 |

## Per-Commit Deltas

| Change | Baseline Mean (s) | Candidate Mean (s) | Δ% | Description |
|--------|------------------:|-------------------:|---:|-------------|
| 1 vs 0 | 16.8620 | 16.8702 | +0.05% | InternalLayer16 copy elim |
| 2 vs 1 | 16.8702 | 16.9000 | +0.18% | Parallel stacking |
| 3 vs 2 | 16.9000 | 17.3634 | +2.74% | FFT MDS |
| 4 vs 3 | 17.3634 | 17.6726 | +1.78% | RATE=12 |
| 5 vs 4 | 17.6726 | 19.1933 | +8.60% | MMO feedforward |
| **5 vs 0** | 16.8620 | 19.1933 | **+13.83%** | Full bundle |

## Proof Size Comparison (main vs bundle)

| Node path | main (KiB) | bundle (KiB) | Δ% |
|-----------|-----------:|-------------:|---:|
| `0.0.0.0` | 339.0 | 343.2 | +1.24% |
| `0.0.0.1` | 206.0 | 208.0 | +0.97% |
| `0.0.0` | 190.0 | 206.6 | +8.74% |
| `0.0.1.0` | 226.6 | 229.8 | +1.41% |
| `0.0.1.1` | 205.6 | 208.6 | +1.46% |
| `0.0.1` | 194.4 | 190.8 | -1.85% |
| `0.0` | 279.2 | 289.8 | +3.80% |
| `0.1.0` | 206.2 | 208.2 | +0.97% |
| `0.1.1` | 205.4 | 208.4 | +1.46% |
| `0.1` | 194.8 | 191.4 | -1.75% |
| `0` | 196.2 | 209.0 | +6.52% |
| `root` | 129.4 | 129.2 | -0.15% |
| **Total** | **2572.8** | **2623.0** | **+1.95%** |

## Outlier Check

No individual run exceeded 2σ from its binary's mean, so no extra runs were collected.

`bdf43a62` (RATE=12) shows materially higher variance than the other binaries (σ=0.144s vs ~0.01–0.03s elsewhere). Inspecting its 5 runs, the first three cluster near 17.57s and the last two near 17.85s — a step pattern rather than a single outlier. This may reflect cache state or SMT scheduling noise during that block. The pattern does not change the sign or order-of-magnitude of the delta (`bdf43a62` is unambiguously slower than `a2dc0cfe`).

## Raw Data — total_time_secs per run

```
19f1c774 (main (baseline)          ): [16.8482, 16.8633, 16.8602, 16.8648, 16.8733]
a6b3e553 (InternalLayer16 elim     ): [16.8802, 16.8592, 16.8516, 16.8622, 16.8979]
b3213c11 (Parallel stacking        ): [16.9023, 16.9138, 16.9031, 16.8847, 16.8962]
a2dc0cfe (FFT MDS                  ): [17.3487, 17.3604, 17.3523, 17.3692, 17.3866]
bdf43a62 (RATE=12 + zk-DSL         ): [17.5652, 17.5603, 17.5854, 17.7834, 17.8688]
4175b20a (MMO feedforward          ): [19.1826, 19.1723, 19.2143, 19.1709, 19.2266]
```

## Per-Node Mean Time (s) — main vs bundle

| Node path | main (s) | bundle (s) | Δ% |
|-----------|---------:|-----------:|---:|
| `0.0.0.0` | 2.1657 | 2.2613 | +4.41% |
| `0.0.0.1` | 1.3423 | 1.3235 | -1.40% |
| `0.0.0` | 1.2383 | 1.9181 | +54.90% |
| `0.0.1.0` | 2.8796 | 2.9423 | +2.18% |
| `0.0.1.1` | 1.3343 | 1.3170 | -1.30% |
| `0.0.1` | 0.8497 | 1.1370 | +33.81% |
| `0.0` | 0.9633 | 1.0133 | +5.19% |
| `0.1.0` | 1.4234 | 1.4459 | +1.58% |
| `0.1.1` | 1.4251 | 1.4460 | +1.46% |
| `0.1` | 0.8533 | 1.1306 | +32.50% |
| `0` | 1.3627 | 1.9963 | +46.49% |
| `root` | 1.0241 | 1.2622 | +23.25% |
| **Total** | **16.8620** | **19.1933** | **+13.83%** |

## Observations

- **The full bundle is a regression of +13.83%** on the production `fancy-aggregation` workload; every successive commit in the PR is slower than its predecessor.
- The first two commits (`a6b3e553` InternalLayer16 elim, `b3213c11` parallel stacking) are within run-to-run noise (+0.05% and +0.18%).
- The three later commits each contribute material time: `a2dc0cfe` FFT MDS (+2.74%), `bdf43a62` RATE=12 (+1.78%), `4175b20a` MMO feedforward (+8.60%).
- Per-node breakdown shows the regression is concentrated in **inner aggregation nodes** (`0.0.0`, `0.0.1`, `0.1`, `0`, `root`) which range +23% to +55% in the bundle, while the **leaf XMSS nodes** (`*.0`, `*.1`) regress only ~1–4% or are flat. This is consistent with the RATE=12 / MMO-sponge / FFT-MDS changes affecting recursion-heavy paths most.
- Proof size grew from 2572.8 KiB to 2623.0 KiB (+1.95% total), with the largest per-node growth on `0.0.0` (+8.74%) and `0` (+6.52%).
- Build artifacts: all 6 binaries had distinct md5 hashes (see `/tmp/build_log.txt`).

## Reproducing

```bash
# Builds (clean release per binary, AVX-512 enabled)
export RUSTFLAGS="-C target-cpu=native"
for sha in 19f1c774 a6b3e553 b3213c11 a2dc0cfe bdf43a62 4175b20a; do
  git checkout $sha
  cargo clean --release
  cargo build --release --bin lean-multisig
  cp target/release/lean-multisig /tmp/bench_${sha}
done

# Benchmarks (5 runs per binary, all 5 runs of one binary before next)
for sha in 19f1c774 a6b3e553 b3213c11 a2dc0cfe bdf43a62 4175b20a; do
  for run in 1 2 3 4 5; do
    /tmp/bench_${sha} fancy-aggregation --json >> /tmp/bench_results_${sha}.jsonl
  done
done
```
