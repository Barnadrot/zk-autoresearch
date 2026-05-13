# Phase 0 — Memory hygiene + smoke test

**Host:** Scaleway M2-L (Apple M2 Pro, 10-core, 16 GiB) — macOS Sequoia 15.6.1 (24G90), Darwin 24.6.0 arm64
**Date:** 2026-05-12

## Build

Both binaries built with `RUSTFLAGS="-C target-cpu=native"` + `--features zkalloc_global`.
No 687ec5cc cherry-pick was applied — verified not needed on macOS (no mach-vm crash).

| Binary | Branch | HEAD | Build time | Size | MD5 |
|---|---|---|---|---|---|
| `/tmp/prove_loop_main`  | `origin/main`                   | `d080f3e2` | 57.75 s | 4,798,272 B | `b82040d1a1aed24b53679faa09a063ff` |
| `/tmp/prove_loop_pr216` | `myfork/perf/poseidon-fft-mmo`  | `3441e3a9` | 48.99 s | 4,833,488 B | `b767bcf4c5c418291c732c5acba70030` |

Distinct MD5s confirm we are measuring two real configurations.

Two unused-variable warnings on `prove_loop.rs:53-54` (`phase_boundary`, `deactivate`) — pre-existing, harmless.

## Smoke test (N=1, after `sudo purge`)

| Binary | real (s) | user (s) | sys (s) |
|---|---|---|---|
| main (run 1)  | 14.13 | 96.51 | 3.03 |
| pr216 (run 2) |  6.41 | 24.12 | 2.98 |

**Important caveat:** the N=1 numbers are not comparable across the two binaries:
- The leanMultisig prove_loop precomputes & caches benchmark signatures on first run; the main-binary run paid that cost (~7-8 s of progress-bar work visible in stdout), the pr216 run inherited the cached signatures.
- These N=1 numbers exist only to verify *no crash*. The paired Δ measurement is Phase 1.

Both binaries:
- emitted `prove_loop: zkalloc_global — #[global_allocator] mode` → zk-alloc is the active allocator.
- completed cleanly. No `mach_vm_allocate` errors, no panics, no aborts.
- printed `1 proofs, 1550 sigs, log_inv_rate=1`.

## Phase 0 finding for #41 / #59

**zk-alloc works under macOS mach-vm semantics without the 687ec5cc MAP_NORESERVE cherry-pick.** No 120 GB virtual mmap crash, no 12x M1 historical regression observed at N=1. The 12x M1 figure (memory: project_zk_alloc_macos_bug) does not reproduce on M2 Pro Sequoia at this scale. Phase 1's N=5 paired delta will tell us whether the *amplitude* of zk-alloc's contribution differs from Asahi.

## Stop gate

No crashes ⇒ proceed to Phase 1.
