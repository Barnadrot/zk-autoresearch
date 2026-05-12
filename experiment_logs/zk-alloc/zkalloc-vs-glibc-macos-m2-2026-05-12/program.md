# zk-alloc vs system malloc — paired N=5 on macOS M2 Pro

## Role

You are a performance investigator running a tight single-phase comparison on **macOS Sequoia 15.6.1 on Apple M2 Pro** (Scaleway M2-L). One question: **does zk-alloc still deliver wins on macOS, like it does on Linux, or has the M1-era macOS bug story left a remnant?**

Read-only. No code changes. Single deliverable: a delta number + a one-paragraph verdict.

## Hardware

Same M2-L box as `profiling_macos_m2pro_pr216_2026-05-12`: Apple M2 Pro (6 P-core + 4 E-core, Mac14,12), 16 GiB RAM, macOS Sequoia 15.6.1, Darwin 24.6.0 arm64.

## Context

- Reference: Asahi M2 (same chip family, Linux): glibc 2.7197 s → zkalloc 2.5581 s = **−5.94%** for zk-alloc.
- Hetzner Zen 4: zk-alloc wins similarly (~−3 to −5%).
- macOS: **unknown.** Apple libsystem uses a magazine-based zone allocator (very different from glibc); mach-vm has different page-fault semantics than Linux. zk-alloc could match Asahi, beat it, underperform, or even regress.
- Today's `profiling_macos_m2pro_pr216_2026-05-12` proved zk-alloc *works* on M2 macOS (no 12× regression, builds clean) — but did NOT compare to system malloc.
- This experiment fills the gap. The historical M1 12× regression story closes cleanly once we have a glibc/libsystem baseline.

## Phase 1 (only phase) — paired N=5

Build two binaries from `origin/main` of leanMultisig:

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout origin/main

cd ~/zk-autoresearch/harness/leanmultisig/bench

# zk-alloc binary
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_zkalloc
md5 /tmp/prove_loop_zkalloc

# system malloc binary (NO zkalloc_global feature → Apple libsystem)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop
cp target/release/prove_loop /tmp/prove_loop_sysmalloc
md5 /tmp/prove_loop_sysmalloc
```

Confirm at launch that each binary prints the expected allocator banner (zkalloc prints `zkalloc_global — #[global_allocator] mode`; sysmalloc has no banner / standard mode).

Memory hygiene + paired N=5 with alternating order:

```bash
sudo purge

ROUNDS=5
ITERS=5
for r in $(seq 1 $ROUNDS); do
    if [ $((r % 2)) -eq 1 ]; then ORDER="sysmalloc first"; A=/tmp/prove_loop_sysmalloc; B=/tmp/prove_loop_zkalloc
    else                          ORDER="zkalloc first"; A=/tmp/prove_loop_zkalloc; B=/tmp/prove_loop_sysmalloc
    fi
    echo "=== Round $r ($ORDER) ==="
    A_TIME=$(/usr/bin/time -p "$A" $ITERS 2>&1 | awk '/real/{print $2}')
    sleep 1
    B_TIME=$(/usr/bin/time -p "$B" $ITERS 2>&1 | awk '/real/{print $2}')
    echo "A: $A_TIME, B: $B_TIME"
done | tee phase_1_paired.log
```

Compute per-round delta as `(zkalloc_time − sysmalloc_time) / sysmalloc_time`. Negative = zk-alloc wins.

## Phase 2 — Verdict writeup

Single file: `verdict.md`. Include:

1. **Headline number** — mean Δ ± stddev, range
2. **Per-round table** — 5 rows
3. **Cross-machine comparison row** — drop this result alongside Asahi −5.94% and Hetzner reference
4. **Verdict on the M1 bug story** — three possible conclusions:
   - macOS Δ within ±2 pp of Asahi → zk-alloc is portable across OS, M1 bug definitively closed
   - macOS Δ noticeably worse than Asahi (3+ pp shallower or regression) → macOS libsystem is already strong; zk-alloc value is Linux-specific or has a lingering macOS interaction worth investigating
   - Any positive delta (zk-alloc HURTS) → genuine macOS regression remnant; reopen the M1 bug story
5. **Implication for paper claim** — does the cross-OS portability story hold?

## Stop criterion

`verdict.md` exists and contains a headline delta with at least 5 rounds of data.

## Hard constraints

- **Read-only.** No leanMultisig source changes.
- **N=5 paired with alternating order.** Order bias is real on this hardware.
- **`sudo purge` before the run.** Memory hygiene one time at start; not between rounds (paired alternating amortizes).
- **No PR push.** Brain handles whatever decision falls out of the verdict.
- **Tight scope.** This is the missing baseline number, not a full profiling pass. Don't add phases.

## Why this matters

The M1 12× regression cited in memory `project_zk_alloc_macos_bug` lacked closure on M2. Today's profiling experiment partially closed it (proved zk-alloc *works*), but the comparison-to-libsystem number is what definitively answers whether the macOS path is now production-clean. This number directly affects: (a) the zk-alloc paper's cross-OS claim, (b) Justin's deployment story, (c) task #59 zk-alloc Plonky3 macOS validation framing.

---
*Tight add-on to profiling_macos_m2pro_pr216_2026-05-12. Drafted 2026-05-12 after that experiment surfaced the gap.*
