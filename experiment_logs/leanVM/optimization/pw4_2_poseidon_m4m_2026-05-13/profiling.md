# pw4_2-m4m — Initial profiling (read once at session start)

Source: distilled from `experiment_logs/leanMultisig/profiling/concluded/profiling_macos_m4m32_pr216_2026-05-12/program.md` and its `summary_note.md` + `phase_2_hot_symbols.md` (the parent profiling experiment on this exact hardware). Raw phase outputs from that experiment live in its gitignored `report/` subdir on brain — NOT synced to this executor. The distilled numbers in this file are the canonical reference for pw4_2-m4m.

**This profile decays after your first big keep (cumulative ≥ -3%).** When that happens, re-profile via the cheatsheet below; the fresh profile supersedes this file as your hot-symbol reference. Don't keep planning iterations from a stale picture.

## Conditions
- Scaleway M4-M: Apple **M4 base** (Mac16,10) — NOT M4 Pro despite SKU naming.
- 10 cores: 4 P-core + 6 E-core, no SMT.
- 32 GiB RAM (LPDDR5X, ~120 GB/s — NOT the ~273 GB/s of M4 Pro).
- macOS Sequoia 15.6.1 (build 24G90), Darwin 24.6.0 arm64.
- 16 KiB native page. NEON 128-bit. ARMv9 SME (unused by current Plonky3).
- Workload: `prove_loop 3` (3 proofs, 1550 sigs, log_inv_rate=1, fat LTO, zkalloc global)
- Baseline: `origin/main @ c868330c` (PR #216 already integrated into main)
- Capture method: `sample <pid> 10` (1 ms interval) + `xcrun xctrace record --template 'Time Profiler'` + `sudo powermetrics --samplers cpu_power`. NO `perf` available.

## Top-line (parallel, 10-thread rayon pool, 3 proofs, on origin/main)

| Metric | Value |
|---|---:|
| 5-proof wall (warm) `/usr/bin/time real` | ~2.21 s per warm proof |
| **Warm-proof wall (main)** | **2.206 s** |
| Sample budget per profile | ~60k thread-samples (10 s × 11 threads) |
| Inclusive Poseidon (of-CPU-bound, sample) | **58.23%** (main) |
| `__psynch_cvwait` (rayon worker idle) | **18.54% self-time** |
| Rayon plumbing (bridge/helper) | 11.11% self-time |
| P/E heterogeneity tax (theoretical / effective) | 30.1% / 45% — P-core runs ~1.62× faster than E-core |
| P/E topology | 4 P-core + 6 E-core, no SMT |

**Workload classification:** Poseidon-dominant CPU-bound. The TWO biggest CPU sinks are (1) the SIMD permutation and (2) **rayon worker idle on barrier** — at 18.54% of self-time, `__psynch_cvwait` is essentially "P-cores waiting for E-cores to finish their share of work." Memory bandwidth is constrained vs M4 Pro (120 vs 273 GB/s) but not the dominant bottleneck.

Cross-platform reference (PR #216 paired Δ wall):
- Hetzner Zen 4 64 GiB: −5.58%
- M2 Asahi Linux 16 GiB: −6.64%
- M2 Pro macOS 16 GiB: −5.05% ± 0.89
- **M4 macOS 32 GiB (this hardware)**: **−5.23% ± 0.53**

## Top inclusive call-graph paths (sample, 10 s window, main)

| Self % | Symbol |
|---:|---|
| **23.78%** | `Poseidon1KoalaBear16::compress_mut` (primary hash variant — entered via `mt_merkle::commit` / `poseidon_compress_slice`) |
| **18.54%** | `__psynch_cvwait` (rayon worker idle on conditional variable) |
| 11.11% | `rayon::bridge_producer_consumer::helper` |
| 4.54% | `lean_vm::tables::poseidon_16::eval_2_full_rounds_16` (AIR-side first two rounds) |
| 3.80% | `Poseidon1KoalaBear16::compress_mut` (second variant) |
| 2.61% | `mt_poly::eq_mle::eval_eq_with_packed_output` |
| 1.91% | `Poseidon1KoalaBear16::permute_mut` |
| 1.89% | `ConstraintFolderPacked::...` (AIR builder) |
| 1.65% | `mt_sumcheck::fold_and_compute_product_sumcheck_polynomial` |
| 1.55% | `Poseidon16Precompile::eval` (AIR) |
| 1.36% | `lean_vm::tables::poseidon_16::eval_last_2_full_rounds_16` |

**Poseidon-inclusive total ≈ 58.23% of CPU-bound cycles.** The two biggest non-Poseidon costs are rayon idle wait (18.54%) and rayon plumbing (11.11%) — together ~30% of CPU-bound is parallelism overhead.

## Bottleneck-shape map (M4-M specific — DIFFERENT from Hetzner!)

| Lever class | Effect on M4-M parallel | Notes |
|---|---|---|
| Mul-count reduction (algorithmic) | strong win (attacks 23.78% compress_mut self) | Same as Hetzner |
| Permutation-count reduction (sponge RATE, Merkle topology, leaf packing) | strong win | Same as Hetzner |
| **P/E core affinity (rayon ThreadPool with core_affinity)** | **POTENTIALLY HUGE (8-15% predicted) — not yet attempted** | M4-M-specific; pin Poseidon work to P-cores |
| **Reducing rayon barrier waits (chunk sizing, work-stealing tuning)** | **medium-strong (cvwait is 18.54% — 1 pp reduction = 1.7% wall)** | M4-M-specific; not in Hetzner pool |
| Mul-port-relief in `compress_mut` (register-pressure, scalar binding) | uncertain — M4 has different register file + NEON ≠ AVX-512 | DIFFERENT from Hetzner (Hetzner has 32 ZMM, M4 has 32 NEON Q-regs but different latencies) |
| DRAM-bandwidth cache-blocking | medium win (120 GB/s ceiling) | Less effective than on Hetzner (single CCD vs M4's unified bandwidth) |
| `MADV_HUGEPAGE` on zk-alloc slabs | NULL on macOS (no transparent huge pages) | DIFFERENT |
| Source-level wrappers / inline hints | NULL (LTO neutralizes) | Same |

**Key insight specific to M4-M:** the 4P+6E heterogeneity tax dominates parallelism efficiency. Any optimization that reduces TOTAL CPU-bound work helps, but you also have the unique M4 lever of **shifting which cores execute Poseidon** (P-cores at ~1.62× E-core speed). The Hetzner sibling agent does NOT have this lever; it has homogeneous 8c/16t SMT.

## Profiling cheatsheet (commands the agent should use freely)

macOS does NOT have `perf`. Use the macOS stack instead. **Most commands need `sudo`** — passwordless sudo is configured.

```bash
# Build with debug info for symbol-level profiling
CARGO_PROFILE_RELEASE_DEBUG=true RUSTFLAGS="-C target-cpu=native" \
  cargo build --release --bin prove_loop --features zkalloc_global

# Discard page cache between paired runs (important on macOS)
sudo purge

# Sample (1 ms interval, single-process) — primary self-time tool
./target/release/prove_loop 3 &
PID=$!
sleep 2  # skip setup
sudo sample $PID 10 -file /tmp/sample.txt
wait $PID
# Output: 38 MB call-tree. grep for hot symbols:
grep -E '^\s+[0-9]+\s+Poseidon|compress_mut|cvwait' /tmp/sample.txt | head -30

# xctrace Time Profiler (kernel-thread accurate, all threads)
xcrun xctrace record --template 'Time Profiler' \
  --launch -- ./target/release/prove_loop 3 \
  --output /tmp/run.trace
xcrun xctrace export --input /tmp/run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-sample"]' \
  > /tmp/run.xml  # parse with a helper

# dtrace for syscall / thread-state breakdown
sudo dtrace -n 'profile-997 /pid == <pid>/ { @[ustack()] = count(); }' &
DPID=$!
./target/release/prove_loop 3
kill $DPID

# powermetrics for P/E core breakdown (residency, freq, package power)
sudo powermetrics --samplers cpu_power -i 1000 -n 30 > /tmp/pm.txt
# Look at: P-core vs E-core %active, freq histogram, "CPU x active residency"

# Serial vs parallel comparison
RAYON_NUM_THREADS=1 ./target/release/prove_loop 3
RAYON_NUM_THREADS=10 ./target/release/prove_loop 3

# Per-core thread placement check (which threads on P vs E)
sudo dtrace -n 'mach_kernel:thread_dispatch:thread_dispatch {
  @[execname, tid, cpu] = count(); }' > /tmp/cpu_placement.txt &
./target/release/prove_loop 3
# Map to P (CPU 0-3) vs E (CPU 4-9) cores

# Disassemble a release binary symbol
objdump -d --no-show-raw-insn --no-leading-addr target/release/prove_loop \
  | awk '/<.*Poseidon1KoalaBear16.*compress_mut.*>:/,/^$/' | head -200
```

## When to re-profile

**Trigger re-profile when ANY of:**
- A keep lands with cumulative ≥ -3% vs origin/main
- Hot symbol distribution has materially shifted (e.g., `compress_mut` share drops below 18%, or `cvwait` drops below 14%)
- You're 5+ iterations in on the same hot symbol with no keep — re-profile to confirm the symbol is still the right target

After re-profile: write `report/profiling_after_iter_N.md` (gitignored in report/) with the new distribution. Reference THAT file, not this one, going forward.

## What's NOT in this file (intentionally)

- Per-line `sample` dumps — too much detail; agent re-runs them per-hypothesis with the cheatsheet
- Allocator-pressure analysis — already factored into zk-alloc enablement; no further leverage here. On macOS, Mach-VM lazy backing handles slab over-commitment cleanly.

If you need any of the above, the full profiling baseline experiment's `program.md` is at `experiment_logs/leanMultisig/profiling/concluded/profiling_macos_m4m32_pr216_2026-05-12/program.md` (raw phase outputs are NOT on the executor — they live on brain only). If you need fresh per-line data, re-run the cheatsheet commands above against the current binary.
