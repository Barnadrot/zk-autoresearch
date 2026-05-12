# leanMultisig profiling baseline — Hetzner Zen 4 + AVX-512 (2026-05-11)

Canonical baseline for leanMultisig `prove_loop` performance on Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE, Zen 4, 8c/16t, 64 GiB RAM, single CCD). Replaces the regex-grouped table from the call-sites experiment with ground-truth per-crate + line-level attribution.

## Method

| | Value |
|---|---|
| Binary | `/tmp/prove_loop_profile` |
| Source | leanMultisig branch `profile/baseline-2026-05-11` (off `origin/main @ d080f3e2`) — clean tree, no source modifications |
| Build | `CARGO_PROFILE_RELEASE_DEBUG=true RUSTFLAGS="-C target-cpu=native" cargo build --release --bin prove_loop --features zkalloc_global`; `[profile.release]` has `lto = "fat"`, `codegen-units = 1`; binary 183 MB with full DWARF |
| Input | `prove_loop 3` — 3 proofs, 1550 sigs, log_inv_rate=1, zkalloc global allocator |
| Capture | `perf record -F 997 --call-graph dwarf` for sampling profile; `perf stat -e <...>` for counters |
| Reports | `perf report --stdio` (leaf + children), `perf annotate --stdio` (line-level), Brendan Gregg `flamegraph.pl` |

All raw perf data and per-phase summaries are committed alongside this report. Reproduction recipe in `pr_body.md`.

## Top-line numbers (parallel run, 16-thread rayon pool, 3 proofs)

| Metric | Value |
|---|---:|
| Wall-clock total | **11.75 s** |
| Setup time (one-shot) | 3.45 s |
| Pure prove time (3 proofs) | 7.77 s (3.11 + 2.32 + 2.34) |
| Total cycles | 4.41 × 10¹¹ |
| Total instructions | 3.57 × 10¹¹ |
| **IPC (parallel)** | **0.82** |
| Branch miss rate | 3.00 % |
| L1D miss rate | 10.36 % |
| Cache miss rate (LLC tier proxy) | 6.47 % |
| dTLB miss rate (subset) | 58.99 % |
| Frontend stalls | 6.33 % of cycles |
| CPUs utilised | 9.04 (of 16 logical / 8 physical) |
| Effective per-core clock (parallel) | 4.156 GHz (vs 5.116 GHz serial) |

Serial baseline (`RAYON_NUM_THREADS=1`, 3 proofs):

| Metric | Value |
|---|---:|
| Wall-clock total | **52.83 s** |
| Pure prove time | 49.0 s (18.16 + 15.36 + 15.40) |
| **IPC (serial)** | **1.29** |
| Per-core clock | 5.116 GHz |
| **Parallel speedup (prove only)** | **6.31× on 9.04 CPUs (70 % efficient)** |
| **Cycle inflation (parallel vs serial)** | 441 / 268 = 1.65× |
| **Instruction inflation (parallel vs serial)** | 357 / 346 = 1.033× |

Workload classification: **compute-bound on `vpmuludq` when serial, becomes memory-bound under parallel pressure**. The prior wisdom of "latency-bound by Montgomery dependency chains" is refuted by serial IPC = 1.29 — the pipeline is well-populated.

## Canonical per-crate cycle distribution (re-attributed, Phase 7)

The rayon-helper-self bucket from the raw leaf view has been re-distributed to the leanMultisig closure parents that own its cycles under fat-LTO inlining.

| Subsystem | Share | What it is |
|---|---:|---|
| `mt_koala_bear` (Poseidon1 perm + Montgomery + AVX-512 packing) | **~27 %** | The dominant compute kernel |
| `lean_vm` (AIR tables — Poseidon, Execution, etc.) | **~13 %** | AIR-side compute, same primitive as above |
| `mt_sumcheck` (product sumcheck rounds + helpers) | **~12 %** | Quintic-extension mul + add in sumcheck inner loop |
| `sub_protocols` (quotient-GKR sumcheck + air_sumcheck) | **~9 %** | Same shape as above, different protocol |
| `mt_whir` (DFT + open + commit, was hidden inside rayon helper) | **~7 %** | FRI butterfly + linear combine |
| `mt_poly` (eq-MLE + multilinear utilities) | **~6 %** | Eq-poly construction for sumcheck |
| Kernel (page-fault handlers, syscalls) | **~5 %** | 2.9 M minor faults during the 11.75 s run |
| `rayon` (true scheduler — idle-spin + atomics + dispatch) | **~5 %** | Phase 4: bounded above by 11 %, lower bound 3 % |
| `core` + `mt_air` + `alloc` + `std` | **~5 %** | Framework code |
| Other / unaccounted | **~11 %** | Generic-helper recursion residual + small leaves |

The brain's regex-grouped table had `rayon` at 19.33 % — this baseline shows it is **~5 % true scheduler + ~14 % inlined user closure code**. The corrected table moves the latter to `mt_whir`, `mt_sumcheck`, `sub_protocols`, and `lean_vm`.

