## Multi-Task Implementation (replaces WIP arc)

For structural changes that span multiple files and commits (protocol replacements, multi-file refactors):

1. **Plan in /plan mode.** Produce the full implementation plan with tasks, file ownership, signatures, dependencies.
2. **Save the plan as `plan_spec.md`** in your experiment dir before your first implementation commit.
3. **One commit per task.** Each task gets its own commit. No batching, no partial commits.
4. **Review gate fires on every commit.** A hook compares your diff against plan_spec.md and injects a review subagent prompt. Spawn it, wait for ACCEPT. On REJECT, fix the listed gaps and commit again.
5. **Mark completed tasks.** On ACCEPT, mark the task `[x]` in plan_spec.md, proceed to the next.
6. **Correctness gate runs after the final task**, not after each intermediate commit. Performance gate runs against the pre-plan baseline.
7. **If the final gate discards:** `git revert` all commits back to the pre-plan baseline.

Simple one-commit iterations (single hypothesis → implement → gate) don't need a plan spec. The review gate is a no-op without plan_spec.md.
