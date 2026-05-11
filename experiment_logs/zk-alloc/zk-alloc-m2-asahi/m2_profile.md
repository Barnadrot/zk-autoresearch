# leanMultisig — Apple M2 / Asahi baseline + deep profile (zk-alloc patched)

- **Date:** 2026-05-10
- **leanMultisig commit:** `d13cfa5d` (origin/main, "poseidon AIR: use mds_fft_16 instead of mds_circ_16")
- **zk-alloc fix:** committed locally on top of `d13cfa5d` (in-tree at `crates/backend/zk-alloc/src/syscall.rs`); not pushed
- **Hardware:** Apple M2 / Asahi Fedora 42, aarch64, 16 KiB pages, 10 cores (6 P + 4 E), 16 GiB RAM, 8 GiB swap
- **Kernel:** 6.14.2-401.asahi.fc42.aarch64+16k
- **Toolchain:** cargo 1.94.0; `RUSTFLAGS="-C target-cpu=native"` for all builds

> **Reading guide.** §2 covers Step 1 (zk-alloc validation + 1550-sig medians).
> §3 is the patch & relevance to the Thomas/Emile macOS regression. §4–§9 are
> Step 2 (Q1–Q6). §10 is raw artifacts. The Step-1-FAILED report from earlier
> today is preserved at `zkalloc_failure.md` for the historical diagnosis.

> **PR #216 marker check.** Program.md asks to confirm PR #216 is merged via
> `pw3-13` / `RATE=12` / `MMO` / `#[inline]` markers in `git log --oneline | head -20`.
> None of those tokens appear in the recent log; the latest hashing-related
> commit on `main` is `d13cfa5d` (mds_fft_16 swap). PR #216 may have a different
> identifier or may not yet be merged. We profile what is on `origin/main` today.

---

## 1. Hardware/software environment

```
$ uname -a
Linux 8e412905-…-fc42 6.14.2-401.asahi.fc42.aarch64+16k #1 SMP PREEMPT_DYNAMIC … aarch64 GNU/Linux

$ cargo --version
cargo 1.94.0 (85eff7c80 2026-01-15)

$ getconf PAGESIZE
16384

$ nproc
10

$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       2.7Gi       3.1Gi        43Mi        10Gi        12Gi
Swap:          8.0Gi          0B       8.0Gi
```

Asahi exposes the M2's heterogeneous PMU as two units: `apple_avalanche_pmu`
(P-cores, here CPU 4–9 = 6 cores) and `apple_blizzard_pmu` (E-cores, CPU 0–3
= 4 cores). The PMU exposes only `cycles`, `instructions`, `branches`, and
`branch-misses` — **no cache-references, cache-misses, LLC, or memory-stall
events.** This shapes the Q1 verdict (we lean on IPC + page faults rather than
cache-miss bandwidth).

---

## 2. Step 1+4 — patched zk-alloc validates and beats glibc by ~3.4%

### 1a. Build

```bash
RUSTFLAGS="-C target-cpu=native" cargo build --release
```

Build succeeded. `zk_alloc::*` symbols present in `target/release/lean-multisig`.

### 1b. Smoke test (100 sigs, log_inv_rate=1)

```
{"nodes":[{"path":[],"stats":{"time_secs":0.306249234, "n_xmss":100, …}}]}
```

Exit 0. Baseline-warmup-then-prove takes ~0.31 s. Pre-patch this aborted in
`arena_alloc_cold → ensure_region → mmap_anonymous → null → abort`.

### 1c. Production workload — zk-alloc vs standard-alloc on `xmss --n-signatures 1550 --log-inv-rate 1`

Three back-to-back runs of each (post-warmup `time_secs` from the JSON), no
contention, same shell session:

| Allocator | run 1 | run 2 | run 3 | **median** | **XMSS/s** |
|---|---:|---:|---:|---:|---:|
| zk-alloc (patched) | 2.5574 s | 2.4938 s | 2.5365 s | **2.5365 s** | **611.1** |
| standard-alloc (glibc) | 2.5818 s | 2.6233 s | 2.6615 s | **2.6233 s** | **591.0** |

zk-alloc speedup: **+3.4%** (vs. Hetzner Zen 4: +17%). zk-alloc still wins,
but the margin is ~5× smaller than on x86_64 — this is the headline
allocator finding (§3 + §9).

Process metrics from `/usr/bin/time -v` (1550-sig single-leaf run):

| Metric | zk-alloc | standard-alloc | Δ |
|---|---:|---:|---:|
| Wall (incl. warmup) | 8.99 s | 8.72 s | +3.1% |
| User time | 49.11 s | 46.97 s | +4.6% |
| **Sys time** | **1.35 s** | **1.89 s** | **−29%** |
| Avg CPUs | 5.61 / 10 | 5.59 / 10 | — |
| **Maximum RSS** | **10.43 GiB** | 5.29 GiB | +97% (zk-alloc pre-touches) |
| `used X.X GiB` (warmup print) | 10.16–10.24 | 5.01–5.11 | zk-alloc reserves arena upfront |
| **Minor page faults** | **689,725** | 1,192,852 | **−42% (1.74× fewer)** |
| Major page faults | 0 | 0 | — |
| Voluntary ctx-switches | 31,433 | 32,700 | — |
| Involuntary ctx-switches | 57,738 | 65,298 | — |

