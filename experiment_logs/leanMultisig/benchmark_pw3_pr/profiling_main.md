# Deep Profiling: leanMultisig origin/main on `fancy-aggregation`

- **Commit profiled:** `19f1c774` (origin/main, "embbed .py files in the binary")
- **Workload:** `fancy-aggregation` (12 nodes; 6 XMSS leaves + 6 recursion aggregations)
- **Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4, 8c/16t, AVX-512), 64 GB RAM
- **RUSTFLAGS:** `-C target-cpu=native` (used for the glibc rebuild; main binary built externally with same flag)
- **Build features:** main binary uses zk-alloc (default); `bench_19f1c774_glibc` rebuilt with `--features standard-alloc`
- **Date:** 2026-05-08

## 1. Executive Summary

1. **Compute-bound, not memory-bound.** LLC-miss bandwidth ≈ 4.0 GB/s, ~8% of the 51.2 GB/s DDR5 ceiling; cache-miss rate 3.57%. IPC 0.91 is consistent with AVX-512-heavy SIMD, not memory stalls.
2. **Poseidon dominates by a wide margin.** `Poseidon1KoalaBear16::permute_mut` alone is **~33% of cycles**; counting AIR evaluation + closures the Poseidon family is **~42%** of total work. Sumcheck/GKR is the #2 cluster (~12%).
3. **zk-alloc has captured nearly all allocator headroom.** Clean raw wall: zk-alloc 24.89 s vs glibc 29.92 s (zk-alloc **17% faster**, 4.8× less sys time, 5.3× fewer page faults). Remaining allocator headroom on this workload is small.
4. **Rayon is mostly saturating, with a non-trivial serial tail.** Average busy-CPU ≈ **11.9 / 16** (74%); ~16% of intervals spend <4 cores busy — node setup/teardown and per-node sequential work.
5. **Highest-EV optimization vector: reduce Poseidon count (algorithmic / hash-design).** Second: shrink the inter-node serial tail (pipelining). Allocator and SIMD have small remaining headroom.

---

## 2. Q1 — Compute-bound vs memory-bound

### Raw `perf stat` output (zk-alloc binary)

```
warming up... used 10.83 GiB

 Performance counter stats for '/tmp/bench_19f1c774 fancy-aggregation --json':

        272,111.95 msec task-clock                       #    8.394 CPUs utilized
 1,098,947,638,166      cycles                           #    4.039 GHz                   (83.34%)
 1,002,960,297,806      instructions                     #    0.91  insn per cycle        (83.32%)
    60,655,270,654      cache-references                 #  222.906 M/sec                 (83.35%)
     2,166,756,124      cache-misses                     #    3.57% of all cache refs     (83.33%)
   <not supported>      LLC-loads
   <not supported>      LLC-load-misses
   <not supported>      LLC-stores
   <not supported>      LLC-store-misses
    50,725,285,567      branches                         #  186.413 M/sec                 (83.33%)
     1,270,027,810      branch-misses                    #    2.50% of all branches       (83.33%)
         3,066,779      page-faults                      #   11.270 K/sec
           896,558      context-switches                 #    3.295 K/sec

      32.415756814 seconds time elapsed
     257.971231000 seconds user
      14.780697000 seconds sys
```

> Note: this run's wall-clock (32.4 s) is inflated by `perf stat` PMU multiplexing (visible as the 83.3% counter-coverage). Clean raw wall (no perf): **24.89 s** (mean of 3 back-to-back runs — see Q2). The *rates* (IPC, miss%, etc.) remain valid because both numerators and denominators were sampled with the same multiplexing duty cycle.

### Derived metrics