## Inclusive call-graph top paths (Phase 1)

1. `Poseidon1KoalaBear16::compress_mut` (h47d4…) — **22.37 % inclusive / 22.28 % self** (single dominant symbol; four total instantiations summing to 26.57 % self).
2. `WorkerThread::wait_until_cold` — 15.15 % inclusive (of which 13.46 % is `execute` reentry into user code; 9.95 % is `main_loop / wait_until_out_of_work` true scheduler-idle).
3. `Poseidon1KoalaBear16::permute_simd::mds_fft` (inlined) — 7.99 % inclusive (MDS-as-FFT kernel).
4. `PackedMontyField31AVX512::Mul + packing::mul` (inlined) — 6.73 % inclusive (Montgomery vector multiply).
5. `lean_vm::tables::poseidon_16::eval_2_full_rounds_16` — 5.71 % inclusive / 5.03 % self (AIR-side first two rounds).
6. `PackedMontyField31AVX512::dot_product` (inlined) — 5.00 % inclusive.
7. `mt_sumcheck::product_computation::fold_and_compute_product_sumcheck_polynomial` (h4a57 closure) — 4.30 % inclusive / 3.59 % self.
8. `mt_poly::eq_mle::eval_eq_with_packed_output` — 4.28 % inclusive / 4.24 % self.
9. `mt_whir::dft::dft_layer_par_triple::closure` (inlined) — 3.58 % inclusive (rolled up from helper).
10. `mt_sumcheck::product_computation::fold_and_compute_product_sumcheck_polynomial` (ha078 closure) — 3.44 % inclusive / 2.79 % self.

## Hot-symbol line-level findings (Phase 3)

- **`compress_mut`**: 27 % `vpmuludq` (Montgomery mul) + 18 % `vpaddd` (MDS add) + 7 % `vpsubd` (MDS sub) + 15 % `vmovdqu64` (load/store). **Top hot single line is a STACK SPILL: `vmovdqa64 %zmm3, 0x780(%rsp,%rsi,1)` at 2.22 %** — register pressure is the binding constraint inside the 16-state Poseidon1.
- **`eval_2_full_rounds_16` / `eval_last_2_full_rounds_16`**: flat distribution (top single line <0.3 %), ~28 % mul / 20 % add. These are the AIR-side unrolled rounds — back-end-saturated, no single hot line.
- **`eval_eq_with_packed_output`**: 18 % mul / 28 % add. The top hot line is `movq $0, (%rsp)` at 0.83 % — the **stack-probe prologue is 1.6 % of the symbol's body** (avoidable by shrinking the frame).
- **`fold_round_packed` (h1cbf)**: 38 % mul / 26 % add. The top 5 hot lines are the 5 mul/add micro-ops of one `quintic_mul` instance. **At the AVX-512 mul-port throughput ceiling** — algorithmic improvements only.
- **`Poseidon16Precompile::eval`**: 35 % mul / 19 % add — same shape as `compress_mut`, different unrolling. Improvements to `compress_mut` propagate here.

## Hardware-counter findings (Phase 5)

- **Branch miss rate 3.00 %** → not a bottleneck. No prediction or layout work needed.
- **L1D miss rate 10.36 %** → moderate; most caught at L2/L3. Not the binding cost.
- **LLC-tier miss rate 6.47 %** → 1.35 B misses × ~50-cycle DRAM penalty = ~67 B cycles = **~15 % of total cycles in DRAM waits**. The dominant non-compute cost.
- **dTLB miss rate 58.99 % of subset** → 489 M page-table walks × ~25 cycles avg = ~12 B cycles = **~3 % of cycles in PTW**. Real but secondary.
- **Frontend stalls 6.33 %** → not bottleneck; I-cache / branch redirect / front-end fetch is fine.
- **Page faults**: 2.9 M minor faults at ~250 k/s (lazy mmap of zkalloc slabs). 0 major faults.

**Workload classification**:
- Primary: **compute-bound on `vpmuludq`** when serial (IPC 1.29 ≈ mul-port ceiling).
- Secondary (under parallel): **memory-bound on shared L3 / DRAM** (~15-20 % of cycles in memory waits).
- **NOT**: latency-bound (high serial IPC rules it out), branch-bound, frontend-bound.

## Rayon decomposition (Phase 4)

- True rayon scheduling code (extra instructions): **~3 % of parallel cycles** (11 B Δ insns / 357 B total).
- Idle-spin upper bound (`wait_until_out_of_work` inclusive): **≤ 11.35 %**.
- Inlined parallel work mis-attributed to bridge_helper: **~19.6 %** (the 22.86 % helper leaf minus 3 % true rayon code).
- Wall-clock parallel speedup on prove-only path: **6.31× on 9.04 CPUs** (70 % efficient).
- Per-core IPC drops 1.29 → 0.82 (−37 %) going from serial to parallel. Causes: 19 % per-core clock throttling (boost limit), 15 % DRAM-bandwidth contention, ~3 % TLB walks, the rest is SMT-sibling mul-port sharing.

