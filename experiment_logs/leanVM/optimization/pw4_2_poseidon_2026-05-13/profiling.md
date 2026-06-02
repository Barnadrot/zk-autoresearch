# pw4_2 — Initial profiling (read once at session start)

Source: distilled from `experiment_logs/leanMultisig/profiling/concluded/profiling_baseline_hetzner_2026-05-11/program.md` (the parent profiling experiment). Raw phase outputs from that experiment live in its gitignored `report/` subdir on brain — NOT synced to the executor. The distilled numbers in this file are the canonical reference for pw4_2.

**This profile decays after your first big keep (cumulative ≥ -3%).** When that happens, re-profile via the cheatsheet below; the fresh profile supersedes this file as your hot-symbol reference. Don't keep planning iterations from a stale picture.

## Conditions
- Hetzner CCX33-equivalent (Hetzner AX42-U, AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB, single CCD)
- Workload: `prove_loop 3` (3 proofs, 1550 sigs, log_inv_rate=1, zkalloc global, fat LTO)
- Baseline: `origin/main @ d080f3e2` (close to current `c868330c`; per-crate distribution is stable across recent main revisions)
- Capture: `perf record -F 997 --call-graph dwarf` + `perf stat`

## Top-line (parallel, 16-thread rayon pool, 3 proofs)

| Metric | Value |
|---|---:|
| Wall total | 11.75 s |
| Pure prove time (3 proofs) | 7.77 s |
| **IPC parallel** | **0.82** |
| **IPC serial** (RAYON_NUM_THREADS=1) | **1.29 ≈ Zen 4 `vpmuludq` mul-port ceiling** |
| Branch miss | 3.00% |
| L1D miss | 10.36% |
| LLC miss proxy | 6.47% |
| dTLB miss (subset) | 58.99% → ~3% of parallel cycles in PTW |
| Frontend stalls | 6.33% (not a bottleneck) |
| Parallel speedup (prove only) | 6.31× on 9.04 CPUs (70% efficient) |
| Per-core clock parallel | 4.156 GHz (vs 5.116 GHz serial — 19% throttle under parallel) |

**Workload classification:** mul-port-throughput-bound serial (IPC 1.29 ≈ ceiling), adds DRAM-bandwidth contention under parallel (LLC miss × ~50-cycle DRAM = ~15% of parallel cycles in memory waits). The prior "latency-bound by Montgomery dep chains" framing is REFUTED by serial IPC 1.29.

## Per-crate cycle distribution (parallel, re-attributed via Phase 7 of original profile)

| Subsystem | Share | What it is |
|---|--:|---|
| `mt_koala_bear` (Poseidon1 perm + Montgomery + AVX-512 packing) | **~27%** | dominant compute kernel |
| `lean_vm` (AIR tables — Poseidon, Execution) | **~13%** | AIR-side compute on same primitive |
| `mt_sumcheck` (product sumcheck rounds) | **~12%** | quintic-extension mul + add inner loop |
| `sub_protocols` (quotient-GKR sumcheck + air_sumcheck) | **~9%** | same shape, different protocol |
| `mt_whir` (DFT + open + commit) | **~7%** | FRI butterfly + linear combine |
| `mt_poly` (eq-MLE + multilinear utilities) | **~6%** | eq-poly construction for sumcheck |
| Kernel + rayon + framework + other | ~26% | page faults, atomics, dispatch, residual |

**Poseidon-touching subsystems** (mt_koala_bear + lean_vm AIR tables + mt_symetric merkle/sponge) = **~40-45% of cycles**. The dominant target.

**Adjacent-compute (sumcheck/eq-MLE) cluster** = mt_sumcheck + mt_poly + sub_protocols = **~27%**. Comparable to Poseidon in aggregate; becomes the dominant target after pw4-class Poseidon wins land.

## Top inclusive call-graph paths

1. `Poseidon1KoalaBear16::compress_mut` — **22.37% inclusive / 22.28% self**. Single dominant symbol. Top hot LINE is a stack spill `vmovdqa64 %zmm3, 0x780(%rsp,%rsi,1)` at 2.22% — register pressure inside the 16-state permutation is the binding constraint at this level.
2. `Poseidon1KoalaBear16::permute_simd::mds_fft` — 7.99% inclusive — MDS-as-FFT kernel
3. `PackedMontyField31AVX512::Mul + packing::mul` — 6.73% — Montgomery vector multiply
4. `eval_2_full_rounds_16` — 5.71% inclusive / 5.03% self — AIR-side first two rounds
5. `mt_sumcheck::fold_and_compute_product_sumcheck_polynomial` — 4.30% inclusive / 3.59% self
6. `mt_poly::eq_mle::eval_eq_with_packed_output` — 4.28% inclusive / 4.24% self
7. `mt_whir::merkle::first_digest_layer` + sponge `hash_slice` — ~5% combined (first Merkle layer hashing)

