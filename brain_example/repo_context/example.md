# Repo context — <project-name>

Mutable facts about a target repo. Read by `brain-author-*` personas before authoring program.md. Updated whenever a new profiling baseline lands or a known-no-go shifts.

Create one file per target repo: `repo_context/<project>.md`.

## What it is

One-paragraph description of the project, its primary metric, and hard constraints (e.g., proof size budget, latency target).

## Location

```
~/zk-autoresearch/<project>          # cloned per scripts/setup/<project>.sh
```

## Active baseline

| Item | Value |
|---|---|
| Branch baseline | `origin/main @ <commit>` |
| Wall-clock at baseline | e.g., 2.1s per proof on <hardware> |
| IPC parallel / serial | e.g., 0.82 / 1.29 |
| Workload classification | e.g., compute-bound-throughput, memory-bound-bandwidth |
| Size budget | e.g., 128 KiB |

Source of truth: `experiment_logs/<project>/profiling/...`

## Canonical workload

The exact command that produces the benchmark number:
```bash
RUSTFLAGS="-C target-cpu=native" cargo run --release -- <workload args>
```

## Architecture (brief)

Key crates/modules, hot path, what the profiling baseline identified as the bottleneck. Keep to ~20 lines — enough for an author persona to write a targeted program.md.

## Known no-go zones

Things that have been tried and failed, or are off-limits for policy reasons. Prevents agents from re-exploring dead ends.

| No-go | Why |
|---|---|
| e.g., Algorithm X | Tried in pw3, +52% regression due to column explosion |
| e.g., Migration to Y | Team decision for security reasons, not a valid candidate |

## Cross-repo dependencies

Other repos this project depends on or is depended on by. Relevant for cherry-pick and integration experiments.
