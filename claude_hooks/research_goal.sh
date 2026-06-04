#!/bin/bash
# research_goal — custom /goal replacement promoting depth over speed.
#
# PostToolUse hook. Fires on ScheduleWakeup and eval_paired result reads.
# Injects phase-aware, depth-oriented prompts instead of failure summaries.
#
# Goal is stored in <experiment_dir>/.research_goal (plain text).
# Write the goal there before dispatching the agent.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ -z "$TOOL_NAME" ]] && exit 0

# --- Only fire on ScheduleWakeup and eval_paired reads ---
case "$TOOL_NAME" in
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    echo "$COMMAND" | grep -qE "eval_paired_summary|eval_recursion_summary" || exit 0
    ;;
  ScheduleWakeup)
    ;;
  *)
    exit 0
    ;;
esac

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

GOAL_FILE="${EXPERIMENT_DIR}/.research_goal"
STATE_FILE="${EXPERIMENT_DIR}/.phase_state"
ITER_FILE="${EXPERIMENT_DIR}/.current_iter"
ITERS_TSV="${EXPERIMENT_DIR}/iters.tsv"
REPORT_DIR="${EXPERIMENT_DIR}/report"

[[ -f "$GOAL_FILE" ]] || exit 0
[[ -f "$STATE_FILE" ]] || exit 0
[[ -f "$ITER_FILE" ]] || exit 0

GOAL=$(cat "$GOAL_FILE")
PHASE=$(cat "$STATE_FILE")
ITER=$(cat "$ITER_FILE")
REQUIRED_PAPERS=${PHASE1_PAPER_MINIMUM:-10}
PAPERS_DIR="${REPORT_DIR}/papers/iter_${ITER}"

# --- Counts ---
KEEPS=0; DISCARDS=0; TOTAL=0
if [[ -f "$ITERS_TSV" ]]; then
  KEEPS=$(tail -n +2 "$ITERS_TSV" | grep -c "keep" 2>/dev/null || echo 0)
  DISCARDS=$(tail -n +2 "$ITERS_TSV" | grep -c "discard" 2>/dev/null || echo 0)
  TOTAL=$(tail -n +2 "$ITERS_TSV" | grep -c "." 2>/dev/null || echo 0)
fi

PAPERS=0
[[ -d "$PAPERS_DIR" ]] && PAPERS=$(find "$PAPERS_DIR" -name "*.pdf" -type f 2>/dev/null | wc -l | tr -d ' ')

# --- Build message per phase ---
MSG=""
case "$PHASE" in
  phase_0)
    MSG="RESEARCH GOAL: ${GOAL}. Phase 0 (profiling). ${KEEPS} keeps / ${TOTAL} iterations. Focus on deep codebase understanding. Have you inspected the proof transcript with the Python verifier? Have you profiled warm proofs?"
    ;;
  phase_1)
    MSG="RESEARCH GOAL: ${GOAL}. Phase 1 (research). Papers: ${PAPERS}/${REQUIRED_PAPERS}. ${KEEPS} keeps / ${TOTAL} iterations. Depth determines quality. Find techniques from DIFFERENT subfields that compose into novel approaches."
    ;;
  phase_2)
    MSG="RESEARCH GOAL: ${GOAL}. Phase 2 (implementation). ${KEEPS} keeps / ${TOTAL} iterations. If blocked or growing complex, decompose into smaller testable steps. Do NOT write todo!() stubs."
    ;;
  phase_3|phase_gate_running)
    MSG="RESEARCH GOAL: ${GOAL}. Gate running. ${KEEPS} keeps / ${TOTAL} iterations."
    ;;
esac

# --- Stall patterns ---
if [[ "$TOTAL" -ge 3 && "$KEEPS" -eq 0 ]]; then
  MSG="${MSG} WARNING: ${TOTAL} iterations, 0 keeps. Your hypotheses are not working. Return to Phase 1 with papers from DIFFERENT areas than what you tried."
fi

if [[ "$TOTAL" -ge 4 && "$KEEPS" -gt 0 ]]; then
  RECENT=$(tail -3 "$ITERS_TSV" 2>/dev/null | grep -c "discard" || echo 0)
  if [[ "$RECENT" -ge 3 ]]; then
    MSG="${MSG} NOTE: Last 3 iterations were discards after prior keeps. Current surface may be exhausted. Return to Phase 1 with completely different research angle."
  fi
fi

# --- Output ---
if [[ -n "$MSG" ]]; then
  jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
fi

exit 0
