# zk-alloc on Plonky3 — vendored→crates.io switch + paired bench (m4m-macos)

## Role
You are an integration engineer. Your job has three sequential tasks:
1. **Verify** the current vendored zk-alloc integration in Plonky3 builds and runs cleanly on this Mac.
2. **Switch** Plonky3's dependency from the vendored `zk-alloc/` workspace member to the freshly-published crates.io dep `zk-alloc = "0.0.9"`.
3. **Measure** the paired wall-clock delta of `prove_poseidon2_koala_bear_keccak` with vs without zk-alloc, N=5 paired runs, document.

This is a Shape A optimization-like flow (real source change on a working branch) producing Shape B measurement output (paired bench numbers). Both the source change and the bench data are part of the deliverable.

## Hardware
**m4m-macos** — Apple M4 Pro 10c (4 P + 6 E), 32 GiB RAM, macOS Sequoia 15.6.1, aarch64-darwin.

Notes specific to this box:
- macOS path in zk-alloc uses the libc fallback (no `MADV_NOHUGEPAGE`, no direct syscalls). Functional but slower setup than Linux.
- `MAP_NORESERVE` is a Linux concept; macOS uses Mach-VM lazy backing which behaves equivalently for our purposes.
- 32 GiB RAM is the headroom-ceiling test box vs the 16 GiB M-series machines. The default `ZK_ALLOC_SLAB_GB=8` × 10 threads = 80 GiB virtual reservation. Should be fine on 32 GiB physical (only touched pages are committed).
- Non-interactive SSH on macOS sources `~/.zprofile`, not `~/.zshrc`. The agent's interactive tmux shell loads cargo via `~/.zprofile`; you should already have `cargo`, `rustup`, `gh`, `claude` on PATH.

## Repos & setup

| Repo | Path | Branch | Role |
|---|---|---|---|
| Plonky3 | `~/zk-autoresearch/Plonky3` | `feat/zk-alloc` → branch off to `crates-io-switch-m4m-2026-05-13` | target (you commit here) |
| zk-alloc (gitignored mirror, not needed) | n/a | n/a | crates.io dep `zk-alloc = "0.0.9"` |

Setup:
```bash
cd ~/zk-autoresearch/Plonky3
git fetch origin
git checkout feat/zk-alloc
git pull --ff-only origin feat/zk-alloc
git checkout -b crates-io-switch-m4m-2026-05-13
git rev-parse --abbrev-ref HEAD     # MUST be crates-io-switch-m4m-2026-05-13
```

Confirm rust toolchain:
```bash
source ~/.zprofile 2>/dev/null
cargo --version  # should report 1.94+ on Apple Silicon
```

## Background

The zk-alloc crate was vendored into Plonky3's `feat/zk-alloc` branch as a workspace member (`zk-alloc/Cargo.toml`, internal name `p3-zk-alloc`). Today we published `zk-alloc v0.0.9` to crates.io (https://crates.io/crates/zk-alloc), Apache-2.0 licensed. The crates.io version has the same public API as the vendored copy (`ZkAllocator`, `begin_phase`, `end_phase`, `phase`, `init`, etc.).

The integration point is in `uni-stark/src/prover.rs` and the Poseidon air examples (`poseidon1-air/examples/prove_poseidon1_baby_bear_keccak.rs`, `poseidon2-air/examples/prove_poseidon2_baby_bear_keccak_zk.rs`, `poseidon2-air/examples/prove_poseidon2_koala_bear_keccak.rs`). Search for `p3_zk_alloc::` / `p3-zk-alloc` references with:

```bash
git grep -n 'p3_zk_alloc\|p3-zk-alloc' | head -30
```

## Task 1 — Verify vendored integration builds + runs

Before switching, confirm the current state works. Build + run `prove_poseidon2_koala_bear_keccak`:

