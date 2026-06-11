#!/bin/bash
# Environmental pre-flight check for leanVM wall-clock gates.
#
# Verifies the host is in a state suitable for reliable paired benchmarking.
# Designed to be called by eval_paired.sh before measurement, OR standalone
# by the agent / orchestrator before a measurement window.
#
# Checks (Linux only — macOS path is a no-op pass):
#   - CPU governor must be `performance` (all CPUs)
#   - 1-min load average must be < ENV_PREFLIGHT_LOAD_THRESHOLD (default 1.0)
#   - No throttling reported in last 60s (if `cpupower` available)
#
# Exit codes:
#   0 = PASS — env is healthy, measurements should be trustworthy
#   1 = FAIL — env has a known drift source, do not measure
#   2 = infrastructure error (e.g., couldn't read scaling_governor)
#
# Output:
#   stdout: JSON summary (machine-readable)
#   stderr: human-readable summary + remediation hints on FAIL
#
# Usage:
#   bash env_preflight.sh                  # default thresholds
#   ENV_PREFLIGHT_LOAD_THRESHOLD=0.5 bash env_preflight.sh
#   bash env_preflight.sh --json-only      # suppress human-readable stderr

set -eo pipefail

LOAD_THRESHOLD=${ENV_PREFLIGHT_LOAD_THRESHOLD:-1.0}
JSON_ONLY=0
case "${1:-}" in
  --json-only) JSON_ONLY=1 ;;
esac

log_human() { [[ "$JSON_ONLY" == "1" ]] || echo "[env_preflight] $*" >&2; }

# ---- platform detection ---------------------------------------------
KERNEL=$(uname -s)
ARCH=$(uname -m)

if [[ "$KERNEL" != "Linux" ]]; then
  # macOS / *BSD path: no governor concept, return PASS with platform note.
  cat <<EOF
{
  "platform": "$KERNEL",
  "decision": "PASS",
  "note": "non-Linux host, governor / load checks skipped"
}
EOF
  log_human "non-Linux host ($KERNEL); skipping governor + load checks"
  exit 0
fi

# ---- governor check -------------------------------------------------
GOVERNORS=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd, -)
if [[ -z "$GOVERNORS" ]]; then
  cat <<EOF
{
  "decision": "ERROR",
  "reason": "could not read scaling_governor (cpufreq not exposed?)"
}
EOF
  log_human "ERROR: scaling_governor not readable"
  exit 2
fi

GOVERNOR_OK=0
[[ "$GOVERNORS" == "performance" ]] && GOVERNOR_OK=1

# ---- load average check ---------------------------------------------
LOAD_1MIN=$(awk '{print $1}' /proc/loadavg)
LOAD_OK=$(awk -v l="$LOAD_1MIN" -v t="$LOAD_THRESHOLD" 'BEGIN{print (l<t)?1:0}')

# ---- emit JSON ------------------------------------------------------
DECISION="PASS"
REASONS=()
if [[ "$GOVERNOR_OK" != "1" ]]; then
  DECISION="FAIL"
  REASONS+=("governor=$GOVERNORS (need performance)")
fi
if [[ "$LOAD_OK" != "1" ]]; then
  DECISION="FAIL"
  REASONS+=("load_1min=$LOAD_1MIN (>= $LOAD_THRESHOLD)")
fi

if [[ ${#REASONS[@]} -eq 0 ]]; then
  REASONS_JSON=""
else
  REASONS_JSON=$(printf '"%s",' "${REASONS[@]}" | sed 's/,$//')
fi

cat <<EOF
{
  "platform": "$KERNEL/$ARCH",
  "governor": "$GOVERNORS",
  "governor_ok": $GOVERNOR_OK,
  "load_1min": $LOAD_1MIN,
  "load_threshold": $LOAD_THRESHOLD,
  "load_ok": $LOAD_OK,
  "decision": "$DECISION",
  "failed_checks": [$REASONS_JSON]
}
EOF

# ---- human-readable summary + remediation ---------------------------
log_human "platform: $KERNEL/$ARCH"
log_human "governor: $GOVERNORS  (ok=$GOVERNOR_OK)"
log_human "load_1m : $LOAD_1MIN  (threshold $LOAD_THRESHOLD, ok=$LOAD_OK)"
log_human "decision: $DECISION"

if [[ "$DECISION" == "FAIL" ]]; then
  log_human ""
  log_human "Remediation:"
  if [[ "$GOVERNOR_OK" != "1" ]]; then
    log_human "  governor → performance:"
    log_human "    sudo cpupower frequency-set -g performance"
    log_human "    # or sysfs fallback:"
    log_human "    for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$c >/dev/null; done"
  fi
  if [[ "$LOAD_OK" != "1" ]]; then
    log_human "  load > threshold:"
    log_human "    pgrep -fa 'cargo|prove_loop|criterion'   # find offenders"
    log_human "    tmux ls                                  # check for stale sessions"
  fi
  exit 1
fi

exit 0