| Metric | Value | Interpretation |
|---|---|---|
| Effective freq | 4.039 GHz | At/near boost; not throttled |
| **IPC** | **0.913** | Low for general-purpose code, normal for AVX-512-heavy SIMD: each instruction does 16× scalar work |
| Avg CPUs utilized (process) | 8.39 / 16 | SMT not doubling throughput — typical for SIMD/FMA-bound code (compute units shared between SMT siblings) |
| Cache-references rate | 222.9 M/s | L1-miss → L2/LLC traffic |
| Cache-miss rate | 3.57% | Low; working set largely fits in cache |
| **LLC-miss bandwidth est.** | **3.98 GB/s** (2.17 G misses × 64 B / 32.4 s) | **7.8% of 51.2 GB/s DDR5 ceiling** |
| Memory-stall band | 15.8% – 39.4% of cycles (assuming 80 – 200 cyc/miss) | Modest; mid-band ~25% |
| Branch miss rate | 2.50% | Moderate; not a pathology |
| Sys time | 14.78 s / 272 s = 5.4% | Most time is user/compute, not kernel |

> AMD Zen 4 LLC-load/store breakdown PMU events are unsupported by this kernel/perf combination. We use total `cache-misses` as the LLC-miss proxy. The published Zen 4 cache-line size is 64 B; bandwidth = misses × 64 B / wall.

### Verdict

**Compute-bound.** Memory bandwidth utilization (~8% of peak) and cache-miss rate (3.57%) are both well below memory-bound thresholds. IPC of 0.91 is consistent with vectorized field arithmetic, not memory stalls. Branch behavior is unremarkable. Most cycles are doing actual computation; the dominant inner loop (Poseidon permutation) is computational, not memory-bound (Q4 confirms: `permute_mut` is 31% of cycles standalone).

---

## 3. Q2 — zk-alloc vs glibc allocator headroom

### Raw `perf stat` output (glibc binary, built with `--features standard-alloc`)

```
warming up... used 5.39 GiB

 Performance counter stats for '/tmp/bench_19f1c774_glibc fancy-aggregation --json':

        306,880.15 msec task-clock                       #   10.330 CPUs utilized
 1,269,089,085,547      cycles                           #    4.135 GHz
 1,087,963,416,990      instructions                     #    0.86  insn per cycle
    65,625,422,629      cache-references                 #  213.847 M/sec
     2,388,502,870      cache-misses                     #    3.64% of all cache refs
        16,124,199      page-faults                      #   52.542 K/sec
           220,518      context-switches                 #  718.580 /sec

      29.706925250 seconds time elapsed
     255.032092000 seconds user
      51.942215000 seconds sys
```

### Clean raw wall-clock (no `perf stat` overhead)

Three back-to-back runs each, sequential, no contention:

| | run 1 | run 2 | run 3 | mean |
|---|---|---|---|---|
| zk-alloc | 24.85 s real, 266.04 user, 10.95 sys | 24.88 / 266.40 / 10.69 | 24.93 / 265.79 / 10.78 | **24.89 s** |
| glibc | 29.93 / 256.26 / 51.82 | 29.98 / 257.10 / 52.02 | 29.85 / 256.61 / 51.45 | **29.92 s** |

### Side-by-side comparison

| Metric (zk-alloc → glibc) | zk-alloc | glibc | Δ (glibc vs zk-alloc) |
|---|---|---|---|
| **Wall (clean)** | 24.89 s | 29.92 s | **+20.2% slower (≈ +5.0 s)** |
| Task-clock (perf) | 272.1 s | 306.9 s | +12.8% |
| Cycles | 1.099 × 10¹² | 1.269 × 10¹² | +15.5% |
| Instructions | 1.003 × 10¹² | 1.088 × 10¹² | +8.5% |
| **Sys time** | **14.78 s** | **51.94 s** | **+251.4% (3.5×)** |
| User time | 257.97 s | 255.03 s | −1.1% |
| IPC | 0.913 | 0.857 | −6.1% |
| Cache misses | 2.17 G | 2.39 G | +10.2% |
| Cache miss% | 3.57% | 3.64% | +0.07 pp |
| **Page faults** | **3.07 M (11 K/s)** | **16.12 M (52 K/s)** | **+426% (5.3×)** |
| Context switches | 896.6 K | 220.5 K | −75% (glibc has fewer) |
| Warmup-arena RSS | 10.83 GiB | 5.39 GiB | zk-alloc pre-touches its full arena upfront |

### Verdict

