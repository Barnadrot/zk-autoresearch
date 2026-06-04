# Phase Gate Hooks

Enforces the Automated Research Methodology phases on executor agents.

## How it works

The hook receives JSON on stdin (tool_name, tool_input, tool_output) from
Claude Code's PostToolUse event. Returns JSON with `additionalContext` to
inject messages into the agent's context. Exit 0 = proceed, exit 2 = block.

### Paper tracking

Papers are saved to `<experiment_dir>/report/papers/iter_<N>/`. Each
iteration gets its own folder. The hook enforces TWO conditions:
1. PDFs exist on disk (downloaded)
2. PDFs were Read by the agent (tracked in `.papers_read` log)

Both must reach the threshold (default 10) before Phase 2 unlocks.

### State machine

```
phase_0 (profiling) ──[profiling artifacts in report/]──> phase_1
phase_1 (research)  ──[10+ PDFs downloaded AND read]────> phase_2
phase_2 (implement) ──[git commit]──────────────────────> phase_3
phase_3 (gate)      ──[eval_paired]─────────────────────> phase_gate_running

On keep:  iter N+1, phase_0, new papers/iter_{N+1}/ folder
On revert: iter N+1, phase_1, new papers/iter_{N+1}/ folder
```

### What each gate enforces

| Transition | Trigger | Blocked when | Message |
|------------|---------|-------------|---------|
| 0→1 | Write hypothesis_pool.yaml | No profiling artifacts in report/ | "Run profiling first" |
| 1→2 | git commit or source edit | PDFs < 10 OR Reads < 10 | "Download/read N more papers" |
| revert→1 | git revert | Always | "Download 10 NEW papers to iter_{N+1}/" |
| plateau | Write to .md file with plateau language | Pattern match | "List 10 unexplored directions" |

### Fixes from v1

- **JSON stdin** instead of env vars (matches Claude Code API)
- **additionalContext JSON output** instead of plain stdout (only way to inject into agent context from PostToolUse)
- **Read tracking** via `.papers_read` log — must download AND read papers
- **Git command detection** uses `^git commit` pattern to avoid matching echo/analysis text
- **Plateau detection** limited to Write on .md files, not all tool calls
- **Keep detection** reads tool_output from eval_paired summary, not tool_input
- **Hook logging** to `.hook_log` for audit trail
- **Active experiment marker** via `.active_experiment` file (avoids fragile dir scanning)

## State files (in experiment dir, gitignored via report/)

- `.phase_state` — current phase string
- `.current_iter` — iteration number (starts at 1)
- `.papers_read` — log of Read calls on PDF files (format: `iter_N:/path/to/paper.pdf`)
- `.hook_log` — audit trail of all hook decisions

## File structure

```
<experiment_dir>/
├── .phase_state          # "phase_0" | "phase_1" | "phase_2" | "phase_3"
├── .current_iter         # "1" | "2" | "3" | ...
├── .papers_read          # Read tracking log
├── .hook_log             # Hook audit trail
├── report/
│   ├── papers/
│   │   ├── iter_1/       # 10+ PDFs downloaded AND read
│   │   ├── iter_2/       # 10+ NEW PDFs after revert/keep
│   │   └── ...
│   ├── iter1_phase_0.md  # profiling output
│   └── ...
├── hypothesis_pool.yaml
├── iters.tsv
└── program.md
```

## Deployment

```bash
# On executor machine:
mkdir -p ~/zk-autoresearch/claude_hooks
scp claude_hooks/phase_gate.sh <host>:~/zk-autoresearch/claude_hooks/
chmod +x ~/zk-autoresearch/claude_hooks/phase_gate.sh
cp claude_hooks/settings_executor.json ~/zk-autoresearch/.claude/settings.json

# Optional: set active experiment explicitly
echo "/path/to/experiment_dir/" > ~/zk-autoresearch/.active_experiment
```

## Configuration

- `PHASE1_PAPER_MINIMUM` env var (default: 10)

## Disabling

```bash
echo '{}' > ~/zk-autoresearch/.claude/settings.json
```

## Upgrading to blocking mode

Change `exit 0` to `exit 2` on gate failure paths. When exit 2, stderr
becomes feedback to the agent. Currently non-blocking (prompt injection only)
to avoid bugs in untested state machine killing the experiment.
