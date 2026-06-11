# Claude Hooks — Message Reference

All hooks are PostToolUse. They fire AFTER the tool runs and inject advisory context via `additionalContext`. They cannot block tool execution.

Settings: `settings_executor.json` → copy to `~/zk-autoresearch/.claude/settings.json` on each executor.

**Dependency:** All hooks require `jq` on the executor (`sudo apt install jq`).

---

## phase_gate.sh

Enforces the Phase 0→1→2→3 research methodology. Fires on Bash, Write, Edit, Read.

### State files (auto-created in experiment dir)
- `.phase_state` — current phase (`phase_0`, `phase_1`, `phase_2`, `phase_3`, `phase_gate_running`)
- `.current_iter` — iteration counter (starts at 1, increments on keep/revert)
- `.papers_read` — tracks which PDFs the agent has Read (per-iteration)
- `.hook_log` — audit trail of all hook actions

### Triggers → Messages

| Trigger | Condition | Message injected |
|---|---|---|
| **Write/Edit to `hypothesis_pool`** | Phase is `phase_0` AND no profiling artifacts in `report/` | `PHASE GATE: Phase 0 incomplete. Write profiling output to report/ before developing hypotheses.` |
| **Write/Edit to `leanVM/crates/`** | Paper count < 10 in `report/papers/iter_N/` | `PHASE GATE: {count}/10 papers in {path}. You cannot implement without reading 10 papers this iteration. Download and read papers first.` |
| **Write/Edit to `leanVM/crates/`** | Papers downloaded but not Read | `PHASE GATE: {count} papers downloaded but only {read_count} read. Read {path}/name.pdf for {remaining} more before implementing.` |
| **Write/Edit to `leanVM/crates/`** | Primitive count < 15 in `report/mechanism_inventory.yaml` | `PHASE GATE: {count}/15 primitives in mechanism_inventory.yaml. Decompose each paper into typed primitives (id, mechanism, cost_model, assumptions, composable_with) before implementing.` |
| **Write/Edit to `crates/backend/zk-alloc/`** | Always | `CONSTRAINT 5: Do not modify the zk-alloc crate. If your hypothesis requires allocation changes, kill it.` |
| **Bash: `git commit`** | Always (when phase tracking active) | Advances phase to `phase_3`. No message. |
| **Bash: `git revert`** | Always | `PHASE GATE: Reverted. Iteration {N}. Download 10 NEW papers to report/papers/iter_{N}/ before next attempt.` Resets to `phase_1`, increments iter. |
| **Keep detected** (agent reads eval summary containing `"decision": "keep"`) | Always | `PHASE GATE: Keep confirmed. Iteration {N}. Re-profile (Phase 0) then read 10 new papers (Phase 1).` Resets to `phase_0`, increments iter. |
| **Write/Edit to `.phase_state`** | Always | `PHASE GATE: Do not modify .phase_state. Phase transitions are managed automatically by the hook.` |
| **Bash: `curl/wget .pdf` to `/tmp/`** | Always | `TIP: Save papers to {papers_dir}/ instead of /tmp/ so they count toward Phase 1.` |
| **Write to `.md` with plateau language** | Content matches `plateau\|search space.*exhausted\|optimization.*ceiling` | `PHASE GATE: Plateau language detected. This requires human confirmation. List 10 unexplored research directions — if you can name them, return to Phase 1.` |

### Phase transitions (automatic)
```
phase_0 → phase_1  : profiling artifacts exist + agent writes hypothesis_pool
phase_1 → phase_2  : 10 papers downloaded AND read AND 15+ primitives in mechanism_inventory.yaml
phase_2 → phase_3  : git commit
phase_3 → phase_0  : keep detected (new iter)
phase_3 → phase_1  : git revert (new iter)
```

### Known issues
- Paper count checks `report/papers/iter_N/*.pdf` only — papers in `/tmp/` don't count
- Iter counter initializes at 1 when state files are created mid-session (not from iters.tsv)
- PostToolUse is advisory — agent can proceed despite the message

---

## research_goal.sh

Depth-oriented nudges injected at decision points. Fires on Bash (eval_paired reads) and ScheduleWakeup.

### State files
- `.research_goal` — plain text goal statement (written at dispatch)
- Reads `.phase_state`, `.current_iter`, `iters.tsv` from experiment dir

### Triggers → Messages