**zk-alloc has captured the dominant allocator wins.** It is 17% faster wall-clock, has 3.5× less sys time, 5.3× fewer page faults, and 6.5% better IPC than glibc on this workload. The remaining ~10.8 s of process sys time + page-fault handling under zk-alloc is mostly the upfront arena pre-touch (10.83 GiB) — actual per-prove allocator overhead is sub-second. **Headroom for further allocator improvement on this workload is small (estimated < 5%).** A possible micro-win: lazy-touch the arena rather than fully pre-touching (would shrink the warmup phase included in wall-clock); however, that interacts with how the workload uses memory and may regress steady-state.

> Note on the higher context-switch count under zk-alloc (896 K vs 221 K): this is consistent with rayon `__sched_yield`-driven steal loops on the relatively idle phases between nodes. It is *not* allocator-related; Q4 shows `__sched_yield` at ~1.7% of samples.

---

## 4. Q3 — Rayon CPU saturation

### Raw `perf stat -a -A` (system-wide, per-CPU)

Wall: 24.49 s. Per-CPU cycles + IPC + task-clock (full output preserved verbatim):

```
CPU0       71,243,497,021      cycles                           #    2.909 GHz
CPU1       71,171,372,736      cycles                           #    2.906 GHz
CPU2       70,590,115,273      cycles                           #    2.882 GHz
CPU3       81,963,069,677      cycles                           #    3.347 GHz
CPU4       71,195,105,829      cycles                           #    2.907 GHz
CPU5       76,101,893,178      cycles                           #    3.107 GHz
CPU6       71,074,474,835      cycles                           #    2.902 GHz
CPU7       71,845,472,510      cycles                           #    2.933 GHz
CPU8       70,760,372,070      cycles                           #    2.889 GHz
CPU9       70,828,594,739      cycles                           #    2.892 GHz
CPU10      70,764,093,335      cycles                           #    2.889 GHz
CPU11      79,855,925,946      cycles                           #    3.261 GHz
CPU12      71,050,881,476      cycles                           #    2.901 GHz
CPU13      86,291,704,295      cycles                           #    3.524 GHz
CPU14      71,133,675,305      cycles                           #    2.905 GHz
CPU15      71,103,363,238      cycles                           #    2.903 GHz
CPU0       60,083,014,081      instructions                     #    0.84  insn per cycle
CPU1       59,489,903,329      instructions                     #    0.84  insn per cycle
CPU2       59,166,528,511      instructions                     #    0.84  insn per cycle
CPU3       81,959,020,906      instructions                     #    1.00  insn per cycle
CPU4       59,915,548,386      instructions                     #    0.84  insn per cycle
CPU5       66,240,048,762      instructions                     #    0.87  insn per cycle
CPU6       59,842,191,233      instructions                     #    0.84  insn per cycle
CPU7       60,400,064,870      instructions                     #    0.84  insn per cycle
CPU8       59,329,433,118      instructions                     #    0.84  insn per cycle
CPU9       59,183,842,798      instructions                     #    0.84  insn per cycle
CPU10      59,410,831,539      instructions                     #    0.84  insn per cycle
CPU11      78,220,464,713      instructions                     #    0.98  insn per cycle
CPU12      59,706,881,208      instructions                     #    0.84  insn per cycle
CPU13      88,510,282,660      instructions                     #    1.03  insn per cycle
CPU14      59,682,910,018      instructions                     #    0.84  insn per cycle
CPU15      59,614,478,199      instructions                     #    0.84  insn per cycle

      24.488545420 seconds time elapsed
```

### `/proc/stat` sampling (every 0.5 s, 50 samples over 25.6 s)

Computed busy-CPU equivalents (sum across 16 CPUs of `(busy_jiffies / total_jiffies)` per sample interval):

