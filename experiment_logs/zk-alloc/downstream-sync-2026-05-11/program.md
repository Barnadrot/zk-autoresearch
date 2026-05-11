# zk-alloc downstream-sync — propagate leanMultisig improvements upstream

## Role

You are a backports engineer. Your job: take the zk-alloc improvements that landed downstream in `Barnadrot/leanMultisig` (Emile's code quality work + the M2 Asahi experiment results) and propagate them upstream to `Barnadrot/zk-alloc` as a single rollup PR.

You do NOT design new optimizations. You do NOT run a perf loop. You read existing diffs, make port-or-skip decisions, apply the kept ports as discrete commits, run CI gates, and draft a PR body.

You are running on Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512). The work is mostly diffing + small edits + cargo runs; no perf benchmarks expected.

## Context (read before starting)

**Already in flight (do NOT re-port these):**
- `Barnadrot/zk-alloc#11` — aarch64 MAP_NORESERVE syscall fix (merged tomorrow)
- `Barnadrot/zk-alloc#12` — flat-phase assert contract (CI green, merged tomorrow). Branch: `fix/assert-flat-phase-contract`. **You will base your work on this branch.**

**Sources of the deltas you need to port:**
1. `Barnadrot/leanMultisig` branch `zk-alloc-m2-asahi` — has the M2 Asahi experiment's kept commits (iters 8, 10, 19 specifically; verify via the iters.tsv summary at `experiment_logs/zk-alloc/zk-alloc-m2-asahi/iters.tsv` on the brain side, or by reading the branch's git log).
2. `Barnadrot/leanMultisig` branch `main` — has Emile's code quality work in `crates/backend/zk-alloc/src/lib.rs` that may not be in upstream yet.

The vendored zk-alloc lives at `crates/backend/zk-alloc/src/` inside leanMultisig. Upstream lives at the root of `Barnadrot/zk-alloc`.

**Known M2 wins worth porting (per project_zkalloc_pretouch_oom.md):**
- iter 8: 32 MiB-aligned mmap + `MADV_HUGEPAGE` + eager pre-touch (-2.51% throughput on M2)
- iter 10: `MIN_ARENA_BYTES=256` default (changed from 4096)
- iter 19: adaptive `PRETOUCH_BYTES` capped at `MemTotal / N_slabs / 3` (required for the iter 8 win to be portable to 16 GiB M-series Macs — without it, iter 8 OOMs)

**iter 8 must NOT ship without iter 19's adaptive cap.** If you port one, port both. Iter 8 alone OOMs 16 GiB Macs (Justin's target). This is non-negotiable.

## Repo

