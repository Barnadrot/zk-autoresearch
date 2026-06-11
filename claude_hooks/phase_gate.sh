#!/bin/bash
# Phase gate hook for zk-autoresearch executor agents.
#
# PostToolUse hook — fires after Bash, Write, Edit, Read.
# Reads JSON from stdin, returns JSON with hookSpecificOutput.additionalContext.
# PostToolUse CANNOT block (tool already ran). Messages are advisory.
# Move to PreToolUse for hard blocking in the future.
#
# State: <experiment_dir>/.phase_state, .current_iter
# Papers: report/papers/iter_<N>/*.pdf (count on disk)
# Reads:  .papers_read log (tracks Read calls on PDFs)
# Audit:  .hook_log

set -uo pipefail

# --- Read JSON from stdin ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ -z "$TOOL_NAME" ]] && exit 0

# --- Extract tool content based on tool type ---
case "$TOOL_NAME" in
  Bash)
    TOOL_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    ;;
  Write|Edit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty')
    TOOL_CONTENT="${FILE_PATH} ${CONTENT}"
    ;;
  Read)
    TOOL_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
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

STATE_FILE="${EXPERIMENT_DIR}/.phase_state"
ITER_FILE="${EXPERIMENT_DIR}/.current_iter"
REPORT_DIR="${EXPERIMENT_DIR}/report"
HOOK_LOG="${EXPERIMENT_DIR}/.hook_log"
PAPERS_READ_LOG="${EXPERIMENT_DIR}/.papers_read"

# --- Initialize ---
[[ -f "$STATE_FILE" ]] || echo "phase_0" > "$STATE_FILE"
[[ -f "$ITER_FILE" ]] || echo "1" > "$ITER_FILE"

CURRENT_PHASE=$(cat "$STATE_FILE")
CURRENT_ITER=$(cat "$ITER_FILE")
REQUIRED_PAPERS=${PHASE1_PAPER_MINIMUM:-10}
PAPERS_DIR="${REPORT_DIR}/papers/iter_${CURRENT_ITER}"

# --- Helpers ---
count_papers() {
  [[ -d "$PAPERS_DIR" ]] && find "$PAPERS_DIR" -name "*.pdf" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0"
}

count_papers_read() {
  [[ -f "$PAPERS_READ_LOG" ]] && grep -c "^iter_${CURRENT_ITER}:" "$PAPERS_READ_LOG" 2>/dev/null | tr -d ' ' || echo "0"
}

log_hook() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) phase=$CURRENT_PHASE iter=$CURRENT_ITER tool=$TOOL_NAME $1" >> "$HOOK_LOG"
}

inject() {
  local msg="$1"
  log_hook "inject: ${msg:0:80}"
  jq -n --arg msg "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
}

# --- Track paper reads ---
if [[ "$TOOL_NAME" == "Read" ]] && echo "$TOOL_CONTENT" | grep -qE "\.pdf"; then
  PDF_PATH=$(echo "$TOOL_CONTENT" | grep -oE "[^ ]*\.pdf" | head -1)
  if [[ -n "$PDF_PATH" ]]; then
    # Only count if not already logged for this iteration
    if ! grep -qF "iter_${CURRENT_ITER}:${PDF_PATH}" "$PAPERS_READ_LOG" 2>/dev/null; then
      echo "iter_${CURRENT_ITER}:${PDF_PATH}" >> "$PAPERS_READ_LOG"
      log_hook "paper_read:${PDF_PATH}"
    fi
  fi
fi

# --- Block agent from writing .phase_state directly (any tool) ---
if echo "$TOOL_CONTENT" | grep -qE "\.phase_state"; then
  if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Bash" ]]; then
    log_hook "blocked:direct_phase_state_write:${TOOL_NAME}"
    inject "PHASE GATE: Do not modify .phase_state. Phase transitions are managed automatically by the hook based on your artifacts (profiling, papers, commits, reverts)."
    exit 0
  fi
fi

# --- Block zk-alloc crate modifications (hard constraint 5) ---
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]] && echo "$TOOL_CONTENT" | grep -qE "crates/backend/zk-alloc/"; then
  log_hook "blocked:zk_alloc_modification:${TOOL_NAME}"
  inject "CONSTRAINT 5: Do not modify the zk-alloc crate (crates/backend/zk-alloc/). If your hypothesis requires allocation changes, kill it — this constraint is non-negotiable."
  exit 0
fi

# --- Nudge: curl to /tmp/ instead of papers dir ---
if [[ "$TOOL_NAME" == "Bash" ]] && echo "$TOOL_CONTENT" | grep -qE "curl.*\.pdf.*-o.*/tmp/|wget.*\.pdf.*/tmp/"; then
  inject "TIP: Save papers to ${PAPERS_DIR}/ instead of /tmp/ so they count toward Phase 1. mkdir -p ${PAPERS_DIR} && curl -s -o ${PAPERS_DIR}/name.pdf ..."
  exit 0
fi