```
Avg busy CPU equivalents over run: 11.91 / 16  (74.4% saturation)
Max busy CPU equivalents:          16.00
Min busy CPU equivalents:           2.10
Median:                            14.31

Intervals with <2 busy CPUs:   0/49 ( 0.0%)  — no full-serial phases
Intervals with <4 busy CPUs:   8/49 (16.3%)  — partial serial (likely per-node setup/teardown)
Intervals with <8 busy CPUs: 10/49 (20.4%)
Intervals with >14 busy CPUs: 26/49 (53.1%) — fully saturated

Histogram of busy-CPU-equivalents (50ms resolution):
   2-3: ####### (7)
   3-4: # (1)
   4-5: # (1)
   5-6: # (1)
  10-11: # (1)
  11-12: ## (2)
  12-13: #### (4)
  13-14: ###### (6)
  14-15: ################## (18)
  15-16: ####### (7)
  16-17: # (1)

Per-CPU avg utilization over run:
  cpu 0: 72.0%   cpu 1: 71.2%   cpu 2: 70.6%   cpu 3: 89.0%
  cpu 4: 71.1%   cpu 5: 81.0%   cpu 6: 71.6%   cpu 7: 73.0%
  cpu 8: 71.1%   cpu 9: 71.0%   cpu10: 70.7%   cpu11: 80.9%
  cpu12: 71.0%   cpu13: 83.6%   cpu14: 71.3%   cpu15: 71.5%
```

### Interpretation

- **No fully serial sections** observed at 0.5-s resolution — the lowest interval still had ~2 cores busy.
- The "ground floor" of ~71% per-CPU utilization across most cores suggests rayon spreads work broadly. Cores 3, 5, 11, 13 run hotter (80–89%) — these are probably the cores where the master thread / proof orchestrator + their SMT siblings land most often.
- ~16% of wall time has <4 cores busy. Over the 24.9-s run this is **~4 seconds of partial-serial work**, which is the pipelinable / overlappable budget. Per-node setup, transcript squeezing, leaf-proof bytes assembly, and inter-node prep are the candidates.
- **Rayon saturates well during inner kernels**, but the program is composed of a serial sequence of 12 prove calls, each with a non-parallelizable head/tail. Cross-node pipelining is the structural opportunity.

---

## 5. Q4 — Per-function hotspots

### Top 30 self-time symbols (`perf record -g --call-graph dwarf -F 997`, 275,784 samples)

Rank | %self | Symbol | Category
---:|---:|---|---
1 | **31.28%** | `Poseidon1KoalaBear16::permute_mut` (clone h0764e6d72e828ac9) | Poseidon perm
2 | 5.29% | `core::ops::function::impls::FnMut::call_mut` (rayon closure thunk) | Rayon plumb
3 | **3.86%** | `lean_vm::tables::poseidon_16::eval_2_full_rounds_16` | Poseidon AIR
4 | 3.61% | `mt_poly::eq_mle::eval_eq_with_packed_output` | Sumcheck (eq MLE)
5 | 3.51% | `mt_sumcheck::product_computation::fold_and_compute_product_sumcheck_polynomial` (clone h3c91697b43c7c379) | Sumcheck
6 | 2.77% | `rayon::iter::plumbing::bridge_producer_consumer::helper` | Rayon plumb
7 | 2.65% | `sub_protocols::quotient_gkr::sumcheck_utils::fold_and_compute_round_packed` (clone h91ac0b522cbe8675) | Sumcheck/GKR
8 | 2.59% | `core::ops::function::impls::FnMut::call_mut` (another rayon closure clone) | Rayon plumb
9 | 2.40% | `mt_sumcheck::…fold_and_compute_product_sumcheck_polynomial` (clone ha6716b919c77e1fe) | Sumcheck
10 | 1.73% | `core::ops::try_trait::Wrapped::call_mut` | Iterator helper
11 | 1.37% | `Poseidon1KoalaBear16::permute_mut` (clone ha68254c099d91a7b) | Poseidon perm
12 | 1.37% | `<lean_vm::tables::poseidon_16::Poseidon16Precompile<_> as mt_air::Air>::eval` | Poseidon AIR
13 | 1.36% | `core::iter::adapters::map::Map::fold` | Iterator helper
14 | 1.31% | `lean_vm::tables::poseidon_16::eval_last_2_full_rounds_16` | Poseidon AIR
15 | 1.27% | `core::ops::function::impls::FnMut::call_mut` (clone) | Rayon plumb
16 | 1.25% | `Poseidon1KoalaBear16::permute_mut` (clone ha5e8678b01a0e71c) | Poseidon perm
17 | 1.24% | `core::ops::function::impls::FnMut::call_mut` (clone) | Rayon plumb
18 | 0.97% | `sub_protocols::quotient_gkr::sumcheck_utils::run_phase1_sumcheck::closure` | Sumcheck/GKR
19 | 0.89% | `core::ops::function::impls::FnMut::call_mut` (clone) | Rayon plumb
20 | 0.89% | `core::iter::adapters::chain::Chain::next` | Iterator helper
21 | 0.74% | `core::array::try_map::h8785fce6d64839b8` | Iterator helper
22 | 0.73% | `mt_poly::evals::eval_multilinear_generic` | MLE
23 | 0.71% | `<RoundCoeffs<T> as Mul<W>>::mul` | Sumcheck (round coeffs)
24 | 0.66% | `sub_protocols::quotient_gkr::sumcheck_utils::fold_and_compute_round_packed` (clone) | Sumcheck/GKR
25 | 0.65% | `lean_vm::tables::execution::air::eval` | AIR (execution)
26 | **0.62%** | `mt_whir::dft::Butterfly::apply_to_rows` | FRI/WHIR DFT
27 | 0.58% | `sub_protocols::quotient_gkr::sumcheck_utils::compute_round_packed::closure` | Sumcheck/GKR
28 | 0.56% | `<ConstraintFolderPacked<...> as AirBuilder>::assert_zero` | AIR folder
29 | 0.52% | `core::ops::function::impls::FnMut::call_mut` (clone) | Rayon plumb
30 | 0.51% | `mt_field::PrimeCharacteristicRing::halve` | Field arith