| Repo | Path on executor | Branch | Role |
|------|------|--------|------|
| zk-alloc upstream | `~/zk-autoresearch/zk-alloc` | base from `fix/assert-flat-phase-contract` (PR #12 tip) | target — you create one new branch here |
| leanMultisig downstream | `~/zk-autoresearch/leanMultisig` | `myfork/zk-alloc-m2-asahi` and `myfork/main` | read-only, source of deltas |

Remote shortcuts:
- `~/zk-autoresearch/leanMultisig` has `myfork` = `Barnadrot/leanMultisig`, `origin` = `leanEthereum/leanMultisig`
- `~/zk-autoresearch/zk-alloc` has `origin` = `Barnadrot/zk-alloc`

**Setup:**
```bash
cd ~/zk-autoresearch/leanMultisig
git fetch myfork
git fetch origin

cd ~/zk-autoresearch/zk-alloc
git fetch origin
git checkout fix/assert-flat-phase-contract
git pull origin fix/assert-flat-phase-contract
git checkout -b sync-from-leanmultisig-m2-2026-05-11
```

You will commit each port as a discrete commit on `sync-from-leanmultisig-m2-2026-05-11`, branched from PR #12's tip. Final state: one branch with N port commits, ready to be opened as a single rollup PR after PR #12 merges.

## Procedure

### Step 1: enumerate the deltas

```bash
cd ~/zk-autoresearch/leanMultisig
git log --oneline myfork/main -- crates/backend/zk-alloc/   # Emile's code quality
git log --oneline myfork/zk-alloc-m2-asahi ^myfork/main -- crates/backend/zk-alloc/   # M2 experiment commits
git diff myfork/main..myfork/zk-alloc-m2-asahi -- crates/backend/zk-alloc/src/    # actual M2 deltas
```

Build a list of candidate ports. Each entry is one logical change (a single commit or a small group of commits implementing one feature). For each, note:
- source: which downstream branch + commits
- one-line description
- predicted classification: port / skip / already-upstream

Record this list in `ports.tsv` (see "Output" below) before making any code changes.

### Step 2: for each candidate, decide port vs skip

A port is worth doing if:
- The change improves performance, correctness, or code quality
- It is NOT leanMultisig-specific (e.g., references to leanMultisig's bench harness, internal types, or vendored-only paths)
- It does NOT introduce a regression on x86 (your test surface)
- For M2-specific perf wins: the iter 8 + iter 19 pairing rule applies — don't port iter 8 without iter 19

Skip if:
- Already in upstream main (verify with `git log Barnadrot/zk-alloc:main -- src/lib.rs | grep <key string>`)
- leanMultisig-specific (references types/paths that don't exist in standalone zk-alloc)
- A WIP / experimental flag that hasn't proved out
- Conflicts irreconcilably with PR #12's assert-flat-phase contract

Record the decision in `ports.tsv` regardless of which way it goes.

### Step 3: apply kept ports as commits

For each port:
1. Make the smallest possible code change in upstream `zk-alloc/src/`
2. Write a one-line commit message matching upstream's convention (`perf:`, `chore:`, `fix:`, etc.)
3. Commit on `sync-from-leanmultisig-m2-2026-05-11`
4. Run the CI gates locally **after each commit** — do not batch:
   ```bash
   cargo fmt --check
   cargo clippy --workspace --all-targets -- -D warnings
   cargo test --workspace
   ```
5. If gates fail: fix in a `chore: fix CI` commit appended to the same branch, do not amend. Retry gates.
6. Update the row in `ports.tsv` with the commit SHA and `gates_passed: yes`.

### Step 4: draft the rollup PR body

After all ports are committed and gates pass, draft a single `pr_body.md` at this experiment dir's root with the following shape:

```markdown
# perf: sync M2 Asahi improvements + downstream code quality from leanMultisig

## Summary

<2-3 sentences: what's being ported, why, what changed in the prover>

## Stacked on PR #12

This branch is based on `fix/assert-flat-phase-contract` (PR #12). It assumes that PR merges first. Rebase to `main` after #12 lands if needed.

## Commits in this rollup

| Commit | Source | Change | Verified |
|---|---|---|---|
| <sha> | leanMultisig:zk-alloc-m2-asahi iter 8 + 19 | 32 MiB-aligned mmap + MADV_HUGEPAGE + adaptive PRETOUCH_BYTES | cargo fmt + clippy + test green on Hetzner Zen 4 |
| <sha> | leanMultisig:zk-alloc-m2-asahi iter 10 | MIN_ARENA_BYTES default → 256 | ... |
| <sha> | leanMultisig:main (Emile) | <code quality change> | ... |
| ... | ... | ... | ... |

## Memory-adaptive pretouch — why it matters

<one paragraph explaining the iter 8 + iter 19 pairing rule: iter 8's 14 GiB anon-rss OOMs 16 GiB Macs without iter 19's MemTotal-adaptive cap. Justin's target hardware includes 16 GiB M1/M2/M3. Both must ship together.>

## Test plan

- [ ] CI green on this PR
- [ ] Local cargo test --workspace passes after every commit (verified during port)
- [ ] No regression on x86_64 (validated implicitly by Hetzner gate; full perf re-validation deferred to a follow-up paired benchmark)
- [ ] Adaptive PRETOUCH formula tested on Hetzner (64 GiB) — pre-touch headroom ≈ 1 GiB per slab (cap), matches pre-port behavior

## What was deliberately not ported

<list any skipped deltas with the reason — leanMultisig-specific, already-upstream, etc.>

---
*Drafted by experiment agent on 2026-05-11. Audit trail at `experiment_logs/zk-alloc/downstream-sync-2026-05-11/ports.tsv`. Stop criterion: every identified delta has a decision row.*

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

### Step 5: exit cleanly

After `pr_body.md` exists and `ports.tsv` has a row for every identified delta:

1. Verify your branch is clean: `git status` shows nothing uncommitted
2. **Do NOT push the branch.** Brain reviews + pushes + opens the PR.
3. **Do NOT open the PR.** Same reason.
4. Print a one-paragraph summary to stdout: how many ports, how many skips, total commits on the branch, CI gate state per commit.
5. Exit.

## Output files

- `experiment_logs/zk-alloc/downstream-sync-2026-05-11/ports.tsv` — append-only, one row per delta evaluated. Format:
  ```
  iter\tsource\tdescription\tdecision\tcommit_sha\tgates_passed\trationale
  ```
  Where `iter` is 1-based, `source` references the downstream branch + commit(s), `decision` is `port|skip|merge-with-other`, `gates_passed` is `yes|no|n/a`, `rationale` is one short line.
- `experiment_logs/zk-alloc/downstream-sync-2026-05-11/pr_body.md` — final deliverable. Brain reads this after coordinator marks the experiment `done`.

## Stop criterion

`ports.tsv` has a row for every delta the diff in step 1 surfaced. Every `decision: port` row has a non-null `commit_sha` and `gates_passed: yes`. `pr_body.md` exists and is non-empty.

## Hard constraints

- **Never amend commits.** Append fix commits if needed.
- **Never `git reset --hard`** or any destructive operation. Branch state is the audit trail.
- **Never push the experiment branch.** Brain pushes.
- **Never open the PR.** Brain opens.
- **No new feature design.** Only ports.
- **Run CI gates after every commit.** Per the brain-side rule `feedback_check_ci_before_pr.md`.
- **iter 8 + iter 19 must be in the same branch.** Don't ship one without the other.
- **No tmux send-keys or shell scripts outside cargo + git + standard utilities.** This is a port task; no need for ssh or runtime testing.

## Hardware-specific notes

You are on Hetzner x86_64. The M2 wins were measured on Apple Silicon. You can verify code compiles and tests pass on x86; you cannot re-measure the M2 perf delta. That's OK — the perf re-measurement happens upstream after merge, on the M2 machine, as a follow-up. Your job is "ports apply cleanly and don't regress correctness on x86."