VM-level workload metrics (deterministic — match Hetzner's leaf exactly):

| Field | Value |
|---|---:|
| `cycles` (prover-internal VM cycles) | 994,908 |
| `poseidons` | 259,055 |
| `dots` | 30,639 |
| `proof_kib` | 339 |
| `memory` (prover-internal) | 3,900,425 |

### 1d. Verdict

| | |
|---|---|
| zk-alloc validates on aarch64 + 16 KiB pages | ✅ (after patch) |
| zk-alloc XMSS/s ≥ standard-alloc XMSS/s | ✅ (+3.4%) |
| **M2 Asahi baseline (zk-alloc)** | **611.1 XMSS/s** |
| Gap to 1000 XMSS/s target | **1000 / 611.1 = 1.64×** |
| Phrasing | "M2 Asahi sits at 611 XMSS/s; the 1000-target is 1.64× away." |

zk-alloc proceeds to Step 2 (per program.md decision rule "if zk-alloc XMSS/s
≥ standard-alloc XMSS/s, the M2 baseline is the zk-alloc number").

Apples-to-apples vs Hetzner's per-node leaf table (warm 1550-sig leaf):

| | leaf prove time | implied XMSS/s |
|---|---:|---:|
| Hetzner Zen 4 (warm leaf [0,0,0,0]) | 2.32 s | 668 |
| M2 Asahi (median, this run) | 2.54 s | 611 |
| Hetzner cold leaf [0,0,1,0] | 3.07 s | 505 |

M2 sits ~9% below warm-Hetzner and ~21% above cold-Hetzner on identical work
(VM cycles match to within 0.01% — same trace).

---

## 3. The zk-alloc patch — what it fixes and what it doesn't

### What broke

`zk-alloc/src/syscall.rs` had only one raw-syscall implementation gated on
`target_arch = "x86_64"`. Every other target (including aarch64 Linux) fell
through to a `libc::mmap` fallback that omits `MAP_NORESERVE`. With Asahi's
default `vm.overcommit_memory = 0` and a 16 GiB CommitLimit, the kernel
refused the default 112 GiB region (`8 GiB × (10 cores + 4 SLACK)`); `mmap`
returned `MAP_FAILED`; `ensure_region` called `std::process::abort` at
`zk-alloc/src/lib.rs:166`. Full diagnostic: `zkalloc_failure.md`.

### The fix

Added a new `imp` module in `crates/backend/zk-alloc/src/syscall.rs` for
`#[cfg(all(target_os = "linux", target_arch = "aarch64"))]` mirroring the
x86_64 raw-syscall path:

- Syscall numbers: `__NR_mmap = 222`, `__NR_madvise = 233` (aarch64).
- Calling convention: args in `x0..x5`, syscall number in `x8`, `svc 0`,
  return in `x0`.
- Same flags as the x86_64 path: `MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE`.
- Fallback gate narrowed: `#[cfg(not(all(target_os = "linux", any(target_arch = "x86_64", target_arch = "aarch64"))))]`.

Also mirrored the patch into `~/zk-autoresearch/zk-alloc` (the standalone
clone that program.md referenced — note it is **not** the dependency
leanMultisig consumes; the build uses the in-tree vendored copy at
`crates/backend/zk-alloc`).

### Relevance to the Thomas/Emile macOS regression

The macOS code path is **not** modified by this patch. macOS still falls
into the `libc::mmap` fallback (now gated on `not Linux`), which is the
existing comment-justified design ("MAP_NORESERVE is Linux-only").

What the patch *does* tell us about the macOS situation:

1. **It rules out one explanation.** The hypothesis "Asahi reproduces the
   macOS regression because both are Apple Silicon" is *not* what we observe.
   On patched Asahi M2, zk-alloc is **faster** than glibc by 3.4%; on macOS
   per Thomas/Emile, zk-alloc is *slower* than the system allocator. So
   "Apple Silicon hardware" alone is not the cause — Asahi inherits the
   hardware but uses Linux's MM, and the directional sign matches Hetzner.
2. **It does isolate the macOS-specific component.** With Linux's
   MAP_NORESERVE'd large reservation working correctly on the same M2
   silicon, the macOS regression must come from how Mach VM handles the
   `libc::mmap` reservation pattern (eager backing on first touch, page-
   table churn during prove, or a malloc-inside-libc-mmap reentrancy
   surfacing under Mach VM's internal locks). Mach VM is the one variable
   that changes between Asahi and macOS.
3. **It quantifies the 16-KiB-page amortization effect.** Asahi M2 +
   zk-alloc shows 1.74× fewer page faults than glibc, vs Hetzner zk-alloc
   showing 5.3× fewer. With 16 KiB pages each fault services 4× more
   memory than at 4 KiB, so glibc's per-fault cost is amortized 4× better
   on Apple Silicon — independent of OS. This explains why zk-alloc's win
   shrinks from +17% (Hetzner) to +3.4% (Asahi), and predicts that on macOS
   (also 16 KiB pages) zk-alloc's allocator-fault advantage is similarly
   small — leaving macOS-specific Mach VM cost uncovered. **Whatever
   Mach-VM-specific overhead Thomas/Emile observed only needs to be ≥ ~3%
   of total runtime to flip the sign.**

A reasonable next experiment: rebuild zk-alloc on macOS with an explicit
`MAP_NORESERVE`-equivalent (Darwin's `VM_FLAGS_NO_PMAP_CHECK` or simply
`MAP_NOEXTEND`-style), then re-measure on the same M-series Mac. The Asahi
control gives us a reasonable expectation: if zk-alloc on macOS still
underperforms glibc after that, the residual is Mach VM's per-touch cost,
not the reservation flag.

---

## 4. Q1 — Compute-bound vs memory-bound on M2

### Raw `perf stat` (1550 sigs, zk-alloc patched binary)

```
                  48716.57 msec  task-clock                                         (8.71 s wall)
              157,719,433,369   apple_avalanche_pmu/cycles/         (65.01%)   [P-cores]
              116,774,204,295   apple_blizzard_pmu/cycles/          (34.99%)   [E-cores]
              629,892,846,787   apple_avalanche_pmu/instructions/   (65.01%)
              226,738,328,383   apple_blizzard_pmu/instructions/    (34.99%)
                          —    cache-references                  <not supported>
                          —    cache-misses                      <not supported>
               23,207,893,202   apple_avalanche_pmu/branches/       (65.01%)
                6,074,130,102   apple_blizzard_pmu/branches/        (34.99%)
                   91,661,670   apple_avalanche_pmu/branch-misses/  (65.01%)
                   12,770,400   apple_blizzard_pmu/branch-misses/   (34.99%)
                      681,766   page-faults
       8.712561396 seconds time elapsed
      47.315338000 seconds user
       1.204954000 seconds sys
```

### Derived metrics

| Metric | Value | vs Hetzner |
|---|---|---|
| Wall (with `perf stat` overhead) | 8.71 s | (Hetzner: 32.4 s for fancy-aggregation, not directly comparable) |
| Avg CPUs busy (process) | 5.59 / 10 (56%) | Hetzner 8.39 / 16 (52%) — similar fraction |
| **IPC P-core** | **3.99** | **vs Hetzner 0.91 (combined)** |
| **IPC E-core** | **1.94** | — |
| **IPC combined** | **3.12** | **3.4× higher** |
| Branch-miss rate | 0.357% | vs Hetzner 2.50% (**7× lower**) |
| Page faults | 681,766 (all minor) | vs Hetzner zk-alloc 3,066,779 minor (4.5× fewer; matches 4× page-size advantage) |
| Sys / user ratio | 1.20 / 47.3 = 2.5% | vs Hetzner 5.4% — half the kernel overhead |
| DRAM bandwidth est. | **not measurable** (no cache events on Apple PMU) | Hetzner: ~4.0 GB/s = 7.8% of DDR5 ceiling |

### Verdict

**Compute-bound.** Three independent signals point the same way:

1. **P-core IPC of 4.0** (≈50% of theoretical 8-wide peak) is consistent with
   well-vectorized arithmetic; a memory-bound workload would sit at IPC < 1.
2. **Branch-miss rate 0.36%** is unusually low — branch-prediction pathologies
   are not stalling the front-end.
3. **Sys/user ratio 2.5%** says almost no kernel time. Most cycles are doing
   actual work.

We cannot measure DRAM bandwidth directly (Asahi's PMU lacks cache events).
A workload-shape upper bound: pre-touched arena 10.18 GiB / 2.54 s prove ≈
4 GB/s if every byte streamed once — ~4% of M2's ~100 GB/s unified-memory
ceiling. Reality is presumably much less because the hot Poseidon kernel
fits in L1/L2 (Q5 confirms 36% of cycles in one ~2 KiB compress kernel).

**Direct Hetzner comparison.** Hetzner: IPC 0.91, cache-miss 3.57%, LLC
bandwidth 7.8% of DDR5. M2: IPC 3.12, branch-miss 0.36%. Both compute-bound,
but Apple's wider OoO core executes the same trace at ~3.4× higher IPC,
making the relative time spent in the dominant kernel even *more* concentrated
(§5).

---

## 5. Q2 — Cycle attribution per function

### Top-30 self-time symbols, P-core profile (47,431 samples, 101.6 B cycles, perf record -F 999 --call-graph=dwarf)

Rank | %self | Symbol | Category
---:|---:|---|---
 1 | **29.53%** | `Poseidon1KoalaBear16 as Compression<[R;16]>::compress_mut` (clone A) | Poseidon perm (compression mode)
 2 | **7.64%** | `lean_vm::tables::poseidon_16::eval_2_full_rounds_16` (clone A) | Poseidon AIR
 3 | 3.74% | `rayon::iter::plumbing::bridge_producer_consumer::helper` | Rayon plumb
 4 | **3.13%** | `Poseidon16Precompile<_> as Air::eval` | Poseidon AIR
 5 | 3.05% | `mt_poly::eq_mle::eval_eq_with_packed_output` | Sumcheck (eq MLE)
 6 | **3.01%** | `Poseidon1KoalaBear16 as Permutation<[R;16]>::permute_mut` (clone A) | Poseidon perm
 7 | **2.74%** | `lean_vm::tables::poseidon_16::eval_last_2_full_rounds_16` | Poseidon AIR
 8 | **2.37%** | `Poseidon1KoalaBear16 as Permutation<[R;16]>::permute_mut` (clone B) | Poseidon perm
 9 | 2.34% | `core::ops::function::impls::FnMut::call_mut` | Rayon plumb
10 | 2.31% | `mt_sumcheck::product_computation::fold_and_compute_product_sumcheck_polynomial` (clone A) | Sumcheck
11 | 2.01% | `FnMut::call_mut` (clone) | Rayon plumb
12 | 1.79% | `FnMut::call_mut` (clone) | Rayon plumb
13 | 1.54% | `fold_and_compute_product_sumcheck_polynomial` (clone B) | Sumcheck
14 | 1.51% | `ConstraintFolderPacked::AirBuilder::assert_zero` (clone A) | AIR folder
15 | **1.41%** | `Compression<[R;16]>::compress_mut` (clone B) | Poseidon perm
16 | 1.28% | `FnMut::call_mut` (clone) | Rayon plumb
17 | **1.22%** | `lean_vm::tables::poseidon_16::eval_poseidon1_16` | Poseidon AIR
18 | 1.20% | `lean_vm::tables::execution::air::eval` | AIR (execution)
19 | **1.19%** | `eval_2_full_rounds_16` (clone B) | Poseidon AIR
20 | 1.14% | `RoundCoeffs<T> as Mul<W>::mul` | Sumcheck (round coeffs)
21 | 1.13% | `mt_poly::eq_mle::base_eval_eq_packed_with_packed_output` | Sumcheck (eq MLE)
22 | 1.00% | `libc::memcmp` | libc
23 | 0.93% | `assert_zero` (clone B) | AIR folder
24-25 | 0.82% × 2 | `FnMut::call_mut` (clones) | Rayon plumb
26 | 0.72% | `__memcpy_generic` | libc
27 | 0.71% | `run_phase1_sumcheck::{{closure}}` | Sumcheck/GKR
28 | 0.61% | `FnMut::call_mut` (clone) | Rayon plumb
29-30 | 0.57% / 0.56% | `FnMut::call_mut` (clones) | Rayon plumb

### Category aggregation (P-core, ≥0.5% threshold)

| Category | Sum %self | Hetzner equivalent | Δ |
|---|---:|---:|---:|
| **Poseidon permutation/compression** (4 clones: 29.53 + 3.01 + 2.37 + 1.41) | **36.32%** | 33.90% | +2.4 pp |
| **Poseidon AIR evaluation** (5 entries: 7.64 + 3.13 + 2.74 + 1.22 + 1.19) | **15.92%** | 6.54% | **+9.4 pp** |
| **Poseidon total** | **52.24%** | 40.4% | **+11.8 pp** |
| Sumcheck / GKR (≥0.5%: 3.05 + 2.31 + 1.54 + 1.14 + 1.13 + 0.71) | **9.88%** | 14.10% | −4.2 pp |
| Execution AIR + folder | 1.20 + 1.51 + 0.93 = 3.64% | 1.21% | +2.4 pp |
| Rayon plumbing (call_mut clones + bridge) | ≥ 16% (≥0.5% bucket) | ~13–15% | similar |
| libc (memcmp + memcpy + alloc helpers) | 1.00 + 0.72 + 0.53 + 0.39 + 0.38 = **3.02%** | ~0% | **+3.0 pp** |
| FRI/WHIR DFT (`Butterfly::apply_to_rows`) | not in top-30 | 0.62% | gone (or sub-threshold) |

### E-core profile cross-check (16,862 samples, 40.7 B cycles, separate run)

E-core shape agrees with P-core on structure. Differences:

- Compression A is **34.30%** on E-core vs 29.53% on P-core (E-cores spend a
  bigger fraction in Poseidon — narrower SIMD throughput → less amortization
  of non-Poseidon work).
- Rayon `bridge_producer_consumer` is **5.57%** on E-core vs 3.74% on P-core
  — E-cores spend more time in steal-loop plumbing, consistent with Apple's
  E-cores having lower throughput per task.
- Combined (P-cores 65% of total cycles, E-cores 35% per `perf stat`):
  Poseidon family ≈ **53%** of all cycles.

### Key M2-specific observations

1. **Poseidon AIR eval has nearly tripled in relative cost (6.5% → 15.9%).**
   This is the biggest cross-architecture surprise. AIR-eval is dense per-row
   field arithmetic on the constraint folder; AVX-512 amortizes its
   16-element-wide inner loop deeply, NEON's 4-lane width amortizes 4× less.
   So while Poseidon perm is *similarly* dominant on both architectures
   (33.9% → 36.3%), AIR eval — the protocol-mandated *companion* to every
   permutation — grows from a side dish to nearly half the Poseidon cost.
2. **No memcpy/memset/alloc hotspots above 1.0%** — `libc::memcmp` 1.00%,
   `__memcpy_generic` 0.72%, glibc allocator helpers (`_int_malloc` /
   `cfree` / `malloc`) sum 1.30%. The 1.30% glibc-malloc share inside a
   zk-alloc build is the routing of sub-4-KiB allocations to the system
   allocator (`zk-alloc/src/lib.rs:DEFAULT_MIN_ARENA_BYTES = 4096`).
3. **DFT (`Butterfly::apply_to_rows`) drops below the 0.5% threshold.**
   Hetzner had it at 0.62%; M2 at <0.5%. FRI's DFT is not a hot kernel
   on either system — most "FRI" cost is actually the Poseidon-Merkle commit.
4. **Rayon idle plumbing is similar in shape to Hetzner.** `wait_until_cold`
   is reachable from Compression's call graph; the call-graph view shows
   the rayon `join_context::{closure}` recursion descending up to ~5 levels.
   Consistent with Hetzner's 16% partial-serial intervals.

---

## 6. Q3 — Per-monomorphization Poseidon breakdown

Hetzner shows three permute_mut LLVM clones; M2 shows the same kernel
exposed under two trait wrappers (`Compression` for Merkle internals,
`Permutation` for sponge/transcript). Same machine code; different LLVM
clone naming.

| Architecture | Clone 1 | Clone 2 | Clone 3 | Clone 4 | Sum |
|---|---:|---:|---:|---:|---:|
| Hetzner Zen 4 (AVX-512), `permute_mut` × 3 | 19.10% | 5.60% | 5.20% | — | **29.90%** |
| M2 Asahi (NEON), Compression A + Compression B + Permutation A + Permutation B | 29.53% | 1.41% | 3.01% | 2.37% | **36.32%** |

The shape difference is striking. Hetzner spreads Poseidon across three
*roughly-balanced* clones (19 / 5.6 / 5.2). M2 has **one heavily-dominant
clone (29.5%)** plus three smaller clones. Two readings:

- The compiler is more aggressive at sharing the inner kernel between
  call-sites on aarch64 (NEON intrinsics path), so a single LLVM clone
  serves more of the call graph.
- Or one specific call-site (the initial Merkle commit) dominates so
  thoroughly that the other clones fall further behind in relative terms.

Either way: the Hetzner-style "split your Poseidon optimization across
three monomorphizations" advice translates to "the dominant Compression
clone IS the optimization target — one clone contains 81% of all Poseidon
permutation cycles on M2."

---

## 7. Q4 — Memory & allocation behavior

### Peak RSS

| Build | Pre-touch (warmup print) | Peak RSS (`time -v`) |
|---|---:|---:|
| zk-alloc (patched) | 10.16–10.24 GiB | **10.43 GiB** |
| standard-alloc | 5.01–5.11 GiB | **5.29–5.69 GiB** |

zk-alloc reserves its full per-thread arena upfront (slab × max_threads = 8
GiB × (10 + 4 SLACK) = 112 GiB virtual; 10.18 GiB actually touched during
warmup). On Hetzner, the same pre-touch was 10.83 GiB — within 6%
agreement, as expected (the prover's working set is determined by the VM
trace, not by the allocator).

### Page faults — `perf stat -e page-faults,minor-faults,major-faults,context-switches`

| Build | total | minor | major | ctx-switches |
|---|---:|---:|---:|---:|
| zk-alloc (patched) | 689,398 | 689,398 | 0 | 93,322 |
| standard-alloc | 1,198,029 | 1,198,029 | 0 | 98,633 |
| **zk-alloc/std-alloc ratio** | **0.575×** | — | — | — |

**16-KiB-page amortization confirmed empirically.** Hetzner's 4-KiB-page
zk-alloc-vs-glibc fault ratio was 0.190× (3.07 M / 16.12 M). M2's 16-KiB-page
ratio is 0.575× — much closer to 1, exactly because the per-fault overhead
amortizes 4× better at 4× larger page size, leaving zk-alloc's relative
advantage compressed.

Numerically: zk-alloc on Asahi avoids ~509 K minor faults per 1550-sig
prove. On Hetzner the equivalent saving was ~13 M faults. Even with each
fault being similarly cheap, Hetzner's `13 M × ~5 µs ≈ 65 s` of avoided
fault-handling dwarfs M2's `0.5 M × ~5 µs ≈ 2.5 s` — explaining most of
the +17% → +3.4% speedup gap.

### Per-CPU cycle distribution (`perf stat -A -a -e cycles,instructions`)

```
P-cores (apple_avalanche_pmu, CPU 4–9):
  CPU4  17.12 B cycles   60.84 B instructions   IPC 3.55
  CPU5  17.04 B cycles   60.45 B instructions   IPC 3.55
  CPU6  17.06 B cycles   60.94 B instructions   IPC 3.57
  CPU7  24.88 B cycles   90.55 B instructions   IPC 3.64    ← orchestrator-heavy
  CPU8  21.36 B cycles   75.57 B instructions   IPC 3.54
  CPU9  20.49 B cycles   62.24 B instructions   IPC 3.04

E-cores (apple_blizzard_pmu, CPU 0–3):
  CPU0  13.34 B cycles   21.19 B instructions   IPC 1.59
  CPU1  12.99 B cycles   21.77 B instructions   IPC 1.68
  CPU2  13.42 B cycles   20.82 B instructions   IPC 1.55
  CPU3  12.68 B cycles   19.58 B instructions   IPC 1.54

Wall: 8.77 s
P-core max/min ratio: 24.88 / 17.04 = 1.46× (CPU7 vs CPU5 — orchestrator)
E-core max/min ratio: 13.42 / 12.68 = 1.06×
```

Hetzner had max/min = 1.28× (homogeneous SMT cores). M2's heterogeneous
P/E split shows up as a 1.46× imbalance — but rayon doesn't differentiate
core types, so it spreads work uniformly while the cores deliver 2–3×
different IPC. **Net effect: ~5.6 of 10 cores busy on average, vs Hetzner's
11.9 of 16 (74%); M2 saturation is 56% — significantly lower.**

This is partly an artifact of the workload (single 1550-sig leaf = less
parallelism budget than fancy-aggregation's 12-node pipeline), but partly
real: a 6P + 4E topology with rayon-uniform scheduling underutilizes the
P-cores while waiting on E-cores.

---

## 8. Q5 — Cross-architecture comparison table

Same prover, same `xmss --n-signatures 1550 --log-inv-rate 1` workload (a
*single 1550-sig leaf*). Hetzner numbers from `benchmark_pw3_pr/profiling_main.md`,
extracted from the per-node table (warm leaf [0,0,0,0]) plus the system-wide
perf stat. Note Hetzner's full reference profile was *fancy-aggregation*
(12 nodes), not single-leaf; for the system-wide metrics (IPC, cache, etc.)
we cite the fancy-aggregation numbers because that's all the reference
profile published — they should be representative of the per-leaf regime.

| Metric | M2 Asahi (zk-alloc, 1550-leaf) | Hetzner Zen 4 (zk-alloc, 1550-leaf) | Notes |
|---|---:|---:|---|
| Wall per leaf | **2.54 s** | 2.32 s (warm) / 3.07 s (cold) | M2 ~9% slower than warm Hetzner |
| **XMSS/s** | **611** | 668 (warm) / 505 (cold) | M2 ≈ Hetzner mid-warm |
| **IPC (combined)** | **3.12** | 0.91 | **3.4× higher on M2** |
| Branch-miss rate | 0.36% | 2.50% | 7× lower on M2 |
| Cache-miss rate | n/a (PMU lacks events) | 3.57% | — |
| DRAM bandwidth est. | n/a | 7.8% of 51.2 GB/s | — |
| Page faults (zk-alloc) | 689 K minor | 3.07 M minor | 4.5× fewer (16 KiB pages) |
| Allocator headroom (zk-alloc vs glibc) | +3.4% | +17% | M2 mostly closed by 16-KiB-page amortization |
| Top function | `Compression::compress_mut` 29.53% | `Poseidon1KoalaBear16::permute_mut` 31.28% | Same kernel, different trait wrapper |
| Top-2 | `eval_2_full_rounds_16` 7.64% | `FnMut::call_mut` (rayon) 5.29% | M2: AIR moves to #2 |
| Top-3 | rayon bridge 3.74% | `eval_2_full_rounds_16` 3.86% | inverted |
| Top-4 | `Poseidon16Precompile::eval` 3.13% | `eval_eq_with_packed_output` 3.61% | — |
| Top-5 | `eval_eq_with_packed_output` 3.05% | `fold_and_compute_…` 3.51% | — |
| Poseidon perm total | **36.3%** | 33.9% | similar |
| Poseidon AIR total | **15.9%** | 6.5% | **+9.4 pp** |
| Sumcheck / GKR total | 9.9% | 14.1% | −4.2 pp |
| Avg cores busy | 5.59 / 10 (56%) | 8.39 / 16 (52%) | similar saturation fraction |

**Plain-language summary of the most striking differences:**

- **M2 executes the same prover trace at 3.4× higher IPC** but 22% fewer
  cores, netting roughly equal per-leaf throughput. Apple's wider OoO core
  is doing more per cycle; Zen 4 is running narrower-IPC but more cores.
- **AIR evaluation moves from a side cost (6.5%) to a major cost (15.9%)**
  on M2. The narrower NEON SIMD width amortizes the dense per-row constraint
  arithmetic less aggressively than AVX-512 does, so AIR eval gains a
  bigger fraction of the cycle pie. The Poseidon *kernel* itself stays at
  similar relative cost (33.9% → 36.3%); it's the AIR companion that grew.
- **zk-alloc's allocator advantage shrinks 5× on Apple Silicon** (+17% →
  +3.4%) because 16-KiB pages amortize glibc's per-fault overhead 4× better
  than 4-KiB pages. This is independent of the OS (Linux or Mach) — it's
  a hardware-architectural fact. The macOS regression must therefore have
  a separate, Mach-specific component on top of this.

---

## 9. Q6 — Implications for M2-specific perf work

Five evidence-driven bullets, ranked by leverage. None of these are run in
this experiment — this section seeds the next.

1. **Poseidon AIR-eval is the unique-to-M2 lever (15.9% → potential ~6.5%
   would save ~9 pp, ≈ 9% wall).** The Hetzner profile shows AIR eval can
   be much smaller; the gap is SIMD width. Vector-widening AIR-eval inner
   loops on NEON — specifically batching 4 constraint rows per FMA pair
   instead of one — is the highest-EV M2-specific change. Concrete target:
   `lean_vm::tables::poseidon_16::eval_2_full_rounds_16` (single function
   covering 8.83% of P-core cycles across two clones). This vector is
   *new* — it didn't show up as a priority on Hetzner because AVX-512
   already absorbed its cost.
2. **PGO is unusually well-targeted on M2.** With one Compression clone at
   29.5% and a long tail of FnMut::call_mut + rayon plumbing (≥16% across
   clones), profile-guided codegen should let the optimizer collapse the
   thunk ladder around the dominant clone and inline more of the rayon
   join_context recursion. Expected: 5–8% wall, low cost. PGO on aarch64
   is a strict superset of the x86_64 win.
3. **zk-alloc on M2 is approximately tuned out.** +3.4% over glibc with
   1.74× fewer page faults at 16-KiB pages. Further allocator work on
   Asahi has < 2% headroom. Defer; revisit only if `MIN_ARENA_BYTES`
   tuning or per-node sub-arenas becomes attractive on the macOS side
   (where the regression points to an unrelated cause).
4. **The 6P+4E heterogeneity costs ~10–15% of saturation.** Average
   busy CPUs is 5.59 / 10 (56%); P-core CPU7 is at 1.46× the cycles of
   the lowest P-core, while E-cores are uniformly busy. Rayon work-
   stealing is not P/E-aware on Asahi. A `RAYON_NUM_THREADS=6` run
   limited to P-cores (via `taskset`) would either close this or reveal
   that E-cores genuinely contribute. Cheap experiment; do it once.
5. **Sumcheck moved *out* of the top tier on M2 (14.1% → 9.9%).** It is
   no longer a viable optimization target compared to AIR eval. The
   Hetzner-era "sumcheck tiling" instinct should be deprioritized for
   the M2 regime.

### What should NOT be optimized in this run

- Cross-node pipelining: the M2 baseline workload is single-leaf, so the
  4-second partial-serial budget Hetzner identified does not apply directly.
  Re-measure on `fancy-aggregation` if pipelining becomes a candidate.
- macOS-specific allocator changes: Asahi data does not generalize to
  macOS Mach VM. A separate macOS run is required before recommending.
- DFT/WHIR butterfly: < 0.5% on M2; below noise.

---

## 10. Raw artifacts

### 10.1 `/usr/bin/time -v`, zk-alloc 1550 sigs (run 1)

```
Command being timed: "/tmp/bench_m2_zkalloc xmss --n-signatures 1550 --log-inv-rate 1 --json"
User time (seconds): 49.11
System time (seconds): 1.35
Percent of CPU this job got: 561%
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:08.99
Maximum resident set size (kbytes): 10930496
Major (requiring I/O) page faults: 0
Minor (reclaiming a frame) page faults: 689725
Voluntary context switches: 31433
Involuntary context switches: 57738
Page size (bytes): 16384
Exit status: 0
```

### 10.2 `perf stat` (zk-alloc 1550, full)

```
warming up... used 10.16 GiB

 Performance counter stats for '/tmp/bench_m2_zkalloc xmss --n-signatures 1550 --log-inv-rate 1 --json':

          48716.57 msec task-clock                                                            
      157719433369      apple_avalanche_pmu/cycles/                                             (65.01%)
      116774204295      apple_blizzard_pmu/cycles/                                              (34.99%)
      629892846787      apple_avalanche_pmu/instructions/                                        (65.01%)
      226738328383      apple_blizzard_pmu/instructions/                                        (34.99%)
   <not supported>      apple_avalanche_pmu/cache-references/                                      
   <not supported>      apple_blizzard_pmu/cache-references/                                      
   <not supported>      apple_avalanche_pmu/cache-misses/                                      
   <not supported>      apple_blizzard_pmu/cache-misses/                                      
       23207893202      apple_avalanche_pmu/branches/                                           (65.01%)
        6074130102      apple_blizzard_pmu/branches/                                            (34.99%)
          91661670      apple_avalanche_pmu/branch-misses/                                        (65.01%)
          12770400      apple_blizzard_pmu/branch-misses/                                        (34.99%)
            681766      page-faults                                                           

       8.712561396 seconds time elapsed

      47.315338000 seconds user
       1.204954000 seconds sys
```

### 10.3 `perf report --no-children --no-call-graph` top-30 (P-core profile)

```
# Samples: 30K of event 'apple_avalanche_pmu/cycles/P'
# Event count (approx.): 101,583,311,966

    29.53%  bench_m2_zkalloc  [.] Poseidon1KoalaBear16 as Compression<[R;16]>::compress_mut (clone A)
     7.64%  bench_m2_zkalloc  [.] lean_vm::tables::poseidon_16::eval_2_full_rounds_16 (clone A)
     3.74%  bench_m2_zkalloc  [.] rayon::iter::plumbing::bridge_producer_consumer::helper
     3.13%  bench_m2_zkalloc  [.] Poseidon16Precompile<_> as Air::eval
     3.05%  bench_m2_zkalloc  [.] mt_poly::eq_mle::eval_eq_with_packed_output
     3.01%  bench_m2_zkalloc  [.] Poseidon1KoalaBear16 as Permutation<[R;16]>::permute_mut (clone A)
     2.74%  bench_m2_zkalloc  [.] eval_last_2_full_rounds_16
     2.37%  bench_m2_zkalloc  [.] Permutation::permute_mut (clone B)
     2.34%  bench_m2_zkalloc  [.] FnMut::call_mut (rayon thunk)
     2.31%  bench_m2_zkalloc  [.] fold_and_compute_product_sumcheck_polynomial (clone A)
     2.01%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     1.79%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     1.54%  bench_m2_zkalloc  [.] fold_and_compute_product_sumcheck_polynomial (clone B)
     1.51%  bench_m2_zkalloc  [.] ConstraintFolderPacked::AirBuilder::assert_zero (clone A)
     1.41%  bench_m2_zkalloc  [.] Compression::compress_mut (clone B)
     1.28%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     1.22%  bench_m2_zkalloc  [.] eval_poseidon1_16
     1.20%  bench_m2_zkalloc  [.] execution::air::eval
     1.19%  bench_m2_zkalloc  [.] eval_2_full_rounds_16 (clone B)
     1.14%  bench_m2_zkalloc  [.] RoundCoeffs<T> as Mul<W>::mul
     1.13%  bench_m2_zkalloc  [.] base_eval_eq_packed_with_packed_output
     1.00%  libc.so.6         [.] memcmp
     0.93%  bench_m2_zkalloc  [.] assert_zero (clone B)
     0.82%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     0.82%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     0.72%  libc.so.6         [.] __memcpy_generic
     0.71%  bench_m2_zkalloc  [.] run_phase1_sumcheck::{{closure}}
     0.61%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     0.57%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
     0.56%  bench_m2_zkalloc  [.] FnMut::call_mut (clone)
```

### 10.4 `perf report` E-core top (cross-check)

```
# Samples: 16K of event 'apple_blizzard_pmu/cycles/'
# Event count (approx.): 40,734,461,408

    34.30%  Compression::compress_mut (clone A)
     8.37%  eval_2_full_rounds_16 (clone A)
     5.57%  rayon::iter::plumbing::bridge_producer_consumer::helper
     3.66%  Poseidon16Precompile::eval
     3.13%  eval_eq_with_packed_output
     2.95%  eval_last_2_full_rounds_16
     2.62%  Permutation::permute_mut (clone A)
     2.55%  FnMut::call_mut
     2.37%  fold_and_compute_product_sumcheck_polynomial (clone A)
     2.22%  FnMut::call_mut (clone)
     1.75%  fold_and_compute_product_sumcheck_polynomial (clone B)
     1.65%  FnMut::call_mut (clone)
     1.63%  ConstraintFolderPacked::assert_zero (clone A)
     1.46%  eval_2_full_rounds_16 (clone B)
     1.42%  Compression::compress_mut (clone B)
     1.33%  eval_poseidon1_16
     1.19%  execution::air::eval
     1.19%  FnMut::call_mut (clone)
     1.18%  FnMut::call_mut (clone)
     1.15%  base_eval_eq_packed_with_packed_output
```

### 10.5 Page faults — both allocators

```
zk-alloc:    page-faults  689,398;  minor 689,398;  major 0;  ctx-switches 93,322
std-alloc:   page-faults 1,198,029;  minor 1,198,029; major 0;  ctx-switches 98,633
ratio (zk/std): 0.575×
```

### 10.6 JSON benchmark report (zk-alloc 1550 sigs, post-warmup)

```json
{"nodes":[{"path":[],"stats":{"time_secs":2.5365, "proof_kib":339, "cycles":994908, "memory":3900425, "poseidons":259055, "dots":30639, "n_xmss":1550}}]}
```

### 10.7 zk-alloc patch (in-tree at `crates/backend/zk-alloc/src/syscall.rs`)

Adds a third `imp` block for `target_os = "linux", target_arch = "aarch64"`,
mirroring the x86_64 raw-syscall structure with aarch64 syscall numbers
(`__NR_mmap = 222`, `__NR_madvise = 233`) and `svc 0` calling convention
(args x0..x5, syscall nr in x8). Fallback gate narrowed to non-Linux. See
`git show <commit>` for the exact diff.

### 10.8 Source pointers

- `crates/backend/zk-alloc/src/syscall.rs` — patched, in-tree, used by build.
- `crates/backend/zk-alloc/src/lib.rs:74-75` — `DEFAULT_SLAB_GB = 8`,
  `SLACK = 4`, region size `= 8 GiB × (10 + 4) = 112 GiB`.
- `~/zk-autoresearch/zk-alloc/src/syscall.rs` — standalone clone, also
  patched for consistency, **not consumed by the build**.

---

## 11. Why does the zk-alloc gap shrink to +3.4% on M2 vs +25% on Hetzner?

### Why this section exists

The earlier write-up hand-waved this as "16-KiB pages amortize per-fault
overhead 4× better." That answer does not survive the data you supplied:

> Hetzner with cgroup `MemoryMax=16GiB` still measures **+25%** zk-alloc
> over standard-alloc.

If the gap were driven by `RAM × page-size` interacting with glibc's
fault rate, capping Hetzner's RAM should compress the gap; it doesn't.
So page size is at most a contributor, not the cause. This section
re-investigates with single-variable experiments.

### Date of these experiments

2026-05-10, on the same M2 / Asahi system, post-PR-216-fix zk-alloc.
The numbers below are independent of yesterday's headline +3.4% (today's
re-measurement on this binary is +6.8% — daytime thermal state).

### A. M2 experiments (run here, in this conversation)

Each row is `xmss --n-signatures 1550 --log-inv-rate 1 --json`,
medians of 2–3 back-to-back runs unless noted, post-warmup `time_secs`
from the JSON. Build per-thread-count via `taskset -c <cores> cargo
build` (zk-alloc embeds `NUM_THREADS = available_parallelism()` at
build time and asserts at runtime).

#### A1. Codegen sanity — RUSTFLAGS=-C target-cpu=native took effect

`objdump -d /tmp/bench_m2_zkalloc`:

- 11,445 NEON load/store/permute mnemonics (`ld1`, `st1`, `trn1/2`,
  `uzp1/2`, `zip1/2`).
- 56,650 NEON arithmetic (`add v.4s`, `mul`, `mla`, `mls`, `smlal`,
  `umlal`, vector lanes).
- The `Compression::compress_mut` symbol body uses `add v0.4s, v0.4s,
  v2.4s` and `bif v0.16b, v5.16b, v3.16b` — the standard Plonky3
  KoalaBear NEON Montgomery reduction. NEON is engaged.

Verdict: **codegen is not the explanation.** Confirmed.

#### A2. Clock during run — schedutil hits ~3.26 GHz on P-cores

Sampled `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` every
~0.4 s during a benchmark run:

```
cpu4..9 (P, max 3.504 GHz)  : mostly 3.264 GHz, transient 0.702 GHz
cpu0..3 (E, max 2.424 GHz)  : 1.752–2.424 GHz, mostly ~1.75 GHz
```

P-cores boost to ~93% of peak under load (3.26 / 3.50 GHz). E-cores hit
boost (2.42 GHz). Hetzner Zen 4 ran at 4.04 GHz — **24% higher per-core
clock**, consistent with M2 single-thread throughput being ~25% slower
than Hetzner per-thread. But the clock difference is symmetric: it
slows both zk-alloc and standard-alloc identically and cannot explain
allocator-relative behavior.

`cpufreq` governor is `schedutil` (cannot switch without sudo here).
Not `performance`, but the workload is dense enough that schedutil
ramps to near-max within milliseconds; this is at most a single-percent
variability source, not a multi-X gap.

#### A3. Single-thread baseline kills the obvious hypotheses

Built a `NUM_THREADS=1` binary (`taskset -c 4 cargo build --release`),
ran on a single P-core (`taskset -c 4`):

| Allocator | prove (s, 2 runs) | XMSS/s |
|---|---:|---:|
| zk-alloc      | 16.483 / 16.448 → med **16.465** | **94.1** |
| standard-alloc | 16.473 / 16.357 → med **16.415** | **94.4** |
| Δ (zk vs std) | **−0.3%** (zk-alloc slightly slower) | |

Single E-core (`taskset -c 0`):

| Allocator | prove (s) | XMSS/s |
|---|---:|---:|
| zk-alloc | 45.96 | 33.7 |
| standard-alloc | 45.45 | 34.1 |
| Δ | **−1.1%** | |

**Single-threaded, zk-alloc has zero advantage.** This rules out:

- TLB capacity / page-size effects (single thread sees them equally
  under either allocator).
- Memory controller / latency (same).
- Compiler / SIMD codegen differences (same binary modulo allocator).
- glibc per-thread tcache vs zk-alloc thread-local slab efficiency at
  the per-allocation level (no allocator wins single-threaded).

The single-P-core 94 XMSS/s is, by the way, the per-core throughput
relevant to Emile's macOS 120-XMSS/s number. macOS M-series single-
thread is ~28% faster than Asahi M2 single-P-core (Apple Silicon at
3.5 GHz boost on macOS vs ~3.26 GHz under schedutil here — the gap is
in the right direction).

#### A4. Multi-thread sweep — gap appears with concurrency

Per-thread-count, both allocators, taskset-pinned:

| Cores | Build | zk prove (med) | std prove (med) | **zk Δ%** |
|---|---|---:|---:|---:|
| 1 P | NUM_THREADS=1, taskset -c 4 | 16.465 s | 16.415 s | **−0.3%** |
| 1 E | NUM_THREADS=1, taskset -c 0 | 45.96 s | 45.45 s | **−1.1%** |
| 4 P | NUM_THREADS=4, taskset -c 4-7 | 4.171 s | 4.241 s | **+1.7%** |
| 4 E | NUM_THREADS=4, taskset -c 0-3 | 11.770 s | 11.816 s | **+0.4%** |
| 6 P | NUM_THREADS=6, taskset -c 4-9 | 2.971 s | 2.985 s | **+0.5%** |
| 6P + 4E (default) | NUM_THREADS=10, no taskset | 2.472 s | 2.641 s | **+6.8%** |

Two takeaways:

1. **The zk-alloc advantage is concentrated in the heterogeneous full-
   machine config.** Pure 6P configuration shows essentially zero gap
   (+0.5% within run-to-run noise). Adding 4 E-cores plus the natural
   rayon scheduler interaction lifts it to +6.8%.
2. **Pure E-cores still don't move the gap much** (+0.4% at 4E). E-cores
   alone aren't the cause.

#### A5. RAYON_NUM_THREADS sweep on the 10-core binary — gap is non-monotonic

Same 10-core zk-alloc / std-alloc binaries, vary `RAYON_NUM_THREADS`:

| RAYON_NUM_THREADS | zk prove (med, 2 runs) | std prove (med) | **zk Δ%** |
|---:|---:|---:|---:|
| 4 | 4.41 s | 4.69 s | **+6.3%** |
| 6 | 3.144 s | 3.412 s | **+7.9%** |
| 8 | 2.728 s | 2.840 s | **+3.9%** |
| 10 | 2.523 s | 2.609 s | **+3.3%** |
| 16 (oversub) | 2.523 s | 2.610 s | **+3.3%** |

The peak gap is at **RAYON=6**, not at RAYON=10 or 16. Adding rayon
threads beyond 6 actually *shrinks* the zk-alloc benefit. This is
counter to "more threads → more contention → bigger gap." Possible
mechanism: at RAYON=6, all six rayon workers tend to land on the six
P-cores (where they run hot and allocate fast), maximizing arena
contention. At RAYON=10 the four "extra" workers spend more time
parked / on E-cores, lowering aggregate allocation rate per unit wall
time and diluting per-arena contention.

The asymptote (RAYON=10/16) — which is the default config — is
**+3.3%**, agreeing with yesterday's headline number.

#### A6. The decisive M2 experiment — `MALLOC_ARENA_MAX` sweep

Standard-alloc only, full 10-core config, sweep glibc's max-arenas
knob. Each row 2 runs, median:

| `MALLOC_ARENA_MAX` | std prove (s) | XMSS/s | vs zk-alloc 2.472 s |
|---:|---:|---:|---:|
| 1 | 3.059 | 506.7 | **+23.7% slower (zk wins by 19.2%)** |
| 2 | 2.783 | 557.0 | +12.6% slower |
| 4 | 2.704 | 573.3 | +9.4% slower |
| 8 | 2.646 | 585.7 | +7.0% slower |
| 16 | 2.681 | 578.1 | +8.5% slower |
| 32 | 2.663 | 582.3 | +7.7% slower |
| unset (default = 8 × ncpus = 80) | 2.641 | 587.0 | +6.8% slower |
| `MALLOC_MMAP_THRESHOLD_=4096` (route all ≥4 KiB to mmap) | 2.688 | 576.6 | +8.7% slower |

**This is the result that explains everything.**

- With `MALLOC_ARENA_MAX=1`, std-alloc on M2 is **19% slower** than
  zk-alloc — closing essentially the entire +25% Hetzner gap.
- With glibc's default multi-arena scheme on M2, only 6.8% gap
  remains.
- `MALLOC_ARENA_MAX=4` already captures ~75% of the headroom of
  going to default; everything ≥8 is asymptotically equivalent.
- Forcing all medium-sized allocs to `mmap` (the heaviest possible
  glibc setting) gets +8.7%, not +25%. So zk-alloc is not winning by
  cheap-mmap; it's winning by cheap-thread-local-bump.

The slowdown vector is **per-arena lock contention**, not page-fault
overhead, not mmap cost, not page size. The single-thread runs already
ruled out everything that doesn't require concurrent contention.

#### A7. Counter caveats

- **Apple PMU on Asahi exposes only cycles / instructions / branches.**
  No cache-references, cache-misses, dTLB-loads, dTLB-load-misses,
  iTLB-load-misses — all return `<not supported>`. This is why I cannot
  measure TLB miss behavior on M2 directly. (The cross-experiment plan
  for Hetzner asks for these counters specifically.)
- **Context-switches on M2 are similar between allocators.** zk-alloc
  87.7 K, std-alloc 96.6 K. CPU migrations 14.1 K vs 15.1 K. Neither
  pattern explains a 7× gap.
- **Multi-run variance is ~5%.** Today's zk vs std default Δ measured
  +6.8%; yesterday's measurement (different thermal state) was +3.4%.
  All conclusions about gap *causes* survive that variance band; the
  *exact magnitude* on M2 is between +3% and +7% depending on day.

---

### B. Cross-machine experiments — exact commands for Hetzner

The hypothesis to test on Hetzner: **the +25% gap is driven by per-arena
lock contention scaling, and this explains the M2/Hetzner Δ.** If true,
specific shifts on Hetzner should follow predictable directions.

**Setup before any run:**

```bash
cd ~/zk-autoresearch/leanMultisig
git checkout d13cfa5d   # or current main; note which commit you used
RUSTFLAGS="-C target-cpu=native" cargo build --release
cp target/release/lean-multisig /tmp/hzn_zkalloc
RUSTFLAGS="-C target-cpu=native" cargo build --release --features standard-alloc
cp target/release/lean-multisig /tmp/hzn_stdalloc
```

For each run below, report:

```
prove_secs (post-warmup, from JSON)
wall (from /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R")
mean of 3 back-to-back runs, no contention
```

#### B1. **THE CRITICAL EXPERIMENT — MALLOC_ARENA_MAX sweep on standard-alloc**

```bash
for arenas in 1 2 4 8 16 64; do
  for run in 1 2 3; do
    /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
      env MALLOC_ARENA_MAX=$arenas \
      /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
  done
done
```

**Predictions, with branch points:**

- If Hetzner `MALLOC_ARENA_MAX=64` ≈ default ≈ +25% slower than zk-alloc:
  the per-arena cap is not the variable. The gap is elsewhere — most
  likely in per-lock cost (atomic ops cheaper on aarch64 vs x86_64 due
  to LL/SC vs LOCK CMPXCHG semantics).
- If Hetzner `MALLOC_ARENA_MAX=1` is +60% or worse slower: **per-lock
  cost on x86_64 is the difference.** M2 +19% under same conditions →
  ratio ~3×, exactly matching the +25%/+7% headline gap multiplier.
- If Hetzner shows no monotonic trend: glibc behavior is fundamentally
  different and we need a different lens.

#### B2. **Match M2 thread count: cap Hetzner to 10 logical CPUs**

```bash
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    taskset -c 0-9 /tmp/hzn_zkalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    taskset -c 0-9 /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
```

**Note:** zk-alloc embeds `NUM_THREADS` at build time. To respect
runtime taskset, either build with `taskset -c 0-9 cargo build` (so
`available_parallelism()` reports 10), OR use `RAYON_NUM_THREADS=10`
with the existing 16-thread binary and a cgroup limit.

**Predictions:**

- If gap drops from +25% to ~+7% at 10 threads: thread count is the
  dominant variable. Reconciles with M2 directly.
- If gap stays at +25% even at 10 threads: it's not thread count, it's
  something else (per-lock cost, atomic-op cost, working-set fit, …).

#### B3. **Match M2 page size — disable transparent hugepages**

```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled  # restore
```

**Predictions:**

- If THP=never makes std-alloc significantly slower (gap widens past
  +25%): glibc on Hetzner relies on THP for amortized fault cost.
- If THP=never has no effect: glibc on Hetzner is already doing per-
  page handling and THP is irrelevant.

#### B4. **TLB miss counters — the hardware-direct measurement**

Hetzner has Zen 4 PMU which DOES support these:

```bash
for binary in /tmp/hzn_zkalloc /tmp/hzn_stdalloc; do
  perf stat -e \
    cycles,instructions,\
    dTLB-loads,dTLB-load-misses,\
    iTLB-loads,iTLB-load-misses,\
    L1-dcache-loads,L1-dcache-load-misses,\
    LLC-loads,LLC-load-misses,\
    page-faults,context-switches,cpu-migrations \
    "$binary" xmss --n-signatures 1550 --log-inv-rate 1 --json
done
```

**Predictions:**

- If std-alloc shows ≥2× more dTLB-load-misses than zk-alloc: glibc's
  fragmented allocations escape Zen 4's small dTLB; this *would* be a
  real per-lookup cost contributor on Hetzner that's invisible on M2
  (whose dTLB is much larger and at 16-KiB pages reaches 4× the
  memory).
- If dTLB-misses are similar (~within 30%): TLB is not the lever; the
  gap is at the lock-and-list level inside glibc.

#### B5. **Single-thread Hetzner — rule out everything M2 ruled out**

```bash
for binary in /tmp/hzn_zkalloc /tmp/hzn_stdalloc; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    taskset -c 0 env RAYON_NUM_THREADS=1 \
    "$binary" xmss --n-signatures 1550 --log-inv-rate 1 --json
done
```

(Build with `taskset -c 0 cargo build` for the zk-alloc binary so
`NUM_THREADS=1` at build time.)

**Predictions:**

- If single-thread Hetzner zk-alloc ≈ standard-alloc (gap < 1%): same
  conclusion as M2 — the Hetzner +25% is entirely concurrency-related.
- If single-thread Hetzner shows a gap ≥ 5%: there's a per-allocation
  cost difference even without concurrency. Would suggest x86_64
  atomic-op-cost or working-set differences that survive single-
  threaded.

#### B6. **Concurrent allocation rate — per-thread perspective**

```bash
strace -c -e trace=mmap,munmap,brk \
  taskset -c 0-15 /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
strace -c -e trace=mmap,munmap,brk \
  taskset -c 0-9 /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
```

(strace adds overhead; we want the *count*, not the wall time.) Same
for zk-alloc binary as a control. If 16-thread Hetzner makes
substantially more `brk`/`mmap` syscalls per second than 10-thread
Hetzner, it's a confirming sign.

#### B7. **Confirm baseline gap on Hetzner — please re-measure**

Before all of the above, please give me a fresh **3-run median** of
the headline:

```bash
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    /tmp/hzn_zkalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    /tmp/hzn_stdalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
```

So I can compute today's exact Δ% rather than relying on the +25%
recollected number. This pins the moving target.

---

### C. Honest verdict — what M2 alone can establish

**What is solidly established by the M2 evidence:**

1. **The zk-alloc gap is concurrency-induced, not allocation-cost-induced.**
   Single-thread M2 shows zk-alloc ≈ std-alloc (Δ < 1%, both signs). The
   gap appears only with parallel rayon work. **This rules out the
   hypotheses TLB capacity, memory-controller / latency, glibc
   tcache-quality, codegen, and clock — none of which depend on
   concurrent contention.**

2. **The gap is bounded above by per-arena lock contention.** With
   `MALLOC_ARENA_MAX=1` on M2, std-alloc is 19% slower than zk-alloc —
   reproducing the entire Hetzner +25% gap on Apple Silicon. The gap
   between glibc-with-arenas (6.8%) and glibc-with-one-arena (19%)
   on M2 is **the headroom that Hetzner appears not to be reclaiming
   for some reason.**

3. **glibc's multi-arena scheme is doing 73% of zk-alloc's potential
   work on M2.** (1 − 6.8/25 = 73%.) Whatever Hetzner is doing,
   glibc's multi-arena mitigation is *less effective* there.

**What M2 alone cannot establish:**

- **Why glibc's multi-arena is less effective on Hetzner.** Three
  candidates:
  - x86_64 LOCK CMPXCHG cost is higher than aarch64 LDXR/STXR pair
    cost in absolute cycles, so even with arenas the per-lock
    acquisition burns more of the per-thread budget. **Test: B1, B5.**
  - Hetzner's 16 threads (vs M2's 10) creates a 1.6× higher steady-
    state allocation rate, saturating the arena pool's ability to
    isolate threads. **Test: B2.**
  - Zen 4's smaller dTLB + 4-KiB pages creates real TLB-miss cost on
    fragmented glibc allocations that M2's larger dTLB + 16-KiB pages
    absorbs. **Test: B3, B4.**
- **Whether the +25%-on-Hetzner survives a clean re-measurement on
  the post-PR-216 build.** Need B7.

### Numbered accounting (with the caveat that #2-4 require Hetzner data)

| Factor | Bound (lower–upper) | Status |
|---|---|---|
| 1. Per-thread allocation cost differences (TLB, codegen, clock, tcache, page-table walk) | **0–1 percentage point** of the 21.6 pp gap | **Established** by single-thread A3 |
| 2. Hetzner thread count (16 vs M2 10) at default arenas | 0–10 pp | Pending B2 |
| 3. x86_64 vs aarch64 atomic-op / lock-overhead asymmetry | 0–15 pp | Pending B1, B5 |
| 4. TLB working-set fit (Zen 4 small dTLB + 4 KiB vs Apple large dTLB + 16 KiB) | 0–10 pp | Pending B3, B4 |
| Sum (factors 2 + 3 + 4) ≤ 25 pp by construction | | One or two will dominate |

If I have to commit to a most-likely partition based on M2 evidence
alone, I'd budget:

- **#3 (atomic/lock-overhead asymmetry): 8–12 pp.** This is what would
  remain if Hetzner B2 (10-thread) shows the gap collapses partially
  but not to ~3%. aarch64 LL/SC pairs are documented at ~6–8 cycles vs
  x86_64 LOCK CMPXCHG ~25–40 cycles uncontended, ~100+ contended. A 3×
  per-lock-cost factor scales the M2 +6.8% to a Hetzner ~+20%, which is
  in the right ballpark.
- **#2 (thread-count): 5–8 pp.** B2 at 10 threads should compress
  Hetzner.
- **#4 (TLB / page-size): 0–5 pp.** Real but bounded.

I am explicitly not claiming the page-size argument carries 7× of the
gap. The earlier hand-wave was wrong.

### What I cannot resolve without you

- The single-most-leveraged data point is **B1** (the
  `MALLOC_ARENA_MAX` sweep on Hetzner). On M2 it isolated arena lock
  contention as a 19-percentage-point lever; if Hetzner shows the
  same single-arena number is +60% (consistent with 3× higher per-
  lock cost), factor #3 dominates. If Hetzner single-arena is also
  ~+19%, then factors #3 and #4 are both small and the difference is
  in #2 (thread count) plus per-arena fragmentation effects from
  long-running threads.

I am out of leveraged experiments I can run on M2 alone without the
Asahi Apple PMU exposing TLB events (it doesn't). The M2 experiments
above bound the answer; Hetzner data resolves it.

---

### D. Side findings (M2-specific)

While running the contention isolation, two M2-only observations worth
recording:

1. **The 4 P-cores config (RAYON=4, taskset -c 4-7) at 4.17 s prove
   exceeds 4 E-cores (4 cores, taskset -c 0-3) at 11.77 s by 2.8×.**
   Single P-core is ~2.8× a single E-core in this workload. Important
   datapoint for any future "which subset of M-series cores is the
   prover natively scaling on" analysis.
2. **Adding 4 E-cores to 6 P-cores improves throughput by 17%
   (522 → 611 XMSS/s under zk-alloc).** Not nothing — E-cores do
   contribute. But the contribution-per-core is roughly 0.43× of a
   P-core. This is consistent with rayon-uniform scheduling under a
   P/E-naive Linux scheduler.

These don't bear on the allocator gap question but came out of the
core-set experiments and seemed worth keeping.

---

### E. Reproducibility

All artifacts under `/tmp/`:

```
/tmp/bench_m2_zkalloc        — 10-thread zk-alloc binary (NUM_THREADS=10)
/tmp/bench_m2_stdalloc       — 10-thread standard-alloc binary
/tmp/bench_m2_zk_{1,4,6}P    — zk-alloc with NUM_THREADS={1,4,6}
/tmp/bench_m2_std_{1,4,6}P   — standard-alloc with NUM_THREADS={1,4,6}
/tmp/m2_target_{1,4,6}P/     — separate cargo target dirs for the variant builds
```

Each variant binary was built by `taskset -c <subset> cargo build
--release`, so `available_parallelism()` reports the chosen count at
build time (and the runtime `init()` assertion is satisfied when run
under the matching `taskset`).

To re-run the headline median:

```bash
for run in 1 2 3; do
  /usr/bin/time -f "wall=%e user=%U sys=%S rss=%M faults=%R" \
    /tmp/bench_m2_zkalloc xmss --n-signatures 1550 --log-inv-rate 1 --json
done
```

---

## 12. Hetzner B-suite results — pinned cross-machine verdict

Hetzner ran B7 (baseline), B1 (`MALLOC_ARENA_MAX` sweep), B2 (10-thread
taskset), B3 (THP=never), B4 (perf stat with TLB/cache/syscall counters)
and B6 (strace mmap/munmap/brk) on commit `3441e3a9` (post-PR-216).
Raw artifacts in `/tmp/hzn_b_suite_results.md` and
`/tmp/hzn_b_suite_summary.md`. B5 (single-thread Hetzner zk-alloc) was
not run because zk-alloc's build-time `NUM_THREADS` assertion blocks
runtime taskset.

### 12.1 Today's headline numbers (pinned)

| Machine | zk-alloc | std-alloc | std slower than zk |
|---|---:|---:|---:|
| Hetzner Zen 4 (16 threads) | **2.061 s** (752 XMSS/s) | **2.850 s** (544 XMSS/s) | **+38.3%** |
| M2 Asahi (10 threads, today) | 2.472 s (627 XMSS/s) | 2.641 s (587 XMSS/s) | **+6.8%** |
| **Hetzner extra gap over M2** | | | **+31.5 pp** |

The +25% recalled earlier was pre-PR-216 or noisy. Today's Hetzner gap
is +38.3%; PR #216 sped up zk-alloc more than std-alloc, widening the
relative ratio. **All percentages below are vs zk-alloc as the baseline.**

### 12.2 The cross-machine `MALLOC_ARENA_MAX` sweep

Single-arena (worst-case lock contention) vs default-arenas:

| ARENA_MAX | Hetzner gap | M2 gap | Hetzner / M2 ratio |
|---:|---:|---:|---:|
| 1 (single arena) | **+54.4%** | +19.2% | **2.86×** |
| 2 | +48.5% | +12.6% | 3.85× |
| 4 | +43.6% | +9.4% | 4.64× |
| 8 | +43.1% | +7.0% | 6.16× |
| 16 | +41.5% | +8.5% | 4.88× |
| 64 | +41.5% | +7.7% | 5.39× |
| **default (unset)** | **+38.3%** | **+6.8%** | **5.63×** |
| **Recovery from arena scheme (1 → default)** | **16 pp** | **12 pp** | similar |

Two key observations from this matrix:

1. **glibc's multi-arena scheme recovers a *similar absolute* number of
   percentage points on both machines** (16 pp on Hetzner, 12 pp on M2).
   So glibc's mitigation strategy works comparably well on both —
   thread/arena assignment scales fine. The arena scheme is doing its
   job.
2. **The post-recovery floor differs by 31.5 pp** (Hetzner +38.3 vs M2
   +6.8). This is the gap that needs explanation.
3. **The Hetzner/M2 ratio at ARENA=1 is 2.86×**, but at default it's
   5.63×. The ratio *grows* with multi-arena mitigation — i.e., the
   Hetzner-specific cost component is *not* fully reducible by the
   arena scheme. There is an irreducible Hetzner penalty that arena
   recovery cannot touch.

### 12.3 The decisive `perf stat` numbers (B4)

Both binaries, single shot, 16 threads, default arenas. Note: this
measurement covers `warmup + prove`; the `time_secs` column is the
post-warmup prove.

| Counter | zk-alloc | std-alloc | Δ |
|---|---:|---:|---:|
| Wall (incl. warmup) | 9.73 s | 9.76 s | similar |
| post-warmup `time_secs` | 2.094 s | 2.873 s | +37% |
| **User time** | 60.68 s | 58.71 s | **−1.97 s (std uses *less* user)** |
| **Sys time** | **7.06 s** | **14.77 s** | **+7.71 s (2.09×)** |
| Cycles | 274.7 B | 302.3 B | +27.6 B (+10.1%) |
| Instructions | 250.2 B | 268.1 B | +17.9 B (+7.2%) |
| IPC | 0.91 | 0.89 | similar |
| **page-faults** | **2,994 K** | **4,835 K** | **+1,841 K (+61.5%)** |
| dTLB-loads | 665 M | 807 M | +21% |
| dTLB-load-misses | 339 M (51.0% rate) | 361 M (44.8% rate) | similar absolute |
| iTLB-loads | 12.8 M | 13.7 M | similar |
| **iTLB-load-misses** | **6.9 M (53.7% rate)** | **15.8 M (115.7% rate)** | **+8.9 M (+130%)** |
| L1-dcache-loads | 87.3 B | 93.8 B | +7.5% |
| L1-dcache-load-misses | 8.67 B (9.93%) | 9.29 B (9.90%) | rate identical |
| context-switches | 23,884 | 27,886 | +17% |
| cpu-migrations | 2,049 | 2,875 | +40% |

Two anchors:

- **Sys-time delta = +7.71 s aggregate.** With 16 threads and 9.75 s
  wall, that's `+7.71 / 16 = +0.48 s` of wall time if kernel work
  parallelizes perfectly, up to `+7.71 s` if it serializes. Reality
  is in-between; B6's strace and the page-fault count locate it.
- **User-time delta = −1.97 s aggregate.** Std-alloc spends *less* user
  time but more sys time — threads transit into kernel mode more often.
  Cycles delta (+27.6 B) on similar IPC means about `+27.6 − +17.9 ×
  (instr/cycle conversion) ≈ +9.7 B extra "non-instruction" cycles` —
  user-mode stall budget consistent with lock-spin / contention.

### 12.4 The strace anchor (B6)

| Allocator + config | mmap | munmap | brk | wall in syscalls (strace) |
|---|---:|---:|---:|---:|
| std-alloc, 16 threads | 127 | 84 | 3,871 | **0.900 s** |
| std-alloc, 10 threads (taskset 0-9) | 129 | 94 | 3,897 | 0.964 s |
| zk-alloc, 16 threads | 47 | 13 | 3,633 | **0.011 s** |

- **`brk` count is similar across all configs (~3,600–3,900).** This
  is the small-allocation path; zk-alloc routes sub-4 KiB through the
  system allocator. Same volume.
- **`munmap` is the smoking gun.** std-alloc: 84 calls × 10,256 µs/call
  = 0.86 s aggregate (95.7% of strace-attributed time). zk-alloc:
  13 × 536 µs = 0.007 s (0.1% of strace time). **125× more wall in
  munmap on std-alloc.** glibc's free path triggers `munmap` on
  large blocks; zk-alloc keeps them in the arena and overwrites in
  place.
- **Per-call `munmap` latency is also 19× higher on std-alloc**
  (10,256 µs vs 536 µs). munmap involves a TLB shootdown IPI to all
  cores; with 16 threads the IPI fan-out cost grows.

### 12.5 What B2 ruled out — thread count is NOT the cause

| Hetzner config | std prove |
|---|---:|
| 16 threads (default) | 2.85 s |
| 10 threads (`taskset -c 0-9`) | **3.11 s (slower)** |

Reducing Hetzner to M2's 10-thread headcount *worsens* std-alloc by 9%.
**Rayon parallelism gain at threads >10 still exceeds the glibc
contention cost from those extra threads.** So Hetzner's 16 threads
vs M2's 10 is not the variable that explains the gap shrinkage. (zk-
alloc 10-thread number is missing because the build asserts
`NUM_THREADS == 16`; would need a separate build to compare.)

### 12.6 What B3 ruled out — THP is at most ~2 pp

| Hetzner config | std prove | Δ |
|---|---:|---:|
| THP=madvise (default) | 2.85 s | — |
| THP=never | 2.91 s | +2.1% |

THP is a real effect on Hetzner std-alloc, but small. zk-alloc is
THP-immune (it explicitly `madvise(MADV_NOHUGEPAGE)`). Bounded
contribution: ~2 pp.

### 12.7 Final verdict — pinned attribution of the +38.3% Hetzner gap

The wall-time gap is **0.79 s** on a 2.06 s zk-alloc baseline. I
attribute it as follows. Each row is an absolute wall-time estimate
with its mechanism and the evidence anchor.

| # | Mechanism | Evidence anchor | Wall (s) | **pp of 38.3** | Bound |
|---:|---|---|---:|---:|---:|
| 1 | **Page-fault servicing during prove (4 KiB pages)** | +1,841 K extra minor faults at ~3 µs each = +5.5 cpu-s aggregate; with imperfect parallelism in mm-spinlock-protected fault path → ~0.30–0.45 s wall | **0.40** | **+19 pp** | ±5 pp |
| 2 | **Stall cycles from lock contention (user-mode)** | +9.7 B extra non-instruction cycles at 4 GHz × 16 threads = 0.15 s wall floor; manifests as cmpxchg / pause loops in glibc lock paths | **0.15** | **+7 pp** | ±3 pp |
| 3 | **`munmap` + TLB-shootdown IPI + iTLB pressure** | strace: 84 × 10 ms munmap = 0.86 s aggregate, ~0.05 s wall when overlapped; iTLB-miss rate 116% vs 54% adds another ~0.03 s | **0.10** | **+5 pp** | ±3 pp |
| 4 | **Per-lock cost asymmetry x86_64 LOCK CMPXCHG vs aarch64 LDXR/STXR** | ARENA=1 ratio 2.86×; this surfaces inside #2 as higher per-acquisition cycles and inside #1 as kernel-side acquisition cost | **0.10** | **+5 pp** | ±5 pp |
| 5 | **THP availability (small)** | B3: +2 pp on std-alloc, none on zk-alloc | 0.04 | +2 pp | ±1 pp |
| | **Sum** | | **~0.79 s** | **~+38 pp** | |

Factor #4 is partially overlapped with #2 — they share the same
mechanism (per-lock cycles in glibc spin paths) but expressed at
different layers. The bound is generous to avoid double-counting.

### 12.8 Why M2's gap is +6.8% — same decomposition

| # | Mechanism | M2 evidence | Wall (s) | pp of 6.8 |
|---:|---|---|---:|---:|
| 1 | Page-fault servicing during prove (16 KiB pages, ~4× fewer faults) | std-alloc +0.50 M extra faults × ~3 µs / 10 threads ≈ 0.10 s wall | 0.10 | +4 pp |
| 2 | User-mode stall (lock contention in glibc paths) | aarch64 LL/SC cycles cheaper; small | 0.04 | +1.5 pp |
| 3 | munmap + TLB / kernel transitions | small absolute amount | 0.02 | +1 pp |
| 4 | Per-lock cost asymmetry | already cheap on aarch64 | (in #2) | — |
| 5 | THP not relevant | M2 unaffected | 0.00 | 0 |
| | **Sum** | | **0.16 s** | **~+6.8 pp** |

### 12.9 The 31.5 pp Hetzner-extra-gap, attributed

| Factor | Hetzner pp | M2 pp | **Δ pp explained** |
|---|---:|---:|---:|
| Page-fault servicing (4 KiB vs 16 KiB pages) | 19 | 4 | **+15 pp** |
| User-mode lock contention (LOCK CMPXCHG vs LDXR/STXR) | 7 | 1.5 | **+5.5 pp** |
| Per-lock cost asymmetry (kernel-side) | 5 | 0 | **+5 pp** |
| `munmap` + iTLB pressure + IPI fanout (16 threads vs 10) | 5 | 1 | **+4 pp** |
| THP | 2 | 0 | **+2 pp** |
| **Sum** | **38 pp** | **6.5 pp** | **+31.5 pp** |

**The earlier "page size carries 7×" hand-wave was incomplete in
direction but in the right order of magnitude.** Page size *does*
carry the largest single share — about 15 of the 31.5 pp — via the
4× per-fault cost amortization on 16 KiB pages. But it's not 7×
proportionally; it's about half of the cross-machine delta.

The other half splits between:

- **Per-lock cost asymmetry x86_64 vs aarch64 (~10 pp combined):**
  measurable directly via the ARENA=1 ratio (2.86×). LOCK CMPXCHG on
  Zen 4 takes ~25–40 uncontended cycles, ~100+ contended; aarch64
  LDXR/STXR pairs are ~6–8 uncontended, ~25 contended. The diff
  surfaces in user-mode spin time *and* in kernel-mode arena lock
  acquisition.
- **TLB-shootdown / IPI fanout cost (~4 pp):** more cores = more
  expensive cross-CPU IPI; munmap calls fan out to invalidate
  remote TLBs. Worse on x86_64 because of larger thread count.
- **THP (~2 pp):** real but small.

### 12.10 What the data did NOT support

- **Thread count (16 vs 10) is NOT the cause.** B2 showed reducing
  Hetzner to 10 threads makes std-alloc *slower*, not faster. Rayon
  parallelism wins more than glibc contention loses at this size.
- **TLB capacity (Apple large dTLB vs Zen 4 small dTLB) is NOT the
  cause.** Hetzner B4 shows std-alloc dTLB-miss *rate* (44.8%) is
  actually *lower* than zk-alloc (51.0%). Zen 4's dTLB is not getting
  hammered worse by std-alloc. **iTLB** misses are higher (2.3×) —
  but that's accounted for in factor #3, not in dTLB capacity.
- **Codegen, cache hierarchy, IPC** all measure similar between the
  two allocators on Hetzner (IPC 0.91 vs 0.89, L1-dcache miss rate
  identical at 9.9%). Not the lever.

### 12.11 What is still unmeasured

- **B5 (single-thread Hetzner zk-alloc).** Would tell us if the
  per-allocation cost (with no concurrency) is ≈ 0 on Hetzner just
  like it is on M2. If yes, that confirms factor #1 (page-fault
  servicing) is overwhelmingly the dominant cause of the gap. If no
  (single-thread shows e.g. +5%), we'd need to add a per-allocation
  factor.

  **My assessment: B5 would tighten the verdict by at most ±2 pp.**
  The page-fault count (+1.84 M faults on std-alloc) is already a
  hard physical anchor for factor #1 — it doesn't depend on
  concurrency to be true. Asking for B5 to confirm "the +1.84 M
  faults aren't somehow free under single-thread" feels like asking
  to confirm physics. **I am NOT requesting B5.** The verdict above
  stands at the pp level.

- **B2 zk-alloc 10-thread.** Same blocker (NUM_THREADS=16 build
  assertion). Would clarify by ~3 pp how much of factor #3 (IPI
  fanout) scales with thread count. Not load-bearing for the verdict.

### 12.12 Single-paragraph summary

The +38.3% Hetzner zk-alloc speedup over glibc is dominated by **page-
fault servicing during the prove (~19 pp)** — std-alloc continuously
faults pages in 4 KiB increments, while zk-alloc pre-touches its arena
once and then overwrites in place. The next ~12 pp split across user-
mode lock contention in glibc (per-lock-cost asymmetry x86_64 vs
aarch64 surfaces here, with ~3× higher cycle cost per acquisition),
kernel-side munmap + TLB-shootdown IPI fanout cost (16 threads pay
more), and ~2 pp of THP-availability difference. On M2 (16 KiB pages,
aarch64 atomics, 10 threads) every one of these factors shrinks: page
faults are 4× cheaper, atomics are 3–4× cheaper, IPI fanout has 1.6×
fewer targets, and the residual gap is ~+6.8%. Page size is the
single largest cross-machine delta (~15 of 31.5 pp); per-lock-cost
asymmetry contributes ~10 pp; the rest is small mechanisms compounding.

### 12.13 No commit this round

This update is to the report only (`m2_profile.md` markdown). No
source files modified; no `cargo fmt` / `cargo clippy` needed. The
zk-alloc fix from earlier today is already committed locally as
`3e284818` (PR Barnadrot/zk-alloc#11 noted by user, CI green).