Per-DSO total:
```
92.73%  bench_19f1c774        — application code
 5.18%  [unknown]             — unresolved (kernel callbacks, vDSO, JIT-less inlines)
 2.09%  libc.so.6             — pthread/sched/alloc helpers
```

Inclusive (with-children) view top items:

```
81.11%  [.] 0xffffffffffffffff      — top-of-stack roots (rayon entry points)
31.39%  [.] Poseidon1...permute_mut (children + self)
15.32%  [.] rayon_core::registry::WorkerThread::wait_until_cold
11.62%  [.] rayon_core::registry::ThreadBuilder::run
10.78%  [.] std::sys::backtrace::__rust_begin_short_backtrace
10.65%  [.] core::ops::function::FnOnce::call_once {{vtable.shim}}
 9.29%  [.] std::sys::thread::unix::Thread::new::thread_start
 1.66%  [.] __sched_yield     — rayon idle thread parking
```

The `wait_until_cold` 15.3% inclusive is the rayon worker idle-loop time. It is *not* productive work; it indicates the worker pool occasionally exceeds the available parallelism (consistent with the 16% partial-serial tail in Q3).

### Category aggregation (sum of self-time)

Counting all matching clones in the top-symbol list (>0.5% threshold):

| Category | Symbols | Sum %self | Notes |
|---|---|---:|---|
| **Poseidon permutation (compute kernel)** | 3 LLVM clones of `permute_mut` | **33.90%** | Vectorized AVX-512 inner loop |
| **Poseidon AIR evaluation** | `eval_2_full_rounds_16`, `eval_last_2_full_rounds_16`, `Poseidon16Precompile::eval` | **6.54%** | Constraint trace gen |
| **Poseidon total** | (above two combined) | **~40.4%** | |
| **Sumcheck / GKR** | `fold_and_compute_product_sumcheck_polynomial` ×2, `fold_and_compute_round_packed` ×2, `run_phase1_sumcheck`, `compute_round_packed`, `RoundCoeffs::mul`, `eval_eq_with_packed_output` | **~14.1%** | |
| **MLE / poly eval** | `eval_multilinear_generic` (and the eq-MLE counted above) | **0.7% (excl. eq-MLE)** | |
| **Execution AIR + constraint folder** | `execution::air::eval`, `assert_zero` | **1.21%** | |
| **FRI/WHIR (visible)** | `Butterfly::apply_to_rows` | **0.62%** | DFT presence is small — most FRI cost lives inside Poseidon-based Merkle commits |
| **Field arithmetic helpers** | `PrimeCharacteristicRing::halve` | **0.51%** | |
| **Rayon plumbing (closure thunks, bridges, stackjob)** | `bridge_producer_consumer`, `call_mut` clones, etc. | **~13–15%** (inclusive; <0.5% each self) | |
| **Iterator helpers** | `Map::fold`, `Chain::next`, `try_map`, `Wrapped::call_mut` | **~4.7%** | |
| **kernel + libc + sched_yield + memcpy/memset** | `__sched_yield`, kernel `0xffffffff…` symbols | **~5–8%** | |
| **Memory copy / set / alloc primitives** | none above 0.5% | **~0%** | No `memcpy`/`memset`/`alloc` symbols crack the threshold |

