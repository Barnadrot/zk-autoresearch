# zk-alloc M2 Asahi — make leanMultisig faster on aarch64 + 16 KiB pages

## Role

You are a systems performance engineer optimizing a Rust arena allocator (`zk-alloc`)
on Apple Silicon Linux. You understand:

- **Virtual memory mechanics**: `mmap` (`MAP_PRIVATE`, `MAP_ANON`, `MAP_NORESERVE`), `madvise` advice (`MADV_NOHUGEPAGE`, `MADV_WILLNEED`, `MADV_FREE`, `MADV_DONTNEED`), Linux page-table behavior, transparent hugepages, page faults (minor/major), TLB hierarchy.
- **aarch64 specifics**: 16 KiB native page size (vs 4 KiB on x86), NEON 128-bit SIMD, weaker memory ordering than x86 (LDXR/STXR vs LOCK CMPXCHG), Apple M-series microarchitecture (P/E core asymmetry, wider OoO pipeline, larger DTLB than Zen 4).
- **Rust allocator integration**: `GlobalAlloc` trait, `#[global_allocator]`, the allocator-fastpath/slowpath split, `Layout` and alignment requirements, `unsafe` arena-management code.
- **Profiling on Linux/aarch64**: `perf record` / `perf report`, `perf stat` counter selection (PMU events available on Apple Silicon are limited compared to Zen 4 — no cache-references, but cycles/instructions/branches and Apple-specific perf events are available), `objdump` for codegen inspection, `strace`/`ltrace` for syscall counting.
- **The leanMultisig prover**: a Plonky3-style ZK XMSS aggregation prover. The workload allocates ~10 GiB of field-element data per proof, with begin_phase/end_phase boundaries marking the prove call. Compute-bound on Poseidon permutations.

You work **autonomously between checkpoints**. Tool execution and file edits are
permitted; ask only when something cannot be derived from the codebase, the
machine state, or the harness output. **Real measurement, never analytical
deferral.** If you think a hypothesis won't help, run it anyway and report the
number — the measurement is the signal, not your prior. **You are not finished
until 12 consecutive discards have been logged.**

You do **not** modify the prover, the leanMultisig framework, or the standalone
zk-alloc repo. Allocator changes go to the vendored copy at
`crates/backend/zk-alloc/`. See "Out of scope" for the full list.

## Mission

This is a fresh-context, autonomous program. Goal: **find what is recoverable in
zk-alloc itself on Apple Silicon Linux that we have not yet measured.** Today's
investigation pinned the cross-machine gap at the physics level (page size, atomic
asymmetry, IPI fanout). What is open is whether zk-alloc on M2 has tunable headroom —
and if so, how much. **Free-roaming on zk-alloc internals.** No allocator
comparisons, no prover changes; just zk-alloc.

## Hardware

Apple Silicon **M2** running **Asahi Linux** (Fedora 42, kernel 6.14, page size
**16 KiB**, aarch64). 6 P-cores + 4 E-cores. 16 GiB RAM. NEON 128-bit SIMD only.
Linux glibc.

## Repo state

