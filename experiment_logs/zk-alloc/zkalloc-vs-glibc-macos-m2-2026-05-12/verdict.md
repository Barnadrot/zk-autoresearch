# Verdict — zk-alloc vs Apple libsystem on macOS M2 Pro

**Date:** 2026-05-12
**Hardware:** Scaleway M2-L (Apple M2 Pro, 6P+4E, 16 GiB), macOS Sequoia 15.6.1, Darwin 24.6.0 arm64
**Source:** leanMultisig `origin/main` @ `d080f3e2` ("fix logup-GKR when packing_width = 1")
**Build flags:** `RUSTFLAGS="-C target-cpu=native"`, `lto = "fat"`, `codegen-units = 1`
**Workload:** `prove_loop 5` (1550 sigs × 5 proofs per binary, wall-clock via `/usr/bin/time -p`)
**Memory hygiene:** `sudo purge` once at start; paired alternating order absorbs warm-cache drift

---

## 1. Headline

**zk-alloc beats macOS libsystem by −9.24% ± 0.73 pp** (range −10.22% … −8.21%, N=5 paired rounds).

| Metric | sysmalloc | zk-alloc |
|--------|----------:|---------:|
| Mean wall-clock | 18.130 s | 16.454 s |
| Absolute Δ | — | **−1.676 s** |
| Relative Δ | — | **−9.24%** |

Sample stddev across rounds: **0.73 pp**. Median Δ: **−9.15%**. Every single round was a zk-alloc win; the worst round was −8.21%.

## 2. Per-round table

| Round | Order            | sysmalloc (s) | zk-alloc (s) | Δ%      |
|------:|------------------|--------------:|-------------:|--------:|
| 1     | sysmalloc first  | 18.20         | 16.34        | −10.22% |
| 2     | zk-alloc first   | 18.19         | 16.45        |  −9.57% |
| 3     | sysmalloc first  | 18.14         | 16.48        |  −9.15% |
| 4     | zk-alloc first   | 18.10         | 16.46        |  −9.06% |
| 5     | sysmalloc first  | 18.02         | 16.54        |  −8.21% |

Order bias check: averaging by execution slot (A vs B), the two slots differ by < 0.3 s — alternation neutralized it, so the −9.24% mean is not a positional artifact.

## 3. Cross-machine comparison (CORRECTED 2026-05-12)

**Reference numbers in the program.md cited "~−3% to −5%" for Hetzner — that was wrong.** Canonical data from memory `project_leanmultisig_uses_zkalloc.md`:

| Workload / Platform | OS / libc | zk-alloc Δ |
|---|---|--:|
| leanMultisig / **Hetzner Zen 4 AVX-512** | Linux / glibc | **+25%** |
| leanMultisig / MacBook M4 | macOS / libsystem | +10% |
| **leanMultisig / M2-L (THIS RUN)** | **macOS Sequoia / libsystem** | **+9.24% ± 0.73 pp** |
| leanMultisig / M2 Asahi | Linux / glibc | +3.4% |
| leanMultisig / M-series macOS 16 GiB (historical, Thomas/Emile) | macOS | **negative** |

## 4. Verdict on the M1 bug story (CORRECTED)

The narrative I drafted in §4 originally was wrong. Corrected:

- macOS M2 Pro Sequoia is **NOT** the strongest zk-alloc target. Hetzner Zen 4 (Linux glibc) is, by ~2.7×.
- The **+9.24%** measured here is **consistent with the MacBook M4 macOS reference (+10%)** — confirms cross-OS portability at the macOS-typical magnitude.
- The **historical "negative on M-series macOS 16 GiB"** (Thomas/Emile) **does not reproduce** on this Scaleway M2-L Sequoia 15.6.1 setup. That IS a meaningful closure of the M1 bug story, but a smaller claim than "macOS is strongest."
- Why is Asahi +3.4% the smallest Linux number? Open question. Candidate explanations: 16 KiB vs 4 KiB pages, M2 vs Zen 4 microarchitecture, Apple-Silicon-on-Linux memory-subsystem differences. Worth a focused investigation if zk-alloc's M2-Linux story matters.

## 5. Implication for the paper claim (CORRECTED)

The cross-OS portability story holds at the **expected** magnitude, not better than expected:

> zk-alloc delivers wall-clock improvements on every platform tested. Hetzner Zen 4 + Linux + glibc is the strongest win at +25%. macOS (MacBook M4 +10%, Scaleway M2 Pro +9.24%) consistently shows a smaller but real +9-10% win — confirming portability without claiming macOS dominance. M2 Asahi Linux's +3.4% is the smallest Linux number and warrants its own investigation.

Operational consequences:
- **Justin's deployment story:** macOS works fine — +9-10% is real and consistent, not a hedge case. NOT a "best target" but a confirmed-working target.
- **Task #59 (zk-alloc Plonky3 macOS validation):** expect ~+10% on macOS, similar to or slightly smaller than Linux glibc, and verify the Plonky3 workload shape behaves similarly to leanMultisig.
- **No need to gate the `zkalloc_global` feature behind a `cfg(target_os = "linux")` guard.** Same default everywhere — but the Linux/Hetzner Zen 4 path remains the headline.

---

## Appendix — raw log

See `phase_1_paired.log` in this directory. Binary md5s:
- `prove_loop_zkalloc` — `b82040d1a1aed24b53679faa09a063ff`
- `prove_loop_sysmalloc` — `bc14a01da933d1e26a19bab7b1a0c464`

Allocator banners observed at launch:
- zk-alloc: `prove_loop: zkalloc_global — #[global_allocator] mode`
- sysmalloc: `prove_loop: no zk_alloc FFI — running without phase boundaries`