```bash
cd ~/zk-autoresearch/Plonky3
RUSTFLAGS="-C target-cpu=native" cargo build --release --example prove_poseidon2_koala_bear_keccak --features p3-poseidon2-air/zk-alloc 2>&1 | tail -10
RUSTFLAGS="-C target-cpu=native" cargo run --release --example prove_poseidon2_koala_bear_keccak --features p3-poseidon2-air/zk-alloc 2>&1 | tail -20
```

Adjust the `--features` flag to whatever the `feat/zk-alloc` branch actually uses for the zk-alloc feature gate (grep `Cargo.toml`s for `zk-alloc` or `zkalloc` feature names).

**Stop and escalate** if:
- Build fails — record the error in `report/task1_verify.md` and stop. Do not proceed to Task 2.
- Run fails — same, document the failure mode (Mach-VM regression? OOM? assertion? signal?) and stop.

If both succeed, record proof wall time + RSS in `report/task1_verify.md`, proceed to Task 2.

## Task 2 — Switch vendored → crates.io upstream dep

Goal: replace the vendored `zk-alloc/` workspace member with a crates.io dependency on `zk-alloc = "0.0.9"`. Imports change from `p3_zk_alloc::*` → `zk_alloc::*` (no `p3_` prefix — the published crate is just `zk-alloc`).

Concrete steps:

1. **Workspace Cargo.toml.** Remove `zk-alloc` from the `[workspace] members = [...]` list (it's currently a workspace member, no longer needed).
2. **Per-crate Cargo.toml.** Each crate that depended on `p3-zk-alloc` (path dep) needs to swap to `zk-alloc = "0.0.9"`. Likely affected files (grep to be sure):
   - `uni-stark/Cargo.toml`
   - `poseidon1-air/Cargo.toml`
   - `poseidon2-air/Cargo.toml`
   - `poseidon-air/Cargo.toml`
3. **Imports in `.rs` files.** `use p3_zk_alloc::*` → `use zk_alloc::*`. Also `p3_zk_alloc::ZkAllocator` → `zk_alloc::ZkAllocator`, etc.
4. **Feature renames.** If any feature was named `p3-zk-alloc` (the crate's own feature, not the dependency), check what it's called now — likely you'll rename internal features from `p3-zk-alloc` → `zk-alloc` to match the new dep name.
5. **Delete the `zk-alloc/` workspace member directory.** Once nothing references it, remove `zk-alloc/` from the repo entirely.

Verify by:
```bash
cargo build --release --example prove_poseidon2_koala_bear_keccak --features <whatever the new feature gate is> 2>&1 | tail -10
cargo run --release --example prove_poseidon2_koala_bear_keccak --features <gate> 2>&1 | tail -20
```

Both should succeed and produce the same proof timing ± noise as Task 1.

Commit the switch as a single commit: `feat: switch p3-zk-alloc vendored → zk-alloc 0.0.9 crates.io dep`. Commit body should:
- Reference crates.io URL: https://crates.io/crates/zk-alloc
- List the workspace + per-crate file changes
- Note any API differences encountered (should be zero)

**If you find a bug in zk-alloc 0.0.9 during integration** (e.g., feature flag mismatch, missing API): per the brain protocol, diagnose + fix on a working branch under `~/zk-autoresearch/zk-alloc/`. Do NOT silently work around or comment out. Document in `report/task2_switch.md`.

## Task 3 — Paired bench: zk-alloc vs system allocator

Now measure the actual benefit on this hardware.

Run two configurations:
- **Baseline (system allocator):** build + run `prove_poseidon2_koala_bear_keccak` WITHOUT the zk-alloc feature gate
- **Candidate (zk-alloc):** build + run the same example WITH the zk-alloc feature gate

N=5 paired runs, alternating baseline/candidate rounds. For each run, record the warm proof wall-clock time. Use the existing leanMultisig methodology pattern (cold proof discarded, warm proofs measured) but applied to Plonky3's `prove_poseidon2_koala_bear_keccak` output.

`prove_poseidon2_koala_bear_keccak` typically runs ONE proof per invocation, so you'll invoke it N=5 times per configuration. To get a "cold + warm" pair per invocation you can either:
- (a) Modify the example to run 2 proofs (cold + warm) per invocation, measure only the warm
- (b) Use N=10 invocations per side, treat odd-indexed as warmup, even-indexed as measurement
- (c) Trust that the chip is warm after one invocation and use all N=5 invocations as warm samples
Pick (c) as the default — simplest, the prover is dominated by O(N) work that doesn't change much cold vs warm.

Output to `report/task3_paired_bench.csv` with columns: `round,configuration,seconds,rss_kb_peak`.

Compute the headline statistics (Python or awk):
- mean baseline, mean candidate
- delta_pct = (mean_cand - mean_base) / mean_base * 100
- Welch's t-test or just mean ± std dev with sample size noted
- p-value if you compute t (numerical integration over t-PDF, or just trust scipy if available)

Document in `report/task3_paired_bench.md`:
- Hardware fingerprint (sysctl machdep.cpu.brand_string, total RAM, macOS version)
- Per-round timings
- Headline delta + significance
- Comparison to prior numbers in `experiment_logs/zk-alloc/multi-prover-bench/plonky3.md`

Prior multi-prover-bench data for Plonky3 on different hardware (for comparison context): on Linux x86_64 we measured ~−12% to −17%; on M2 Pro macOS we measured ~−9.24% (see `project_zkalloc_macos_strongest_win` memory). This M4 Pro 32GiB measurement is the next data point.

## Output / artifacts

All output goes in `experiment_logs/zk-alloc/plonky3-crates-io-switch-m4m-2026-05-13/report/`:

- `report/task1_verify.md` — vendored build + run verification (or failure)
- `report/task2_switch.md` — what was changed in Plonky3, diff summary, any surprises
- `report/task3_paired_bench.csv` — raw per-round data
- `report/task3_paired_bench.md` — analysis, delta, comparison to prior platforms
- `report/synthesis.md` — top-level summary: did the switch work? what's the M4 Pro 32GiB number? do all three tasks pass?

The `report/` dir is gitignored per path policy. Coordinator rsyncs back to brain at stop.

## Hard constraints

- **Branch:** all Plonky3 commits on `crates-io-switch-m4m-2026-05-13`. NEVER commit to main.
- **No `git push`:** brain pushes after reviewing your verdict. The crates-io switch eventually becomes a PR to Plonky3 main; brain handles that PR after this experiment.
- **No `cargo publish`:** zk-alloc 0.0.9 is already on crates.io. Don't republish.
- **No experimental zk-alloc patches in this experiment.** If you find a bug, document it but DO NOT patch zk-alloc during the bench — the published 0.0.9 is what we're validating.
- **No proof correctness shortcuts.** Run the actual `prove_poseidon2_koala_bear_keccak` example end-to-end, not a microbench.
- **macOS-aware:** if a step requires `sudo` (e.g., `purge` for memory hygiene between runs), use the passwordless sudo configured on this box. Don't add interactive sudo prompts.
- **Memory hygiene between configurations:** run `sudo purge` between baseline and candidate runs in each round to flush page cache. Important on macOS where Mach-VM page-cache state affects proof timings.

## Stop criterion

Stop when `report/synthesis.md` is written with all three tasks' results. If Task 1 fails, stop after writing `report/task1_verify.md`. If Task 2 fails (build doesn't succeed after switching), stop after writing `report/task2_switch.md` with the failure mode + suspected cause.

Do NOT chase additional optimizations, perf tuning, or extra benchmarks beyond the prescribed three tasks.

## Never stop (within stop criterion)

Run autonomously until one of the stop conditions above hits. No "let me ask brain first" — diagnose + document + proceed. If you're genuinely blocked (e.g., crates.io network unreachable, sudo broken), document the block clearly in the appropriate report file and exit with that documented.