### Key observations

- **Poseidon is everything.** Two-thirds of the field-arithmetic work in this proof system is hashing. `permute_mut` alone matches the entire sumcheck/GKR engine **3×** in cost.
- **No memory-copy hotspots.** No `memcpy`, `memset`, `alloc`, `mmap`, or page-fault helpers crack the 0.5% bar — confirming Q1's compute-bound verdict.
- **Rayon plumbing is ~15% inclusive** but ~5% self. This is overhead from per-iteration closure dispatch through `bridge_producer_consumer`/`StackJob` — not free, but most of it is pure infrastructure cost of using rayon at fine granularity.
- **Iterator-adapter overhead** (`Map::fold`, `Chain::next`, `Wrapped::call_mut`, `try_map`) sums to ~4.7% — these are usually inlined; their visibility suggests some closures escape inlining at hot points.

---

## 6. Q5 — Per-node times and serialization signal

### Per-node breakdown (parsed from `fancy-aggregation --json`)

```
path                          secs     cycles        mem        poseidons   dots     n_xmss
[0, 0, 1, 0]                 3.065     994824    3,900,425    259,055      30,619     1550   ← leaf
[0, 0, 0, 0]                 2.321     994842    3,900,425    259,055      30,602     1550   ← leaf
[0, 1, 0]                    1.530     498011    1,953,569    129,630      15,361      775   ← leaf
[0, 1, 1]                    1.523     498056    1,953,569    129,630      15,363      775   ← leaf
[0]                          1.456     329766      939,133     36,207     105,657     None   ← agg
[0, 0, 0, 1]                 1.442     326798    1,283,933     85,041      10,068      508   ← leaf
[0, 0, 1, 1]                 1.434     326848    1,283,933     85,041      10,118      508   ← leaf
[0, 0, 0]                    1.324     282702      798,634     29,107     104,752     None   ← agg
[]                           1.106     109703      322,550      9,574      44,889     None   ← root agg
[0, 0]                       1.037     286081      791,141     30,814      85,548     None   ← agg
[0, 1]                       0.928     243008      642,900     22,191      90,347     None   ← agg
[0, 0, 1]                    0.914     251801      692,907     24,078      84,750     None   ← agg

Total node-time (sequential prove sum): 18.08 s
Wall clock (clean run):                 24.89 s
Pre-prove warmup + post-prove output:   ≈ 6.8 s

Total poseidons across nodes: 1,099,423
Total VM cycles:              5,142,440
Total proof KiB:                  2,577 (2.5 MiB)

Leaves   (XMSS-bearing): 6 nodes, 11.32 s prove time
Aggregations:            6 nodes,  6.76 s prove time
```

### Per-CPU cycle distribution during one fancy-aggregation run (Q5 dedicated capture)

Wall: 24.44 s. Cycles (B = ×10⁹):

```
CPU0  71.3 B   CPU1  70.9 B   CPU2  70.3 B   CPU3  78.9 B
CPU4  71.0 B   CPU5  90.3 B   CPU6  71.4 B   CPU7  71.6 B
CPU8  70.9 B   CPU9  70.7 B   CPU10 70.6 B   CPU11 74.9 B
CPU12 71.0 B   CPU13 71.8 B   CPU14 71.4 B   CPU15 71.1 B

min=70.3 B, median=71.4 B, max=90.3 B (CPU5)
max/min = 1.28×, max/median = 1.27×
```

