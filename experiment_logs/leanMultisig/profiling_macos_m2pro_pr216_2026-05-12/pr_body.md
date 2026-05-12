# PR #216 macOS M2 Pro confirmation

PR #216 (`perf/poseidon-fft-mmo`) was previously validated on M2 Asahi Linux (−6.64%) and Hetzner Zen 4 (−5.58%). This is the third-machine confirmation on the production target OS — macOS Sequoia on M2 Pro silicon.

## Numbers

**Paired N=5 alternating order on `prove_loop 5`, after `sudo purge`, both binaries built with `RUSTFLAGS="-C target-cpu=native" --features zkalloc_global`:**

| Round | main (s) | PR #216 (s) | Δ |
|:-:|--:|--:|--:|
| 1 | 16.54 | 15.51 | −6.23% |
| 2 | 16.48 | 15.70 | −4.73% |
| 3 | 16.58 | 15.78 | −4.83% |
| 4 | 16.55 | 15.63 | −5.56% |
| 5 | 16.50 | 15.86 | −3.88% |

**Mean Δ = −5.05% ± 0.89%** (sample stddev, n=5). Per-warm-proof (incremental N=5−N=1): main 2.50 s → PR #216 2.38 s.

Cross-machine:

| | Hetzner Zen 4 | M2 Asahi Linux | M2 macOS Sequoia |
|---|--:|--:|--:|
| Paired Δ | −5.58% | −6.64% | **−5.05% ± 0.89%** |
| warm-proof main | 2.002 s | 2.558 s | 2.50 s |
| warm-proof PR #216 | ≈1.890 s | ≈2.388 s | 2.38 s |

## Methodology

- **Host:** Scaleway M2-L (Apple M2 Pro, Mac14,12), macOS Sequoia 15.6.1 (24G90), Darwin 24.6.0 arm64.
- **Binaries:** `origin/main` @ `d080f3e2` vs `myfork/perf/poseidon-fft-mmo` @ `3441e3a9`. Distinct MD5s confirmed.
- **Memory hygiene:** `sudo purge` before each measurement-bearing phase.
- **Profiling stack (macOS-native):** `sample(1)` for self-time, `xctrace --template "Time Profiler"` for inclusive call-tree + P/E breakdown, `powermetrics --samplers cpu_power` for per-cluster frequency/residency/power.

## Attribution (where the wins land)

PR #216's leverage is concentrated entirely in `Poseidon1KoalaBear16::compress_mut`:

| Symbol (self-time, sample(1)) | main | PR #216 | Δ |
|---|--:|--:|--:|
| `Poseidon1KoalaBear16::compress_mut` | 14,591 | 13,115 | **−10.1%** |
| `Poseidon1KoalaBear16::permute_mut` | 2,247 | 2,244 | flat |
| `Poseidon16Precompile::eval` (AIR) | 1,320 | 1,319 | flat |
| AIR-side full-round evaluators | 5,236 | 5,481 | +5% (noise) |

This is the signature of a RATE 8→12 sponge rebalance: fewer compression invocations per leaf, AIR untouched. Consistent across all three target machines.

## Profile context (PR #216 binary, xctrace + sample(1))

- **Poseidon inclusive share: 52.5%** (xctrace inclusive) / 50.9% (sample(1) self-of-active) — disproves the 35-40% prediction, consistent with Asahi 57.85%.
- **`compress_mut` alone is 30.3% inclusive** — the single largest leaf in the proof.
- **P/E heterogeneity tax: 18.2%** (xctrace thread-time per core), vs ~13% on Asahi. macOS scheduler runs all 10 rayon workers as Default QoS with no P-affinity — work stealing is uniform (53.3-53.8% Poseidon-inclusive per worker), so E-cores set the tail latency. *Tractable separate macOS optimization, out of scope for this PR.*
- **Steady-state power: 27 W CPU package** (peak 30.3 W), all three clusters >90% residency at peak frequency. No throttling on this 16 s workload.

## mach-vm / zk-alloc on macOS

- **zk-alloc works on macOS** without the 687ec5cc MAP_NORESERVE cherry-pick required on Asahi.
- No `mach_vm_allocate` errors, no `vm_fault` symbols in the hot path.
- No M1-era 12× regression reproduces on M2 Pro Sequoia at this scale.

## Verdict

PR #216 is portable: **−5.58% Hetzner / −6.64% Asahi / −5.05% macOS — all in family**. The macOS path is healthy. Ship.

Full audit trail: `experiment_logs/leanMultisig/profiling_macos_m2pro_pr216_2026-05-12/`
- `phase_0_smoke.md` through `phase_5_cross_machine.md` per-phase deliverables
- `profiling_macos_m2pro_pr216_report.md` synthesis
- `phase_2_sample_*.txt`, `phase_3_time_profiler.trace`, `phase_4_powermetrics.txt` raw artifacts
- `parse_xctrace.py` reusable parser (resolves xctrace's frame-deduplication, which initially threw off Poseidon attribution 6×)
