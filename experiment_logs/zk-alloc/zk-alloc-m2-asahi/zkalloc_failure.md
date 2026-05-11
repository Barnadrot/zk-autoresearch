# zk-alloc smoke-test failure on Asahi M2 (aarch64 Linux, 16 KiB pages)

- **Date:** 2026-05-10
- **Repo:** leanMultisig @ `d13cfa5d` (origin/main, "poseidon AIR: use mds_fft_16 instead of mds_circ_16")
- **zk-alloc:** `617e91a` (origin/main; `Cargo.lock` resolves the local path dep at this commit)
- **Hardware:** Apple M2 / Asahi Fedora 42, aarch64, 16 KiB page size, 10 cores, 16 GiB RAM, 8 GiB swap
- **Kernel:** 6.14.2-401.asahi.fc42.aarch64+16k
- **Toolchain:** cargo 1.94.0 (85eff7c80 2026-01-15)
- **Build:** `RUSTFLAGS="-C target-cpu=native" cargo build --release` — succeeds; binary contains `zk_alloc::*` symbols
- **Failure:** SIGABRT (exit 134) on every invocation, immediately after `warming up...`

## Reproducer (any size, any rate)

```bash
cd ~/zk-autoresearch/leanMultisig
target/release/lean-multisig xmss --n-signatures 100 --log-inv-rate 1 --json
# → Aborted (core dumped); exit 134
```

stderr contents in their entirety:

```
warming up...
```

Nothing else printed before the abort. No Rust panic, no `aborted at` message.

## Stack trace (from `coredumpctl info`)

```
#0  __pthread_kill_implementation               libc.so.6
#1  raise                                        libc.so.6
#2  abort                                        libc.so.6
#3  std::sys::pal::unix::abort_internal          lean-multisig
#4  std::process::abort                          lean-multisig
#5  std::sync::once::Once::call_once::{closure}  lean-multisig
#6  std::sys::sync::once::futex::Once::call      lean-multisig
#7  zk_alloc::arena_alloc_cold                   lean-multisig
#8  core::slice::sort::stable::driftsort_main    lean-multisig
#9  rec_aggregation::type_1_aggregation::aggregate_type_1
#10 rec_aggregation::benchmark::build_aggregation
#11 rec_aggregation::benchmark::run_aggregation_benchmark
#12 lean_multisig::run_with_warmup
```

The Once-call_once-closure → abort path is unique to one call site in zk-alloc:
`ensure_region` aborts when `mmap_anonymous` returns null
(`zk-alloc/src/lib.rs:142-172`). Every other abort/panic in zk-alloc is reachable
only after `ensure_region` succeeds.

## Root cause: aarch64 Linux path is missing `MAP_NORESERVE`

`zk-alloc/src/syscall.rs` has two `mmap_anonymous` implementations:

1. **`#[cfg(all(target_os = "linux", target_arch = "x86_64"))]`** — raw `syscall`
   with `MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE` (`syscall.rs:14-87`).
2. **Otherwise (any non-x86_64 target, including aarch64 Linux)** — `libc::mmap`
   with `MAP_PRIVATE | MAP_ANON` only — **no `MAP_NORESERVE`**
   (`syscall.rs:95-119`).

The fallback's comment explains the omission as a macOS concession ("MAP_NORESERVE
is Linux-only. macOS lazily backs anonymous mappings with physical memory by
default…"), but the cfg gate also catches aarch64 *Linux*. On aarch64 Linux,
`MAP_NORESERVE` is supported and required for the over-large reservation pattern
zk-alloc uses, but the fallback never asks for it.

Default arena layout on this machine:

```
DEFAULT_SLAB_GB = 8
SLACK           = 4
cpus            = 10
region_size     = 8 GiB × (10 + 4) = 112 GiB
```

With `vm.overcommit_memory = 0` (Asahi default; verified live), the kernel applies
the heuristic check and rejects a 112-GiB request without `MAP_NORESERVE`. `mmap`
returns `MAP_FAILED` → `mmap_anonymous` returns null → `ensure_region` calls
`std::process::abort` (`lib.rs:165-167`).

I confirmed it is a size-and-overcommit problem rather than a 16 KiB-page or
address-space-bits issue:

- `getconf PAGESIZE` = 16384 (irrelevant to the syscall failure mode).
- `cat /proc/sys/vm/max_map_count` = 1048576 (plenty).
- `aarch64` user VA space is 48-bit on this kernel — 256 TiB, far above 112 GiB.
- `vm.overcommit_memory` = 0 (heuristic), `MemTotal` = 16 GiB, `Swap` = 8 GiB →
  `CommitLimit` ≈ 24 GiB. Any anonymous reservation > CommitLimit is denied.
- Setting `ZK_ALLOC_SLAB_GB=1` (so region_size = 14 GiB) **also aborts** —
  expected, because 14 GiB without NORESERVE plus the rest of the process
  footprint still exceeds CommitLimit.
- `sudo sysctl vm.overcommit_memory=1` would let the mmap through but requires
  password sudo here. I did not attempt the workaround per program.md ("Do NOT
  continue silently with standard-alloc or any workaround").

## Workload itself is healthy

`cargo build --release --features standard-alloc` plus the same xmss invocation
runs cleanly:

- 100 sigs / log_inv_rate=1 → wall ≈ 1.5 s including warmup, exit 0.
- 1550 sigs / log_inv_rate=1 → wall **8.72 s**, prove time **2.582 s**, RSS peak
  5.29 GiB, 1,192,852 minor / 0 major page faults. Exit 0.
- `cycles`, `poseidons`, `memory`, `dots` per-node identical to Hetzner's 1550-sig
  leaf (same VM trace, as expected — the bytecode is deterministic).

So the abort is unambiguously inside zk-alloc's region setup, not the prover.

## Suggested fix (for follow-up; not applied here)

Replace the binary `cfg(all(linux, x86_64))` gate in `syscall.rs` with one that
covers all Linux targets, or pass `MAP_NORESERVE` from the libc fallback when
`cfg(target_os = "linux")`. One-line patch:

```rust
// in the libc fallback path
let mut flags = libc::MAP_PRIVATE | libc::MAP_ANON;
#[cfg(target_os = "linux")] {
    flags |= libc::MAP_NORESERVE;
}
```

Or, cleaner, extend the raw-syscall path to aarch64 — the syscall numbers differ
(`mmap` is `__NR_mmap` = 222 on aarch64) and the register convention uses `x0..x5`
+ `x8` instead of `rdi..r9` + `rax`, but the calling shape is the same.

A correctness/perf trade-off either way: with `MAP_NORESERVE`, a single thread
touching its slab past CommitLimit will SIGBUS at the touch site instead of
failing predictably at mmap time. For this workload (~10.8 GiB pre-touch on
Hetzner; ~5.3 GiB observed under standard-alloc on M2) the per-machine sizing
should leave plenty of headroom on a 16 GiB box.

## Why we stop here

`program.md`, step 1b: *"If it OOMs, panics, hangs, or returns a non-zero exit
code, **stop and document the failure**."* This is exactly that condition. We
also follow the broader rule at the bottom of step 1: *"If anything in step 1
fails permanently (build, link, smoke test): write the report with a 'Step 1
FAILED' section explaining what happened, save the failure artifact under
benchmark_m2/, and stop. Do not proceed to step 2."*

The failure is permanent for this build of zk-alloc on this kernel/sysctl
configuration, with a clear one-line fix that belongs in zk-alloc rather than
this experiment.