| Trigger | Condition | Message injected |
|---|---|---|
| **ScheduleWakeup** | Phase is `phase_0` | `RESEARCH GOAL: {goal}. Phase 0 (profiling). {keeps} keeps / {total} iterations. Focus on deep codebase understanding. Have you inspected the proof transcript with the Python verifier? Have you profiled warm proofs?` |
| **ScheduleWakeup** | Phase is `phase_1` | `RESEARCH GOAL: {goal}. Phase 1 (research). Papers: {count}/{required}. {keeps} keeps / {total} iterations. Depth determines quality. Find techniques from DIFFERENT subfields that compose into novel approaches.` |
| **ScheduleWakeup** | Phase is `phase_2` | `RESEARCH GOAL: {goal}. Phase 2 (implementation). {keeps} keeps / {total} iterations. If blocked or growing complex, decompose into smaller testable steps. Do NOT write todo!() stubs.` |
| **ScheduleWakeup** | Phase is `phase_3` or `phase_gate_running` | `RESEARCH GOAL: {goal}. Gate running. {keeps} keeps / {total} iterations.` |
| **Bash: read eval summary** | Same as above (fires on `cat.*/tmp/eval_.*summary`) | Same phase-aware message as ScheduleWakeup |
| **Stall: 0 keeps after 3+ iters** | `total >= 3 AND keeps == 0` | Appends: `WARNING: {total} iterations, 0 keeps. Your hypotheses are not working. Return to Phase 1 with papers from DIFFERENT areas than what you tried.` |
| **Stall: 3 consecutive discards after keeps** | `total >= 4 AND keeps > 0 AND last 3 = discard` | Appends: `NOTE: Last 3 iterations were discards after prior keeps. Current surface may be exhausted. Return to Phase 1 with completely different research angle.` |

### No-op conditions
- No `.research_goal` file → silent exit
- No `.phase_state` file → silent exit
- Tool is not ScheduleWakeup or Bash with eval summary pattern → silent exit

---

## review_gate.sh

Spec compliance review triggered on git commit. Fires on Bash only.

### State files
- `plan_spec.md` in experiment dir (agent-written after Phase 1 planning)
- `.review_log` — audit trail of commits reviewed

### Triggers → Messages

| Trigger | Condition | Message injected |
|---|---|---|
| **Bash: `git commit`** | `plan_spec.md` exists in experiment dir | Full review prompt (see below) |
| **Bash: `git commit`** | No `plan_spec.md` | Silent exit (no-op) |

### Review prompt (injected verbatim)

```
MANDATORY REVIEW GATE — Do NOT proceed to the next task until this review completes.

You just committed: {commit_message}

Spawn a review subagent NOW with this exact pattern:

agent("You are a spec compliance reviewer. Your ONLY job is to compare
a code diff against a plan spec and determine if the implementation matches.

PLAN SPEC FOR THIS TASK:
{task_spec_from_plan_spec.md}

DIFF STATS:
{git diff HEAD~1 --stat}

DIFF (first 300 lines):
{git diff HEAD~1 | head -300}

Check these criteria:
1. Every function/struct/const named in the spec EXISTS in the diff with matching signatures
2. No todo!(), unimplemented!(), or panic!("not yet") in the diff
3. No functions from the spec are MISSING from the diff
4. Return types match what downstream tasks expect
5. If the spec mentions transcript format, verify prover/verifier transcript calls match

Return EXACTLY one of:
ACCEPT — all spec items present and signatures match
REJECT — followed by a numbered list of specific gaps

Be strict. A plausible-looking implementation that is missing spec items is a REJECT.
Do NOT accept partial implementations. Do NOT accept stubs.", {label: "review-gate"})

If the review returns REJECT:
- Do NOT proceed to the next task
- Fix every gap listed in the rejection
- Commit the fix
- The review gate will fire again on the new commit

If the review returns ACCEPT:
- Mark the task as done in plan_spec.md (change [ ] to [x])
- Proceed to the next task
```

### Task detection
- Finds the first unchecked `- [ ]` line in plan_spec.md
- Extracts the `## Task X` section matching that line (or falls back to first 80 lines)
- Diff is truncated at 8000 chars to avoid context bloat

---

## settings_executor.json

Hook wiring configuration. Copy to `~/zk-autoresearch/.claude/settings.json` on each executor.

```json
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash",          "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/phase_gate.sh"}]},
      {"matcher": "Write",         "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/phase_gate.sh"}]},
      {"matcher": "Edit",          "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/phase_gate.sh"}]},
      {"matcher": "Read",          "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/phase_gate.sh"}]},
      {"matcher": "Bash",          "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/review_gate.sh"}]},
      {"matcher": "Bash",          "hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/research_goal.sh"}]},
      {"matcher": "ScheduleWakeup","hooks": [{"type": "command", "command": "bash ~/zk-autoresearch/claude_hooks/research_goal.sh"}]}
    ]
  }
}
```

---

## Dispatch checklist

1. `jq` installed on executor (`which jq`)
2. `settings_executor.json` copied to `~/zk-autoresearch/.claude/settings.json`
3. `.active_experiment` written: `echo "/path/to/experiment_dir" > ~/zk-autoresearch/.active_experiment`
4. `.research_goal` written in experiment dir (one-sentence target)
5. `report/papers/iter_1/` directory created: `mkdir -p <experiment_dir>/report/papers/iter_1`
6. `/tmp/*.pdf` cleaned: `rm /tmp/*.pdf` (prevents stale paper cache hits)
7. leanVM repo on correct branch