## Per-thread load balance (Phase 6)

- 14 of 16 logical CPUs run rayon workers at uniform IPC = 0.80, each executing ~20 B instructions / ~25 B cycles. **No load imbalance.**
- CPU3 and CPU11 are the main / dispatch threads (43 B / 38 B insns, IPC 1.10-1.12). They run serial code that isn't competing for the mul-port — hence higher IPC.
- **No worker is silently stuck in the steal-loop with low insn-count.** The "9 of 16 CPUs busy" is per-CPU 54 % utilisation, not 7 idle workers. The idle slack is distributed evenly.

## Implications for optimisation candidate ranking

The brain's prior table ranked candidates against regex-grouped sample data. This baseline lets us re-rank against ground truth.

### Tier 1 — Real attack surface (combined ≥ 30 % of cycles)

1. **Poseidon1 SIMD path** (`compress_mut` + `permute_simd` + `mds_fft` + AIR-side eval). Total ~35-40 % of cycles. Specific handle from Phase 3: register-pressure reduction inside `compress_mut` (the 2.22 % stack-spill hot line is the canary). Either (a) re-schedule MDS to keep fewer elements alive simultaneously, (b) shrink round constants in zmm by computing differently, (c) restructure the loop nest to be cache-friendly. Any 5 % reduction translates to ~2 % wall-clock.

2. **DRAM-bandwidth reduction** (~15 % of parallel cycles). The per-worker working set doesn't fit in L3 (32 MB Zen 4 single-CCD). Better cache-blocking in `fold_and_compute_product_sumcheck_polynomial` and `mt_whir::dft::dft_layer_par_triple` (which are the two biggest streaming loops). Probably worth ~3-5 % wall-clock.

3. **Huge-page mapping for zkalloc slabs** (~3 % of cycles in dTLB walks). `madvise(MADV_HUGEPAGE)` on the slab regions or `mmap(MAP_HUGETLB)`. Should be a one-day change inside zk-alloc.

### Tier 2 — Real but smaller (5-10 %)

4. **Eliminating Poseidon1 calls** (algorithmic). Examples: smarter Merkle batching, redundant-leaf avoidance, lazy-evaluation of unused paths. Every 10 % reduction in `compress_mut` invocations = ~3 % wall-clock.

5. **WHIR DFT optimisation** (~7 % inclusive). The butterfly count is fixed by code-rate × log domain size; the win is in better SIMD scheduling. AVX-512 8-way + 4-way 64-bit lanes vs the current packing — quantify with a focused micro-benchmark.

6. **`eval_eq_with_packed_output` stack-frame reduction** (~1.5 % of total cycles in stack probe). Move the temp buffer to a pre-allocated heap arena. One-day change.

### Tier 3 — Bounded ceiling (≤ 5 %)

7. **Rayon scheduler tuning** — bounded above by 11 %, realistic gain ≤ 5 %. Not worth significant engineering effort given Tier 1/2 wins available.

8. **Reducing `quintic_mul` count** — algorithmic; at AVX-512 mul-port ceiling so per-call improvements impossible. ~6-7 % attack surface combined across sumcheck + WHIR.

### Refuted candidates (negative results)

- **"Reduce dependency chain depth in Montgomery reduce"** — refuted by serial IPC = 1.29 (chains are not the bottleneck; mul-port is).
- **"Pin rayon to physical cores (RAYON_NUM_THREADS=8)"** — refuted by Phase 6 uniform IPC and Phase 4 70 % parallel efficiency. Both SMT siblings are doing useful work; halving them halves available context for the same mul-port ceiling.
- **"Reduce branch mispredicts"** — refuted by 3.00 % miss rate, well below attack-vector threshold.

## What changed from the call-sites baseline

| Brain-side claim (call-sites baseline) | This baseline says | Direction |
|---|---|---|
| `rayon::bridge_helper` is 19.33 % overhead | True rayon overhead is **3-5 %**; the other ~15 % is inlined user code under fat LTO | Brain over-ranked rayon |
| Latency-bound on Montgomery dependency chains | **Compute-bound on `vpmuludq`** (serial IPC = 1.29); chain length is not the bottleneck | Brain mis-classified |
| `compress_mut` is the top symbol | Confirmed — 22.28 % self. **Plus the stack-spill hot line shows register pressure is the specific actionable inefficiency** | Brain right on rank, this baseline gives the actionable line |
| WHIR / FRI is large | Inclusive ~7 %, smaller than the brain's regex grouping implied | Brain over-ranked |
| `mt_sumcheck` + `mt_poly` are large | Confirmed at ~18 % combined | Brain matched |

The baseline is now anchored for at least the next month of optimisation work on this machine.
