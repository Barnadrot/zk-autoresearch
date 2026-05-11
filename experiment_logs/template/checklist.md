# program.md Pre-Launch Checklist

## Content Checks

1. **Role** — Descriptive, not buzzwords. Name the specific domains (e.g., "Poseidon hash functions, Merkle tree commitment schemes, WHIR polynomial commitment") not generic traits ("expert, high-performance").

2. **Scope matches title** — If the experiment is "Poseidon + WHIR", every surface, file, and dead end must be from that path. Don't leak adjacent systems (sumcheck, AIR) into scope.

3. **Writable files cover the full path** — Trace the call chain from entry point to leaf function. Every file touched by that path should be writable. Check: could the agent implement the most ambitious structural change (e.g., arity change) without hitting an off-limits file?

4. **One profiling table, full system** — Show every component with % e2e, explored status, and notes. Mark out-of-scope items inline ("out of scope") rather than splitting into separate tables. Let the agent see the whole picture.

5. **Dead ends explain WHY, not just WHAT** — Each dead end includes the mechanism of failure, not just the outcome. "Batch interleaving fails because register file saturated" vs "batch interleaving didn't work."

6. **Restrictions in one place** — "What this experiment is NOT" section only. Don't repeat restrictions in scope section, target files, and scope rules.

7. **Profiling commands tested and working** — Commands should handle recompilation (find binary by timestamp, not hardcoded hash). Verified on the actual machine before launch.

8. **No contradictions** — Read the full document and check: does any section contradict another? (e.g., "structural changes in scope" but writable files don't include files needed for structural changes)

9. **Branch state is clean** — Branch reset to baseline on both local and remote before launch. No leftover commits from prior runs.

## Anti-Anchoring Checks

These prevent the agent from falling into micro-optimization loops. Failure on ANY of these
means the program.md will produce an agent that tunes constants for 12 iterations then stops.

10. **No suggestion list.** The program.md must NOT contain a bulleted list of "directions worth
    considering" or "things to try." This is the #1 cause of agent anchoring — the agent treats
    suggestions as a task list and works through them sequentially, ignoring profiling data.
    Replace with research principles and profiling data. The agent forms its own hypotheses.

11. **Iteration loop has magnitude prediction.** The eval loop MUST require the agent to predict
    Δ% and classify changes as micro/medium/structural BEFORE implementing. Without this, the
    agent defaults to micro-changes because they're safe and fast. The prediction forces the
    agent to think about expected value, not just iteration throughput.

12. **Multi-iteration arcs are supported.** The eval loop MUST have a WIP status for structural
    changes that span multiple commits. If every iteration must independently pass the perf
    gate, structural work (which needs 3-5 commits to become measurable) is structurally
    impossible. The agent will never attempt it.

13. **Post-keep lever switching is required.** After a keep, the agent MUST re-profile and switch
    targets. Without this, agents exploit the first lever they find (e.g., tune rayon thresholds
    5 times in a row with diminishing returns). The re-profile catches the shifted bottleneck.

14. **Change-scale expectations match the bottleneck.** If the top hotspot is 30% of e2e, the
    program.md should explicitly state that medium/structural approaches are expected. If the
    program says "one change, as small as possible" without qualification, the agent will never
    attempt a 200-LoC restructuring even when that's the only viable path.

15. **Stop criterion distinguishes ambition levels.** 12 micro-discards and 12 structural-discards
    are completely different outcomes. The stop criterion MUST weight by change scale — structural
    attempts that fail teach more and should count less toward the stop counter. Otherwise the
    agent learns: "ambitious attempts waste my stop budget" and converges on micro-tweaks.

## Infrastructure Checks

16. **Session ID recorded.** Immediately after launch, find the real session UUID and add it to
    `brain/report/sessions.json` with resume commands. Without this, the session is unrecoverable.

17. **Eval gate config propagates.** Verify that `config.env` values actually reach all subprocess
    scripts. Run: `bash -x eval_gate.sh 2>&1 | grep IAI_MAX_REGR` to confirm. (Fixed in
    framework-v2: eval_iai.sh now sources config.env directly.)

18. **iters.tsv header matches.** The TSV header in the program.md must match the actual iters.tsv
    file. Mismatches break `watch.py` monitoring.
