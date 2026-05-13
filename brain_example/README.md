# brain_example/

Public template scaffolding for the brain-driven multi-agent architecture used by zk-autoresearch. **The live `brain/` tree is gitignored** because it holds session UUIDs, RC URLs, executor SSH targets, and persona layout — all of which become attack surface if an agent runtime is ever exploited for prompt injection.

This folder is what stays public. Copy to `brain/` in your own checkout, fill in real values, customize.

## What this implements

A three-tier agent architecture:

```
                       user
                        ↕
                      brain                   ← long-lived Claude session, architect role
                  ┌───┬─┴─┬───┐
                  │   │   │   │
        brain-deep   brain-author-*   brain-portfolio   ← specialist personas (Agent tool)
        (research    (program.md      (weekly cross-
         synthesis,   authoring,       experiment
         ad-hoc       template-        review)
         profiling,   driven,
         surveys)     per-type)
                  │   │   │   │
                  ▼   ▼   ▼   ▼
                  coordinator                 ← long-lived Claude session, state machine
                       ↕
              ┌────────┴────────┐
              ▼                 ▼
         queue/<state>/   executors (rented hardware)
         (sharded JSON)   (one Claude per experiment)
```

Specialist personas split by JOB SHAPE:
- **brain-deep** — open-ended one-shot reasoning (candidate surveys, adversarial review, ad-hoc profiling). The answer isn't a template fill.
- **brain-author-{bug-hunter, profiler, optimization}** — template-driven program.md authoring. The structure is fixed; only the variable section changes per dispatch. Read `agents/AUTHORS.md` for the dispatch contract.
- **brain-portfolio** — weekly cross-experiment review.

The split keeps brain free of operational bookkeeping (which executor has capacity, what's stalled, what PR is open) — coordinator handles all that and escalates ambiguous cases back to brain via `queue/needs-decision/`. Brain never has to remember; it reads queue state at the start of every conversation turn.

## Why methodology, not state, is the public surface

Once you're running this, your `brain/queue/`, `brain/state/`, and `coordinator/` directories accumulate:

- **Session UUIDs** — stable resume targets. Combined with workspace access, can be hijacked.
- **RC URLs** — `https://claude.ai/code/session_<id>`. Auth-gated, but still attack targets.
- **Executor host strings** — `user@<host>:<port>`. Direct attack surface for credential-stuffing, known-CVE scanning, etc.
- **Persona files** — describe the system's reasoning shape in detail. Aid an attacker in mapping where to inject context.

None of these belong in a public git history. They're operational state, not methodology.

The methodology — *how the architecture works*, what role each persona plays, how the queue lifecycle progresses, what hard rules brain follows — is in this folder.

## Files in this template

```
brain_example/
├── README.md                       # this file
├── program.md                      # brain's prompt (the architect role)
├── agents/
│   ├── AUTHORS.md                  # dispatch contract for the brain-author-* family
│   ├── brain-deep.md               # one-shot research synthesis + ad-hoc profiling
│   ├── brain-portfolio.md          # weekly cross-experiment review
│   ├── brain-author-bug-hunter.md  # template-driven program.md for bug-hunting experiments
│   ├── brain-author-profiler.md    # template-driven program.md for profiling experiments
│   └── brain-author-optimization.md # template-driven 3-file design for optimization loops
├── repo_context/
│   ├── leanmultisig.md             # hot symbols, baseline, gate, known-no-go's
│   ├── plonky3.md                  # subsystems, bench bins, bug-class patterns
│   └── zkalloc.md                  # API, platform results, integrations
├── coordinator/
│   ├── program.md                  # coordinator's persistent session prompt
│   └── settings.json               # coordinator's tool scope (Read-heavy, write-stingy)
├── queue/
│   └── README.md                   # sharded queue convention
└── state/
    ├── executors.json.example      # placeholder per-machine capacity table
    ├── sessions.json.example       # empty sessions array
    └── coordinator-mode.flag       # "observe-only" by default; flip to "dispatching" once validated
```

## Bootstrap your own fork

1. Copy `brain_example/` → `brain/` in your checkout.
2. Fill `brain/state/executors.json` with your real SSH hosts and slot counts.
3. Configure `~/.claude/agents/` from `brain_example/agents/` (these are workspace personas; same files apply).
4. Launch the coordinator session:
   ```bash
   tmux new-session -d -s coordinator -c <repo>/coordinator
   tmux send-keys -t coordinator 'claude --dangerously-skip-permissions --remote-control coordinator' Enter
   sleep 5
   tmux send-keys -t coordinator 'Read coordinator/program.md and begin operating per its instructions.' Enter
   ```
5. Coordinator launches in `observe-only` mode by default. Validate one experiment end-to-end, then flip `brain/state/coordinator-mode.flag` to `dispatching`.

## Operational rules — read these first

These come from observed friction in the live system (the live retrospective is private). They generalize:

- **Never use `Bash sleep <long>` for pacing.** The Claude Code harness blocks long leading sleeps. Use `Monitor` tool with an `until <state-change-check>; do sleep N; done` script.
- **Coordinator escalates to brain via `queue/needs-decision/` files, never `PushNotification`.** Brain reads at start of every turn, resolves autonomously where possible, escalates to user only when needed.
- **Coordinator NEVER composes PR body text.** Experiment agents draft `pr_body.md` in their experiment dir before tearing down. Brain reviews and submits.
- **Mid-flight redirects flow user → brain → executor.** Coordinator does not relay user prompts to running executors.
- **Write surface is small for everyone.** Coordinator writes only on confirmed state transitions. Brain.portfolio writes only `portfolio.md`. brain.deep writes only its single artifact per invocation. Brain.triage (if you add it) writes only the brainstorm capture file.
- **Linger must be enabled on executors** (Asahi Fedora, some Ubuntu). `loginctl enable-linger <user>` — without it, the user-slice dies when the last SSH session closes, and detached tmux goes with it.
- **PRETOUCH / large memory optimizations must be `MemTotal`-adaptive**, not absolute. A 14 GiB pre-touched arena win on a 64 GiB host OOM-kills the entire user session on a 16 GiB host. Cap by `MemTotal / N_slabs / 3` with headroom for the rest of the user-slice.

## What's NOT in this template

- The architectural rationale docs (audit, proposed_architecture, feedback, retrospectives) — those live in the private `brain/report/` of the operating fork.
- Live agent memory (`~/.claude/projects/<...>/memory/*.md`) — always outside the repo entirely.
- Per-experiment iteration logs (`experiment_logs/<project>/<experiment>/iters.tsv`) — those are public in `experiment_logs/` since they're scientific record, but the *meta-state* (queue position, dispatch status) is private.

## Provenance

This template was extracted from the live brain configuration on 2026-05-11 as part of the brain-coordinator rearchitecting work. The live config retains the same shape but with real UUIDs/hosts. Periodically re-extract templates when the live config's shape changes.