### Interpretation

- **No pathological serialization.** The hottest CPU does **1.28×** the work of the median, far below the "10× serial" threshold the question asks about. Consistent with Q3 (no full-serial intervals).
- **CPU5 / CPU3 / CPU11 / CPU13 carry slightly more** — these are the cores where the main thread / orchestrator (and per-CCX stealing edge cases) tends to land. The asymmetry is small enough that single-threaded codepaths are NOT a primary bottleneck.
- **Within each individual `prove`,** rayon achieves good (but not perfect) saturation — Q3's 16% partial-serial intervals are split across all 12 nodes (each node has a small serial head/tail). 16 % × 24.9 s ≈ 4 s of inter-node + per-node setup.
- **Two leaves (1550 XMSS each) take 2.32 s and 3.07 s** — the variance (0.75 s on identical workloads) is most likely thermal/boost-state variance or warm-vs-cold cache effects (the second of the pair runs while the first's working set is still resident).
- The Σ(node times) = **18.08 s** vs wall = **24.89 s** ⇒ **~6.8 s of overhead outside `prove()` calls** (warmup, allocator pre-touch, setup, JSON serialization). Most of this is the zk-alloc arena warmup ("used 10.83 GiB" before the first prove).

---

## 7. Q6 — Optimization class ranking (evidence-based)

Ranking by *expected wall-clock impact*, with the supporting datapoint inline.

### Tier 1: Highest leverage

#### (a) Algorithmic — reduce total work (especially Poseidon count)
- **Evidence:** `Poseidon1KoalaBear16::permute_mut` = **31.28% self / 33.9% counting all clones**; Poseidon AIR evaluation adds **6.5%** more → **~40% of total cycles**. (Q4 categorization.)
- **Implication:** A 25% reduction in Poseidon permutations ≈ 10% wall-clock improvement at the level of the whole `fancy-aggregation`.
- **Concrete vectors:** wider/feed-forward MMO sponges (RATE 12 already in flight on `fix/s123-hashing-opt`), reducing the number of leaves committed per Merkle layer, lower-Poseidon LogUp tables, or replacing internal Poseidon use in transcript with cheaper PRF where soundness allows.
- **Why #1:** No other single category exceeds 14%. Algorithmic wins compound (each Poseidon saved is a permute call + an AIR row + a Merkle leaf hash).

### Tier 2: Strong, second-order leverage

#### (b) Parallelism improvements (cross-node pipelining)
- **Evidence:** Average 11.91 / 16 busy CPUs (74.4%). 16% of intervals have < 4 cores busy ≈ 4 s of partial-serial budget over a 25-s run. Σ(node prove times) = 18.08 s on a 24.89 s wall ⇒ 6.8 s of non-prove overhead, much of which is sequential.
- **Implication:** If cross-node pipelining can overlap the trailing FRI/transcript-finalize of node N with the witness-build of node N+1, expected gain ≈ **10–15%** wall-clock.
- **Risk:** The serial dependency comes from the recursion chain (children must finish before parent starts). Aggregation nodes can't start until both children are done. The 4 s opportunity is mostly in inter-node setup and JSON/transcript bytes; pipelining within a single prove (witness gen ‖ tracegen ‖ commit) is the higher-value sub-vector.

#### (c) Memory access pattern improvements
- **Evidence:** Estimated memory stalls 15.8 – 39.4 % of cycles (Q1, 80–200 cyc/miss band). Cache-miss rate is already low (3.57%); LLC bandwidth at 7.8% of DDR5 peak.
- **Implication:** Some stall budget exists, but absolute headroom is modest. A ~50% reduction in cache misses might yield 5–10% wall improvement (mid-band 25% × 50% = 12.5% of cycles).
- **Concrete vectors:** Tile sumcheck `fold_and_compute_*` to fit L2; AoS→SoA on Poseidon round-state if not already; co-locate eq-MLE evaluation with sumcheck round to avoid re-streaming.

### Tier 3: Bounded gains

#### (f) Build / compile improvements (LTO, PGO, codegen)
- **Evidence:** ~14% inclusive in rayon plumbing + ~5% iterator-adapter helpers, plus `__sched_yield` at ~1.7% — these often shrink with PGO/`fat` LTO + frame-pointer tuning. Symbol explosion (multiple `permute_mut::h<hash>` LLVM clones) suggests ThinLTO is already effective; PGO would let the optimizer collapse some of the duplicated rayon-closure thunks at hot points.
- **Implication:** **5–10%** wall-clock typical for SIMD-heavy Rust. Cheap to try; bounded ceiling.

#### (e) SIMD utilization improvements
- **Evidence:** IPC 0.91 with AVX-512 already in use (Plonky3 packed-field path is the inner loop of `permute_mut`). The Poseidon kernel is presumably already vectorized; further gains would need micro-arch tuning (Zen 4 zen-specific dispatch widths, FMA pairing).
- **Implication:** **<5%** wall — optimizer is already exploiting the available width. Branch-mis 2.5% rules out branchy fallbacks as the gap.

### Tier 4: Minimal headroom

#### (d) Allocator improvements beyond zk-alloc
- **Evidence:** Clean wall: zk-alloc 24.89 s vs glibc 29.92 s. zk-alloc already cuts 5.0 s (~17%) and 3.5× sys time off glibc. The remaining ~10.8 s of zk-alloc sys time is dominated by the upfront 10.83-GiB arena pre-touch (warmup, included in wall). Per-prove allocator cost during steady state appears sub-second.
- **Implication:** **< 5%** wall headroom from a smarter allocator on this workload. Possible micro-wins: lazier arena pre-touch (would shorten warmup), per-node sub-arenas to release earlier, larger transparent hugepages. None likely to exceed single-percent wins.

### Final ranked table

| Rank | Class | Expected wall improvement | Confidence | Cost to attempt |
|---:|---|---|---|---|
| 1 | (a) Algorithmic — reduce Poseidon count | 5 – 20%+ per design change | High (40% of cycles is one kernel) | High (touches protocol design) |
| 2 | (b) Parallelism — pipeline witness/tracegen/commit | 10 – 15% | Medium-high (4 s of measurable headroom) | Medium |
| 3 | (c) Memory access patterns | 5 – 10% | Medium (stall band is wide) | Medium |
| 4 | (f) Build / PGO / LTO tuning | 5 – 10% | Medium (typical Rust band) | **Low** |
| 5 | (e) SIMD micro-tuning | < 5% | Low (already AVX-512) | High |
| 6 | (d) Allocator beyond zk-alloc | < 5% | Low (already saturated) | Low |

---

## 8. Final Recommendation

**The dominant lever is algorithmic — reducing Poseidon permutation count.** ~40% of total cycles are inside the Poseidon family (permutation + AIR eval). Any protocol change that lowers the per-proof Poseidon-count multiplier (sponge rate up, fewer Merkle hashes per FRI layer, lighter transcript, etc.) translates ≈ 1:1 into wall-clock savings, up to a 10–15% improvement per significant design change. The current `fix/s123-hashing-opt` branch (RATE 8→12 sponge, MMO feed-forward) is exactly this class of change and is well-targeted.

**The second-tier lever is cross-stage pipelining within each prove.** Σ(node times) is 73% of wall; 27% is non-prove overhead, of which ~4 s is partial-serial. Overlapping commit/transcript-finalize with the next stage's tracegen looks like a 10–15% wall opportunity.

**Allocator and SIMD are largely solved.** zk-alloc captures 17% over glibc on this workload; AVX-512 is engaged in the hot kernel. Further effort here yields <5% each.

**Quick win to try:** PGO build (`cargo pgo` or `-Cprofile-use`) — typical ~5–10% on SIMD-heavy Rust with no code changes. This is the highest ROI low-risk experiment.

**Maintenance-vs-optimization decision:** With ~40% of cycles in one kernel and a clear algorithmic lever still being pursued (`fix/s123-hashing-opt`), the system is **not** in the diminishing-returns regime where shifting to maintenance mode is justified. Continued investment in (a) algorithmic and (b) pipelining is warranted; (c)/(f) are second-priority follow-ons.