## Bottleneck-shape map (per pw4 confirmed)

| Lever class | Effect on Hetzner serial | Effect on Hetzner parallel |
|---|---|---|
| Mul-count reduction (algorithmic) | strong win | strong win |
| Mul-port-relief in `compress_mut` (register-pressure, scalar binding, scheduling) | strong win (pw4-13/15/19 confirmed) | strong win |
| Permutation-count reduction (sponge RATE, Merkle topology, leaf packing) | strong win | strong win |
| DRAM-bandwidth cache-blocking | small (serial isn't bandwidth-bound) | medium win (~15% slice) |
| `MADV_HUGEPAGE` on zk-alloc slabs | small | ~3% (dTLB walks) |
| Mul-count reduction in AIR symbolic path | NEGATIVE — symbolic builder regresses (pw4-8/14/20 all confirmed) | same |
| Rayon nesting cleanup / chunk-size tuning | NULL (HW prefetcher + chunk-size locally optimal) | NULL |
| Source-level wrappers / inline hints | NULL (LTO neutralizes) | NULL |

## Profiling cheatsheet (commands the agent should use freely)

Use these — don't just grep code, MEASURE before hypothesizing.

```bash
# Build with debug info for symbol-level profiling
CARGO_PROFILE_RELEASE_DEBUG=true RUSTFLAGS="-C target-cpu=native" \
  cargo build --release --bin prove_loop --features zkalloc_global

# Sampling profile + call graph
perf record -F 997 --call-graph dwarf -o /tmp/perf.data ./target/release/prove_loop 3
perf report -i /tmp/perf.data --stdio --no-children                  # leaf (self)
perf report -i /tmp/perf.data --stdio                                # children (inclusive)

# Line-level annotation of a hot symbol (find the exact instruction)
perf annotate -i /tmp/perf.data --stdio --symbol='Poseidon1KoalaBear16::compress_mut' | head -200

# Hetzner: enable perf for this session (idempotent, passwordless sudo configured)
sudo sysctl -w kernel.perf_event_paranoid=0 kernel.kptr_restrict=0

# Hardware counters (cycles, IPC, miss rates) — requires the sysctl above
perf stat -e cycles,instructions,branch-misses,L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses,dTLB-loads,dTLB-load-misses,stalled-cycles-frontend \
  ./target/release/prove_loop 3

# Serial vs parallel comparison (catches "is this compute-bound on this surface?")
RAYON_NUM_THREADS=1 ./target/release/prove_loop 3
RAYON_NUM_THREADS=16 ./target/release/prove_loop 3

# Cycle count for a specific function pre/post change (perf annotate after rebuild)
# Compare the hot-line shifts; if your change moves cycles OFF the targeted line
# but adds them ELSEWHERE in the same function, that's a wash.

# Flamegraph (visual, useful for big-picture pre-vs-post)
perf script -i /tmp/perf.data | inferno-collapse-perf | inferno-flamegraph > /tmp/flame.svg

# Disassemble a release binary symbol
objdump -d --disassembler-options=intel target/release/prove_loop \
  | awk '/<.*Poseidon1KoalaBear16.*compress_mut.*>:/,/^$/' | head -200
```

## When to re-profile

**Trigger re-profile when ANY of:**
- A keep lands with cumulative ≥ -3% vs origin/main
- Hot symbol distribution has materially shifted (e.g., `compress_mut` share drops below 15%)
- You're 5+ iterations in on the same hot symbol with no keep — re-profile to confirm the symbol is still the right target

After re-profile: write `report/profiling_after_iter_N.md` (gitignored in report/) with the new distribution. Reference THAT file, not this one, going forward.

## What's NOT in this file (intentionally)

- Per-line `perf annotate` dumps — too much detail; agent re-runs them per-hypothesis with the cheatsheet
- Allocator-pressure analysis — already factored into zk-alloc enablement; no further leverage here

If you need any of the above, the full profiling baseline experiment's `program.md` is at `experiment_logs/leanMultisig/profiling/concluded/profiling_baseline_hetzner_2026-05-11/program.md` (the raw phase outputs are NOT on the executor — they live on brain only). If you need fresh per-line data, re-run the cheatsheet commands above against the current binary.