# --- Phase 0: profiling required before hypothesis writing ---
if [[ "$CURRENT_PHASE" == "phase_0" && ("$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit") ]]; then
  if echo "$TOOL_CONTENT" | grep -q "hypothesis_pool"; then
    HAS_PROFILE=false
    ls "$REPORT_DIR"/*profile* "$REPORT_DIR"/*phase_0* "$REPORT_DIR"/*flamegraph* "$REPORT_DIR"/*perf* 2>/dev/null | head -1 >/dev/null 2>&1 && HAS_PROFILE=true

    if [[ "$HAS_PROFILE" == "false" ]]; then
      log_hook "blocked:phase0_incomplete"
      inject "PHASE GATE: Phase 0 incomplete. Write profiling output to report/ before developing hypotheses."
      exit 0
    else
      echo "phase_1" > "$STATE_FILE"
      mkdir -p "$PAPERS_DIR"
      log_hook "advance:phase_0->phase_1"
    fi
  fi
fi

# --- Paper check: fires on ANY phase when agent tries to implement ---
# This prevents the agent from bypassing Phase 1 by writing .phase_state directly.
PAPER_COUNT=$(count_papers)
READ_COUNT=$(count_papers_read)
TRYING_TO_IMPLEMENT=false

if [[ "$TOOL_NAME" == "Bash" ]] && echo "$TOOL_CONTENT" | grep -qE "^git commit|&& git commit|; git commit"; then
  TRYING_TO_IMPLEMENT=true
fi
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]] && echo "$TOOL_CONTENT" | grep -qE "leanVM/crates/"; then
  TRYING_TO_IMPLEMENT=true
fi

if [[ "$TRYING_TO_IMPLEMENT" == "true" && "$PAPER_COUNT" -lt "$REQUIRED_PAPERS" ]]; then
  log_hook "blocked:papers_insufficient:${PAPER_COUNT}/${REQUIRED_PAPERS}:phase=${CURRENT_PHASE}"
  inject "PHASE GATE: ${PAPER_COUNT}/${REQUIRED_PAPERS} papers in ${PAPERS_DIR}/. You cannot implement without reading ${REQUIRED_PAPERS} papers this iteration. Download and read papers first."
  exit 0
fi
if [[ "$TRYING_TO_IMPLEMENT" == "true" && "$READ_COUNT" -lt "$REQUIRED_PAPERS" ]]; then
  log_hook "blocked:papers_not_read:${READ_COUNT}/${REQUIRED_PAPERS}:phase=${CURRENT_PHASE}"
  inject "PHASE GATE: ${PAPER_COUNT} papers downloaded but only ${READ_COUNT} read. Read ${PAPERS_DIR}/name.pdf for $((REQUIRED_PAPERS - READ_COUNT)) more before implementing."
  exit 0
fi

# Advance from phase_1 to phase_2 if papers satisfied
if [[ "$CURRENT_PHASE" == "phase_1" && "$PAPER_COUNT" -ge "$REQUIRED_PAPERS" && "$READ_COUNT" -ge "$REQUIRED_PAPERS" ]]; then
  echo "phase_2" > "$STATE_FILE"
  log_hook "advance:phase_1->phase_2"
fi

# --- Phase transitions on git commands ---
if [[ "$TOOL_NAME" == "Bash" ]]; then
  # git commit → phase_3
  if echo "$TOOL_CONTENT" | grep -qE "^git commit|&& git commit|; git commit"; then
    echo "phase_3" > "$STATE_FILE"
    log_hook "advance:commit->phase_3"
  fi

  # git revert → reset to phase_1, new iteration
  if echo "$TOOL_CONTENT" | grep -qE "^git revert|&& git revert|; git revert"; then
    NEXT=$((CURRENT_ITER + 1))
    echo "$NEXT" > "$ITER_FILE"
    echo "phase_1" > "$STATE_FILE"
    mkdir -p "${REPORT_DIR}/papers/iter_${NEXT}"
    log_hook "reset:revert->iter_${NEXT}"
    inject "PHASE GATE: Reverted. Iteration ${NEXT}. Download ${REQUIRED_PAPERS} NEW papers to report/papers/iter_${NEXT}/ before next attempt."
    exit 0
  fi

  # eval_paired → gate running
  if echo "$TOOL_CONTENT" | grep -qE "bash.*eval_paired"; then
    echo "phase_gate_running" > "$STATE_FILE"
    log_hook "advance:gate_running"
  fi
fi

# --- Keep detection: agent reads eval summary containing "keep" ---
if [[ "$TOOL_NAME" == "Bash" ]] && echo "$TOOL_CONTENT" | grep -qE "cat.*/tmp/eval_.*summary|python3.*eval_.*summary"; then
  TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty')
  if echo "$TOOL_OUTPUT" | grep -qE '"decision"[[:space:]]*:[[:space:]]*"keep"'; then
    NEXT=$((CURRENT_ITER + 1))
    echo "$NEXT" > "$ITER_FILE"
    echo "phase_0" > "$STATE_FILE"
    mkdir -p "${REPORT_DIR}/papers/iter_${NEXT}"
    log_hook "keep->iter_${NEXT}"
    inject "PHASE GATE: Keep confirmed. Iteration ${NEXT}. Re-profile (Phase 0) then read ${REQUIRED_PAPERS} new papers (Phase 1)."
    exit 0
  fi
fi

# --- Plateau detection: only on Write to .md files ---
if [[ "$TOOL_NAME" == "Write" ]] && echo "$TOOL_CONTENT" | grep -qE "\.md "; then
  if echo "$TOOL_CONTENT" | grep -qiE "plateau|search space.*exhausted|optimization.*ceiling|no further.*improvement"; then
    log_hook "plateau_detected"
    inject "PHASE GATE: Plateau language detected. This requires human confirmation. List 10 unexplored research directions — if you can name them, return to Phase 1."
    exit 0
  fi
fi

exit 0
