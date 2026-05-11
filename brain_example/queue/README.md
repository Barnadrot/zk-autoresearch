# brain/queue/ — experiment lifecycle shards

State is implicit in the parent directory. State transitions = `mv` between subdirs (atomic on POSIX, no locking needed).

## States

| Dir | Meaning | Who writes |
|---|---|---|
| `pending/` | Awaiting dispatch. Brain or specialist persona creates entries here. | brain, brain.deep, brain.portfolio |
| `claimed/` | Coordinator confirmed capacity, about to launch. | coordinator |
| `active/` | Tmux session running, iters.tsv growing. | coordinator |
| `done/` | Stop criterion hit, `pr_body.md` drafted by experiment agent. | coordinator |
| `merged/` | PR merged upstream. | coordinator |
| `killed/` | PR closed without merge OR experiment killed. Retrospective written. | coordinator |
| `needs-decision/` | Coordinator detected an ambiguous case and is asking brain. | coordinator writes, brain resolves |

## Per-experiment file shape

```json
{
  "id": "<project>-<topic>-YYYY-MM-DD",
  "project": "leanMultisig|Plonky3|zk-alloc|jolt|...",
  "experiment_dir": "experiment_logs/<project>/<experiment>",
  "program_path": "experiment_logs/<project>/<experiment>/program.md",
  "hardware_tag": "avx512|aarch64|gpu",
  "branch": "experiment/<name>",
  "executor_assigned": "ccx33|m2|null",
  "session_uuid": "...|null",
  "created_by": "brain|brain-deep|brain-portfolio",
  "created_at": "YYYY-MM-DDTHH:MM:SSZ",
  "started_at": "...|null",
  "stop_criterion": "12_consecutive_discards|N_iters|...",
  "stale_threshold_min": 30,
  "pr_draft_path": "...|null"
}
```

For `needs-decision/` entries, additional fields:
```json
{
  "raised_by": "coordinator",
  "raised_at": "...",
  "issue": "<one-line description>",
  "context_for_brain": "<everything brain needs to decide>",
  "options_coordinator_sees": ["..."],
  "coordinator_lean": "...|null",
  "deadline": "...|null"
}
```

## Discipline

- Coordinator writes only on confirmed state transitions, never heartbeats.
- Brain reads `queue/active/` and `queue/needs-decision/` at the start of every conversation turn.
- Coordinator never PushNotifies the user directly. Escalations land in `needs-decision/` for brain to route.
- Historical sessions (pre-2026-05-11) remain in `brain/report/sessions.json` as legacy record. No retroactive migration.
