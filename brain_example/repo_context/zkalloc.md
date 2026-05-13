# Repo context — zk-alloc

Mutable facts about the zk-alloc target repo. Read by `brain-author-*` personas before authoring program.md. Updated whenever a new platform result lands or an API shifts.

## What it is

Bump-and-reset arena allocator crate purpose-built for ZK prover workloads. Replaces system malloc with a per-thread slab + phase-scoped reset model that matches the phased allocation pattern of provers (commit phase, fold phase, open phase — each ends in mass reset rather than fine-grained frees). Published to crates.io as `zk-alloc = "0.0.9"` (Apache-2.0, 2026-05-13).

## Location

```
~/zk-autoresearch/zk-alloc                # cloned per scripts/setup/zk_alloc.sh
```

Repo is gitignored at the brain checkout root — clone separately.

## Published version

**`0.0.9` on crates.io** (published 2026-05-13). API surface is stable from this version onward.

Public API:
- `ZkAllocator` — the allocator type, install as `#[global_allocator]`
- `init()` — per-thread slab init (called automatically on first alloc)
- `begin_phase(name: &str)` — start a new allocation phase
- `end_phase()` — reset the slab (bump pointer back to phase start)
- `phase<F, T>(name: &str, f: F) -> T where F: FnOnce() -> T` — scoped phase helper
- `assert_flat_phase()` — debug-assert that nested phases are not in use (PR #12, enforced)

## Platform results (per-platform measured, NOT extrapolated)

Canonical cross-platform table as of 2026-05-12:

| Platform | Hardware | Δ% vs glibc | Status |
|---|---|--:|---|
| Hetzner Zen 4 | Linux x86_64, AVX-512 | **−25%** (best win) | shipped |
| Apple M2 Pro macOS | macOS Sequoia 16 GiB | −9.24% | measured |
| Apple M4 Pro macOS | macOS Sequoia 16 GiB | ~−10% | measured |
| Apple M4 Pro macOS | macOS Sequoia 32 GiB | ~−10% | measured |
| Apple M2 Asahi | Asahi Linux, 16 KiB pages | −3.93% | measured (NOT stale) |
| Windows x86 | (user's desktop) | TBD | pending validation |

Asahi result is small because the workload is compute-bound + the 16 KiB pages + strong glibc baseline together close most of the gap. Linux x86_64 wins are bandwidth-bound; aarch64 wins are smaller. (See memory `project_zkalloc_cross_platform_table_2026-05-12.md`.)

## Platform-specific quirks (HARD FACTS)

- **Asahi Linux aarch64** needs `vm.overcommit_memory=1` OR the 687ec5cc commit fix or zk-alloc SIGABRTs on `MAP_NORESERVE`. (See PR #11.)
- **macOS Mach-VM** does lazy backing differently from Linux; `MAP_NORESERVE` is a no-op. macOS path uses libc fallback (slower setup but functional).
- **16 GiB M-series Macs** are RAM-constrained: the iter 8 win (14 GiB pre-touched arena) OOMs on Justin's M2 16 GiB target. `PRETOUCH_BYTES` must be `MemTotal`-adaptive before shipping that variant.
- **Linux x86_64** standard glibc baseline; THP huge pages available via `madvise(MADV_HUGEPAGE)` (Task #72, not yet integrated).

## Configuration tunables

Per-thread slab size: `ZK_ALLOC_SLAB_GB` (default 8 GiB virtual reservation, only touched pages committed via lazy page-backing).

For 10-thread provers on 16 GiB Macs: `10 × 8 GiB = 80 GiB virtual`. Fits in M-series VA space; physical commit is workload-dependent.

## Integrations

| Downstream | Status | Notes |
|---|---|---|
| **leanMultisig** | Vendored as workspace member (`p3-zk-alloc` internal name) | Sync to upstream `zk-alloc = "0.0.9"` pending (Task #78). Carries PR #11 aarch64 fix. |
| **Plonky3** | Vendored on `feat/zk-alloc` branch; crates.io switch in flight on `m4m-macos` | When switch completes: PR upstream to Plonky3/Plonky3. |
| **Jolt** | Cross-prover bench (zkalloc vs glibc) — completed | See `experiment_logs/zk-alloc/multi-prover-bench/`. |
| **SP1** | Future target | No experiment yet. |
| **Miden VM** | Validation candidate (uses glibc, 11 GiB peak for 2^20 cycles) | Bounded benchmark planned. |

## Gate methodology (zk-alloc internal)

```bash
# Build with cgroups for memory accounting
RUSTFLAGS="-C target-cpu=native" cargo build --release

# Cross-allocator paired bench (zk-alloc vs system malloc)
# Run via downstream prover's bench harness with feature flag toggle.

# Correctness via assert_no_nested_phases pattern (PR #12 enforces in dev builds)
cargo test --release
```

zk-alloc itself has unit tests; integration validation happens IN downstream provers (leanMultisig prove_loop, Plonky3 examples).

## Closed decisions / dead-ends

- **Iter 8 PRETOUCH OOM** (HARD FACT). 14 GiB pre-touched arena OOMs on 16 GiB Macs. NOT shippable as-is. Need `MemTotal`-adaptive sizing before shipping.
- **Nested phase model** (HARD FACT). The allocator is flat-phase by contract. Nested `begin_phase` calls inside a phase are a contract violation. PR #12 added `assert_flat_phase()` to enforce this in dev builds. Emile's pattern, validated cross-prover.
- **No competing ZK allocator exists** (research finding, 2026-05). Paper opportunity post-devnet.

## Active investigations

- **Plonky3 zk-alloc integration validation** — Linux x86 (Task #57), Linux aarch64 Asahi (#58), macOS aarch64 (#59), Windows (#60). m4m-macos in flight as of 2026-05-13.
- **MADV_HUGEPAGE on slab regions** — Hetzner Tier-2 candidate (#72), predicted ~3% via dTLB-walk reduction.

## Branch protocol

zk-alloc lives in its OWN repo (`Barnadrot/zk-alloc`). Experiment branches there for allocator-internal work. Downstream integrations (Plonky3, leanMultisig) work on THEIR repo branches; they bump the `zk-alloc` crate dep version when needed.

## Files an author should reference but NOT re-author

- `src/lib.rs` — public API surface.
- `tests/` — phase + reset correctness tests.
- `Cargo.toml` — version pin point.

When the API shifts, bump crates.io version + update this bundle.
