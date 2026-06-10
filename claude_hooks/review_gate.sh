#!/bin/bash
# review_gate — Spec compliance review triggered on git commit.
#
# PostToolUse hook. Fires on Bash tool calls containing `git commit`.
# Reads the plan spec from <experiment_dir>/plan_spec.md and the diff,
# then injects a mandatory review subagent instruction into additionalContext.
#
# The agent MUST spawn a review subagent before proceeding to the next task.
# The subagent compares the diff against the plan spec and returns ACCEPT/REJECT.
#
# Requires: plan_spec.md in experiment dir (written at dispatch or by agent
# after Phase 1 planning). If no plan_spec.md exists, hook is a no-op —
# the review pattern only activates for planned multi-task implementations.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
echo "$COMMAND" | grep -qE "^git commit|&& git commit|; git commit" || exit 0

# --- Find experiment dir ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/zk-autoresearch}"
EXPERIMENT_DIR=""
if [[ -f "${PROJECT_DIR}/.active_experiment" ]]; then
  EXPERIMENT_DIR=$(cat "${PROJECT_DIR}/.active_experiment")
else
  for d in "${PROJECT_DIR}/experiment_logs/leanVM/autoresearcher"/*/; do
    [[ "$d" =~ concluded ]] && continue
    [[ "$d" =~ example ]] && continue
    [[ -f "$d/program.md" ]] && EXPERIMENT_DIR="$d"
  done
fi
[[ -z "$EXPERIMENT_DIR" || ! -d "$EXPERIMENT_DIR" ]] && exit 0

PLAN_SPEC="${EXPERIMENT_DIR}/plan_spec.md"
REVIEW_LOG="${EXPERIMENT_DIR}/.review_log"

# No plan spec → no review gate. Simple iteration loops don't need this.
[[ -f "$PLAN_SPEC" ]] || exit 0

# --- Get the diff from the commit that just happened ---
# Find the target repo (leanVM or wherever the commit was made)
TARGET_REPO=""
if echo "$COMMAND" | grep -qE "cd.*/leanVM"; then
  TARGET_REPO="$HOME/zk-autoresearch/leanVM"
elif [[ -d "$HOME/zk-autoresearch/leanVM/.git" ]]; then
  TARGET_REPO="$HOME/zk-autoresearch/leanVM"
fi
[[ -z "$TARGET_REPO" ]] && exit 0

DIFF=$(cd "$TARGET_REPO" && git diff HEAD~1 --stat 2>/dev/null)
DIFF_FULL=$(cd "$TARGET_REPO" && git diff HEAD~1 2>/dev/null | head -300)
COMMIT_MSG=$(cd "$TARGET_REPO" && git log -1 --format="%s" 2>/dev/null)

# --- Read the current task from plan_spec.md ---
# plan_spec.md has tasks marked with [ ] (pending) and [x] (done).
# Find the first unchecked task — that's what was just implemented.
CURRENT_TASK=$(grep -m1 "^\- \[ \]" "$PLAN_SPEC" 2>/dev/null | sed 's/^- \[ \] //')
[[ -z "$CURRENT_TASK" ]] && CURRENT_TASK="(no pending task found in plan_spec.md)"

# --- Read the spec section for this task ---
# Extract from plan_spec.md: everything from the task header to the next task header or EOF
TASK_SPEC=""
if [[ -n "$CURRENT_TASK" ]]; then
  # Try to find a ## heading matching the task name
  TASK_KEY=$(echo "$CURRENT_TASK" | grep -oE "Task [A-Z][0-9]?" | head -1)
  if [[ -n "$TASK_KEY" ]]; then
    TASK_SPEC=$(sed -n "/## ${TASK_KEY}/,/## Task/p" "$PLAN_SPEC" 2>/dev/null | head -60)
  fi
  # Fallback: first 80 lines of plan_spec.md
  [[ -z "$TASK_SPEC" ]] && TASK_SPEC=$(head -80 "$PLAN_SPEC")
fi

# --- Log ---
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) commit='${COMMIT_MSG}' task='${CURRENT_TASK}'" >> "$REVIEW_LOG"

# --- Build the review prompt ---
# Truncate diff to avoid blowing up context
DIFF_TRUNCATED="${DIFF_FULL}"
if [[ ${#DIFF_FULL} -gt 8000 ]]; then
  DIFF_TRUNCATED="${DIFF_FULL:0:8000}
... (diff truncated at 8000 chars — review agent will read full files)"
fi

REVIEW_PROMPT=$(cat <<'PROMPT_END'
MANDATORY REVIEW GATE — Do NOT proceed to the next task until this review completes.

You just committed: COMMIT_MSG_PLACEHOLDER

Spawn a review subagent NOW with this exact pattern:

agent("You are a spec compliance reviewer. Your ONLY job is to compare a code diff against a plan spec and determine if the implementation matches.

PLAN SPEC FOR THIS TASK:
TASK_SPEC_PLACEHOLDER

DIFF STATS:
DIFF_STATS_PLACEHOLDER

DIFF (first 300 lines):
DIFF_FULL_PLACEHOLDER

Check these criteria:
1. Every function/struct/const named in the spec EXISTS in the diff with matching signatures
2. No todo!(), unimplemented!(), or panic!(\"not yet\") in the diff
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
PROMPT_END
)

# Substitute placeholders
REVIEW_PROMPT="${REVIEW_PROMPT//COMMIT_MSG_PLACEHOLDER/$COMMIT_MSG}"
REVIEW_PROMPT="${REVIEW_PROMPT//TASK_SPEC_PLACEHOLDER/$TASK_SPEC}"
REVIEW_PROMPT="${REVIEW_PROMPT//DIFF_STATS_PLACEHOLDER/$DIFF}"
REVIEW_PROMPT="${REVIEW_PROMPT//DIFF_FULL_PLACEHOLDER/$DIFF_TRUNCATED}"

jq -n --arg msg "$REVIEW_PROMPT" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'

exit 0