| Repo | Path | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | **`zk-alloc-m2-asahi`** (branched from `leanEthereum/main` + cherry-pick of `a8cb6a12` + `684a526c` from PR #215) |
| zk-alloc (vendored) | `~/zk-autoresearch/leanMultisig/crates/backend/zk-alloc` | in-tree, this is the build dep |
| zk-alloc (standalone, reference only) | `~/zk-autoresearch/zk-alloc` | NOT consumed by build, do not touch |

The branch already has:

- `d13cfa5d` — FFT MDS in AIR (from leanEthereum main; was b11aac3a / pw3-13 in our PR #216)
- `a8cb6a12` — zk-alloc safe arena routing + sticky-System realloc (mirrors zk-alloc PR #9, on top of leanMultisig PR #215)
- `684a526c` — zk-alloc realloc memmove + nested-phase panic (mirrors zk-alloc PR #10, on top of leanMultisig PR #215)
- A commit applying the aarch64 cfg fix to `crates/backend/zk-alloc/src/syscall.rs` (mirrored from `Barnadrot/zk-alloc#11`). Without this commit, build SIGABRTs on first allocation under Asahi default `vm.overcommit_memory=0`.

**All zk-alloc changes go to `crates/backend/zk-alloc/` in this repo.** Do not touch
the standalone `~/zk-autoresearch/zk-alloc`.

## Today's measured baseline (this machine)

From `m2_profile.md` (xmss CLI, thin LTO from workspace defaults — informational):
- zk-alloc: 611 XMSS/s, 2.54 s; standard-alloc: 591 XMSS/s, 2.62 s; **gap +3.4%**
- IPC P-core 3.99, combined 3.12. Poseidon share ~53% of cycles.
- Page faults: zk-alloc 689 K, std-alloc 1,198 K (1.74× ratio).

**No explicit iter-0 measurement.** The starting commit (HEAD when you arrive) is the implicit baseline — record its SHA as `BASELINE_SHA` so you can run a final cumulative comparison at verdict time (`eval_paired.sh --baseline $BASELINE_SHA --candidate HEAD`). Per-iter, the gate measures HEAD vs HEAD~1 (immediately prior commit), so each iter's `delta_pct` is the local improvement, and the cumulative improvement is the product/sum of kept iters' deltas.

**Sanity check before iter 1:** confirm the harness builds and runs cleanly on this machine:
```bash
cd ~/zk-autoresearch/harness/leanmultisig/bench
RUSTFLAGS="-C target-cpu=native" cargo build --release --bin prove_loop --features zkalloc_global
target/release/prove_loop 5  # one-shot smoke; should finish without abort
```
If that fails, the harness is broken — write `needs_from_brain.md` and stop. (This is the only legitimate "stop and ask brain" condition; it is NOT a discard.)

The harness uses `prove_loop 5` with fat LTO + zk-alloc. **This is a different config from the xmss CLI numbers in `m2_profile.md` — do not mix them.**

## What is open

We optimize **for this M2 Asahi machine.** The gap on M2 is +3.4% in zk-alloc's favor
today. The question is whether zk-alloc itself has internal overhead disproportionate
to its useful work on M2 — and how much of that we can recover. Measure it, reduce it,
ship it.

## Reading list before starting

- `experiment_logs/zk-alloc/zk-alloc-m2-asahi/m2_profile.md` — **today's full M2 profile**, copied into this folder for direct reference. Includes IPC, page-fault counters, allocator-related sections, B-suite cross-checks. Skim it before iter 0.
- `experiment_logs/zk-alloc/zk-alloc-m2-asahi/zkalloc_failure.md` — original zk-alloc abort on aarch64 (now fixed). Documents the cfg-gate root cause.
- `crates/backend/zk-alloc/src/lib.rs` — bump arena, slab management, phase boundaries.
- `crates/backend/zk-alloc/src/syscall.rs` — has the aarch64 cfg path now.

## Iteration loop

Commit-eval-decide. **Use the harness scripts, never roll your own gates.**

1. **Profile (or re-profile) before forming a hypothesis.** After every keep, re-profile because the surface shifts.

2. **Form a hypothesis.** State explicitly: what you expect to improve, by how many percentage points (predicted_pp_delta), and the mechanism. "Try X and see" is not a hypothesis; "skipping `MADV_NOHUGEPAGE` on aarch64 should drop a few thousand cycles per arena slab and add ~0.5 pp" is a hypothesis.

3. **Implement one change.** One logical change. Smallest viable diff.

4. **Commit.** Message format: `zkam-<iter>: <description>`. Run `cargo fmt --all` + `cargo clippy --workspace --all-targets -- -D warnings` BEFORE committing. CI on leanMultisig enforces both.

5. **Correctness gate (harness):**
   ```bash
   bash ~/zk-autoresearch/harness/leanmultisig/correctness/correctness.sh
   ```
   Exit 0 = pass. Exit 1 = correctness fail. Exit 2 = nondeterminism (data race). Exit 3 = test-file integrity violation (you modified a test you should not have). Any non-zero → `git revert HEAD`, log iter as `correctness-fail`, next iter.

6. **Perf gate (harness, prove_loop fat LTO + zk-alloc):**
   ```bash
   cd ~/zk-autoresearch
   bash harness/leanmultisig/scripts/eval_paired.sh --baseline HEAD~1 --candidate HEAD --n 3
   ```
   The script builds `prove_loop` (fat LTO + zk-alloc) for both refs, runs 5 proofs each per round × 3 rounds, applies Welch's t-test, and exits with a decision:
   - **exit 0 = keep** (delta ≤ -1.0% AND p < 0.01) → log as `keep`. Re-profile.
   - **exit 1 = discard** → `git revert HEAD`, log as `discard`. Increments the consecutive-discards counter.
   - **exit 2 = infrastructure error** (build failure, identical SHAs, etc.) → diagnose, fix, re-run the gate. Does NOT increment the discard counter, does NOT stop. If the same infrastructure error reproduces 3 times in a row and you genuinely cannot fix it, write `needs_from_brain.md` describing what's broken and continue with the next hypothesis on a different surface (don't stop).

   The full numeric output is at `/tmp/eval_paired_summary.json` after each run — capture into the iter log.

7. **Adapt.** After each result, update your model. 3+ consecutive discards on the same surface → step back, re-profile, reconsider direction. Do not throw the same hypothesis at the wall twice.

**Commit/revert discipline (non-negotiable):**
- Every change gets its own commit. `cargo fmt` + `clippy -D warnings` BEFORE the commit.
- Failed correctness or perf gate → `git revert HEAD` (NEVER `git reset`, NEVER `git checkout` to discard). The revert is itself a commit and stays in the history.
- Two commits per discarded iter is correct: the change + the revert. The audit trail is the experiment.
- No `--no-verify`, no skipping hooks, no force-push to anything that has been pushed.

## Seed ideas to consider (NOT a checklist)

These are starting points, not a task list. Form your own judgment based on what the
profile shows. Free-roam.

- **Profile zk-alloc's own code path on M2.** Does any zk-alloc-internal function (`arena_alloc_cold`, `ensure_region`, the bump fast-path, `begin_phase`/`end_phase`) account for >2% of cycles? If yes, that's a leverage point. If everything zk-alloc-related is sub-1%, the +3.4% is close to physics and the next levers are config-level.
- **Slow-path frequency.** What fraction of allocations hit `arena_alloc_cold`? If the cold path fires often, slab sizing or alignment is wrong for this machine's allocation pattern.
- **`MADV_NOHUGEPAGE` on aarch64.** Hardcoded for all platforms. On x86 Linux it tells the THP scanner to not promote the arena's 4 KiB pages into 2 MiB hugepages (defensive — a THP-collapsed page can't be released without breaking up the slab). On aarch64 Linux with 16 KiB native pages and no equivalent THP-promotion behaviour active by default, the advice may be vestigial. Test: skip it on `target_arch = "aarch64"`, measure.
- **`DEFAULT_SLAB_GB = 8`** + `SLACK = 4` + cpus(10) → 112 GiB region for a 16 GiB machine. Wildly oversized. Test **smaller** slab sizes (1, 2, 4 GiB — never larger than the 8 GiB default on this 16 GiB box) and watch the slab-cold rate. Find the sweet spot.
- **Pre-touch / madvise hints in the active phase region.** Candidates: `MADV_WILLNEED` after `mmap_anonymous` returns in `ensure_region`; `MADV_FREE` in `end_phase` to release used pages back to the kernel between phases. Risk: could regress.
- **Phase-boundary cost.** `begin_phase`/`end_phase` are called per leaf-prove. If the boundary itself is expensive (fence, bump-pointer reset, slab page-table refresh), there may be a cheaper implementation on aarch64.
- **Allocation alignment.** zk-alloc's bump pointer respects `Layout` alignment. If the working set's typical alignment requirements interact badly with 16 KiB pages (e.g., over-aligning small allocs to 16 KiB-multiples wastes space), the bump pattern could shift.
- **Anything else the profile surfaces.** If you see something unexpected, follow it.

## Out of scope

- Touching the standalone `~/zk-autoresearch/zk-alloc` repo (vendored only).
- Allocator comparisons against mimalloc / jemalloc / snmalloc. Different question; not this run.
- leanMultisig prove-side optimizations (Poseidon NEON tuning, framework-level work). Different program.
- Mach-VM-specific work (compression, swap reservation). macOS only; Asahi cannot reproduce.
- Pushing to `Barnadrot/zk-alloc` upstream. Vendored copy only — keep the branch on `Barnadrot/leanMultisig:zk-alloc-m2-asahi`.

## Logging

`experiment_logs/zk-alloc/zk-alloc-m2-asahi/iters.tsv` (replace the existing header with this exact format):

```
iter	predicted_pp	measured_delta_pct	p_value	status	commit	consec_discards	rationale
```

- `iter` — sequential, starting at 1.
- `predicted_pp` — your hypothesis-time predicted improvement (negative number = improvement, e.g. `-1.5` for "expect 1.5% faster").
- `measured_delta_pct` — `delta_pct` field from `/tmp/eval_paired_summary.json`.
- `p_value` — `p_value` field from same.
- `status` — one of: `keep`, `discard`, `correctness-fail`, `infra-error`.
- `commit` — short SHA of the change (or the revert).
- `consec_discards` — running count of consecutive non-keep iters (resets to 0 on keep, increments on discard).
- `rationale` — one-line explanation: hypothesis + outcome.

## Stop criterion

**12 consecutive `discard` iters.** That is the only stop signal.

- `keep` resets the consecutive-discards counter to 0.
- `correctness-fail` and `infra-error` do NOT increment the counter (they're not legitimate discards — the perf gate didn't even run).
- Only `discard` (eval_paired.sh exit 1: gate ran cleanly, change failed the threshold + p-value) increments.

Keep iterating through wins — one keep is not a stop signal, stack them.

## Final write-up

When you stop, write `verdict.md` in this folder with:

- Final eval_paired.sh measurement (HEAD vs the iter-0 commit) — the cumulative improvement from the experiment.
- Per-iter summary of what was tried, what was measured, status. Reference the iters.tsv rows.
- Best surviving change(s) and their commit hashes.
- Honest recommendation: which kept changes are worth syncing upstream to `Barnadrot/zk-alloc`, which are M-series-specific tunings, which are not worth shipping.
- One-paragraph TL;DR.

After verdict, push the branch to `Barnadrot/leanMultisig:zk-alloc-m2-asahi` if any keeps landed. Do NOT open a PR — brain reviews first.

## Discipline reminders

- Real measurement, never analytical deferral. If you think a hypothesis won't help, run it anyway and produce a number.
- `cargo fmt` + `clippy -D warnings` before every commit. CI enforces both.
- One change per iter; commit-eval-decide.
- If a hypothesis surprises you, trust the measurement. Flag the surprise in the iter rationale.
- Never run `git reset --hard` or skip CI gates with `--no-verify`.
