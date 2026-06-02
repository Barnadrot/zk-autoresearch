# Author personas — dispatch contract

`brain-author-*` is a family of specialist personas that write `program.md` (and companion files) for each experiment class. They exist so main brain stays focused on research + brainstorming and doesn't load the full template + repo conventions into context every time we dispatch a new experiment.

## Why this family exists

Problem statements addressed (from the brain infra sum-up):

- **P14 — Main brain context contamination from per-experiment authoring.** Writing a new bug_hunter program.md pulls in the full standard-form template, repo conventions, hot-symbol numbers, recent verdicts — all of which then sit in main brain's context bleeding into the next strategic discussion.
- **P15 — Standard-form drift.** Sections that should be verbatim mutate session-over-session because main brain paraphrases from memory. Author personas with the template as a required input catch this.
- **P16 — Per-repo fact fabrication.** Main brain has all repos in context and mixes file paths / baseline commits between them. Repo-specific authors only see one repo's context bundle — can't cross-contaminate.
- **P17 — No parallel authoring.** Main brain authoring 3 bug hunters in sequence pollutes its context. Separate authors allow main brain to dispatch in parallel cleanly.

## Personas

| Persona | Class | Writes | Reads |
|---|---|---|---|
| `brain-author-bug-hunter` | Bug hunting (Shape A) | `program.md` (single file) | own persona + repo_context/<repo>.md + canonical bug_hunter_4 template + most recent prior hunt |
| `brain-author-profiler` | Profiling (Shape B) | `program.md` (+ optional report scaffold) | own persona + repo_context/<repo>.md + closest prior profiler |
| `brain-author-optimization` | Optimization loop (Shape A) | `program.md` + `context.md` + `profiling.md` (3-file split) | own persona + repo_context/<repo>.md + pw4_2 canonical 3-file design |

Each persona file is self-contained. It describes role / required reads / output contract / verbatim sections / variable sections / HARD RULES / return format.

## Repo context bundles

`brain_example/repo_context/<repo>.md` files carry the mutable repo facts: hot symbols, baseline commit, gate script paths, build commands, known-no-go's, integrations. Author personas read the relevant bundle to ground their output.

Live copies at `brain/repo_context/<repo>.md` (gitignored) — the public scaffolding here is the template + baseline content.

Update protocol: bundles are updated whenever a new profiling baseline lands or a known-no-go shifts. Edit the bundle directly + commit. Bundles ARE the source of truth for "what the target repo looks like right now."

Current bundles:
- `leanvm.md` — leanVM XMSS aggregation prover
- `plonky3.md` — Plonky3 ZK proving framework
- `zkalloc.md` — zk-alloc arena allocator crate

(Jolt, SP1, Miden VM bundles are TODO — add when those become active targets.)

## Dispatch pattern

Main brain invokes an author via the Agent tool. Standard form:

```
Agent(
  description: "<one-line task>",
  subagent_type: "general-purpose",       # author personas not registered as subagent types
  model: "opus",                           # PIN THIS — never inherit
  prompt: <full persona file contents> + "\n\n" +
          "## This invocation\n" +
          "Repo: <leanvm | plonky3 | zkalloc>\n" +
          "Experiment dir: <absolute path>\n" +
          "Focus: <one paragraph of what this experiment is about>\n" +
          "Hardware: <hetzner-ax42u | m2-asahi | m4m-macos | etc.>\n" +
          "Other instance-specific parameters (gate config, stop criterion override, etc.)\n"
)
```

The persona file IS the prompt body. The "This invocation" section at the bottom is the only thing that varies per dispatch.

## Scope rules (apply to ALL author personas)

These rules are universal. Individual persona files DO NOT need to restate them but DO need to enforce them in output:

1. **Authors write files, not commits.** The author writes program.md (and companions) to the experiment dir. The author does NOT `git add` or `git commit`. Main brain reviews + commits.
2. **No source modification.** Authors do not touch target-repo source. Their output describes what an experiment AGENT will do — they don't do it themselves.
3. **No bench runs.** Authors don't measure. If a baseline number is needed and not in the repo_context bundle, the author flags it as `[NEEDS BASELINE]` for main brain to source.
4. **No exploration beyond required reads.** Authors stay within their required-reads list. If a key fact is missing, they flag it — they don't go hunting.
5. **Return = file paths + summary, not the file contents.** The author returns "Wrote X to <path>. Variable section: <focus>. Open questions: <list>." Main brain reads the actual file to review.
6. **Model pinned to opus.** Authoring quality matters; never inherit a downgraded model.

## What authors are NOT for

- **Research synthesis** (candidate surfacing, adversarial review, paper surveys) → use `brain-deep`
- **Portfolio coordination** (queue management, dispatch decisions) → use `brain-portfolio`
- **Live experiment monitoring** → coordinator persona, not author

Authors fill templates. brain-deep reasons. brain-portfolio coordinates. Keep distinct.

## When NOT to use an author persona

- **Single-iteration ad-hoc scripts.** If you're writing a 30-line program.md for a one-off measurement, the dispatch overhead exceeds the savings.
- **Heavily novel experiment shapes.** If the experiment doesn't fit bug_hunter / profiler / optimization, write it manually in main brain rather than forcing the persona.
- **Edits to existing program.md.** Authors create. Edits to a live experiment's program.md should be surgical and done in main brain.

## Frontmatter `model:` field

All three author personas declare `model: sonnet` in YAML frontmatter. This matches the existing brain-deep / brain-portfolio convention. **The Agent-tool invocation should override this with `model: "opus"`** when authoring quality matters (most cases). The frontmatter sonnet declaration is the fallback if no override is passed; the explicit override in the dispatch is the operational expectation.

Rationale: brain-deep / brain-portfolio defaulting to sonnet is a cost optimization for routine work; author personas are similarly routine BUT main brain should pin opus explicitly to avoid accidental sonnet downgrade on a load-bearing program.md.
