# Verdict — zk-alloc vs glibc on Asahi M2, paired N=5

**Date:** 2026-05-12
**Hardware:** Apple M2 (Mac mini, base — 8c 4P+4E), Asahi Linux 6.14.2-401.asahi.fc42.aarch64+16k, 16 GiB RAM, 16 KiB pages
**leanMultisig HEAD:** `d080f3e2` ("fix logup-GKR when packing_width = 1 (no SIMD available)")
**zk-alloc HEAD (bundled at `leanMultisig/crates/backend/zk-alloc/`):** `f5e2299b` ("fix rare zkalloc/rayon interraction bug"), on top of `7f4936a1` ("feat: add zk-alloc bump+reset arena allocator …", PR #205)
**Build:** `RUSTFLAGS="-C target-cpu=native"`, fat LTO, codegen-units=1, `--features zkalloc_global` (for zkalloc binary)
**md5sums:** `prove_loop_zkalloc` 8dbb67a6a01c08c157efdd416f2589f0 · `prove_loop_sysmalloc` 6eda7cdf3c66fa508381aa80a9351e42
**Workload:** `prove_loop 5` — 5 proofs of 1550 sigs at log_inv_rate=1, RSS peaks ~2.6 GiB under zkalloc, ~0.3 GiB under sysmalloc

## Headline

**zkalloc speedup on Asahi M2 = +3.93% ± 1.66% (paired N=5, all rounds).**
Range +1.13% to +5.25%. Excluding round 1 as cold-cache: +4.63% ± 0.64% (N=4, tight cluster).

The Asahi number **did not move** from the prior stale +3.4%. Within noise of the old measurement. PRs #9 (slab routing), #11 (size-routing fix), and #12 (assert-flat-phase) did not unlock a larger Asahi win — Asahi remains the smallest zk-alloc delta across all platforms.

## Per-round table

| Round | Order | sys (s) | zk (s) | Δ = (zk−sys)/sys |
|--:|:--|--:|--:|--:|
| 1 | sys → zk | 16.83 | 16.64 | −1.13% |
| 2 | zk → sys | 16.96 | 16.27 | −4.07% |
| 3 | sys → zk | 17.06 | 16.19 | −5.10% |
| 4 | zk → sys | 16.88 | 16.19 | −4.09% |
| 5 | sys → zk | 17.15 | 16.25 | −5.25% |

Round 1 is the only outlier. The remaining four rounds — split evenly across both orderings — agree to within ±0.6%. Order bias is not visible at this N.

## Workaround required to run zkalloc at all on Asahi

**This run required `sudo sysctl vm.overcommit_memory=1`** for the duration of the measurement (restored to 0 after). Without it, the zkalloc binary aborts (SIGABRT, exit 134) inside `zk_alloc::arena_alloc_cold` → `ensure_region` → `mmap_anonymous` → `std::process::abort`. Same failure documented at `experiment_logs/leanMultisig/benchmark_m2/zkalloc_failure.md` on 2026-05-10. The bundled zk-alloc inside leanMultisig HEAD (`f5e2299b`) does **not** have the suggested one-line fix.

Root cause (unchanged from the 2026-05-10 doc):
- zk-alloc's fast path uses raw `syscall(SYS_mmap)` with `MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE`, but only under `cfg(all(target_os = "linux", target_arch = "x86_64"))`.
- On aarch64 Linux the fallback `libc::mmap` is used without `MAP_NORESERVE` (the comment treats the fallback as a macOS concession).
- Default arena layout on this machine: `DEFAULT_SLAB_GB=8 × (cpus=10 + SLACK=4) = 112 GiB`. With `vm.overcommit_memory=0` (Asahi default) and `CommitLimit≈16 GiB`, the kernel rejects the reservation; `mmap` returns `MAP_FAILED`; `ensure_region` aborts.

The workaround opens the reservation gate without changing zk-alloc source. RSS at steady state stays near 2.6 GiB (under both `Committed_AS` and physical capacity), so the SIGBUS-on-touch failure mode that `MAP_NORESERVE` would otherwise risk is not in play here. **The Hetzner measurement (+25%) is implicitly equivalent to overcommit=1, because its x86_64 raw-syscall path passes `MAP_NORESERVE` directly** — i.e., this paired comparison is now fair across platforms, but only after manual sysctl intervention. The aarch64 Linux user has to know to flip the sysctl; that itself is a deployment story.

## Cross-platform table

| Workload / Platform | OS / libc | zk-alloc Δ |
|---|---|--:|
| leanMultisig / Hetzner Zen 4 + AVX-512 | Linux / glibc | **+25%** |
| leanMultisig / MacBook M4 | macOS | +10% |
| leanMultisig / M2-L Scaleway (2026-05-12) | macOS Sequoia | +9.24% |
| **leanMultisig / M2 Asahi (this run, overcommit=1)** | **Linux / glibc** | **+3.93% ± 1.66%** |
| leanMultisig / M2 Asahi (prior, stale) | Linux / glibc | (+3.4%) |

## Why is Asahi the smallest Linux number despite the same M2 silicon?

Three plausible contributors, listed in decreasing confidence:

1. **The workload is compute-bound on M2, not allocator-bound.** Phase 5 of the M2 profile already measured IPC 3.86 on P-cores with branch-miss 0.33%; the prover is not waiting on memory or page faults. On Hetzner with AVX-512, compute is much faster relative to memory bandwidth, so allocator wins land proportionally harder. The +25% Hetzner number reflects a workload that *was* allocator-bound; M2 isn't, so even a perfect arena allocator can only buy back the small slice that is alloc/free.
2. **16 KiB native pages amortize glibc's per-page costs better than 4 KiB does.** Asahi's 16 KiB page size means glibc's `mmap`/`brk` and per-page faulting/zeroing happen at 1/4 the rate of a 4 KiB-page Linux box for the same allocation traffic. Zk-alloc's win partly comes from skipping those per-page costs — which are already 4× cheaper here. Hetzner's +25% gap is partly a 4-KiB-page artifact.
3. **glibc on Linux is genuinely closer to optimal than macOS `libsystem_malloc` for this allocation pattern.** Asahi (+3.93%) sits *below* macOS M2/M4 (+9–10%) on the same silicon. The delta between Asahi and macOS-on-M2 (~+5–6 pp) is the gap between Linux glibc and macOS's allocator on this workload, not anything about the M2 itself. That is a useful data point in its own right: glibc's per-thread arenas + thread cache are competitive with a bump arena when the workload is compute-bound and pages are big.

These compound: Asahi gets both (a) the smallest absolute allocator-time slice in the workload (compute-bound, big pages) *and* (b) the best baseline allocator to beat (glibc, not libsystem_malloc). Both effects pull the same direction. The +3.93% number is genuine, not stale — Asahi is the smallest zk-alloc-win platform we measure on, by structural reasons that won't be unlocked by future zk-alloc PRs without rethinking what zk-alloc optimizes on this profile.

## Hygiene + caveats

- Memory hygiene before run: `sudo sync && sudo swapoff -a && sudo swapon -a && echo 3 | sudo tee /proc/sys/vm/drop_caches`.
- `vm.overcommit_memory` was flipped 0 → 1 before the loop and restored 1 → 0 after. Both binaries were measured under overcommit=1 so the comparison is paired and fair.
- A pre-existing local modification to `leanMultisig/crates/backend/koala-bear/src/quintic_extension/mod.rs` is `#[cfg(test)]`-gated and does not affect the release binary; the bench crate's `prove_loop` build is bit-for-bit a clean origin/main build.
- N=5 paired, ITERS=5 per call, alternating order. Suggested but not required: bump ROUNDS for tighter confidence intervals — Round 1's cold-cache outlier widens the stddev considerably.
- All numbers are wall-clock from `/usr/bin/time -p` (`real`). No isolation to P-cores (`taskset` not used) — rayon decides P/E split as it wishes. Both binaries see the same scheduler so this does not bias the paired delta.

## Raw data

`phase_1_paired.log` (in this directory) contains the round-by-round output.

---
*Re-measure executed 2026-05-12. Asahi remains the outlier; the outlier is real.*
