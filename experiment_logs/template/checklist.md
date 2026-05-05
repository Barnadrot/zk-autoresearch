# program.md checklist

1. **Role** — Descriptive, not buzzwords. Name the specific domains (e.g., "Poseidon hash functions, Merkle tree commitment schemes, WHIR polynomial commitment") not generic traits ("expert, high-performance").

2. **Scope matches title** — If the experiment is "Poseidon + WHIR", every surface, file, and dead end must be from that path. Don't leak adjacent systems (sumcheck, AIR) into scope.

3. **Writable files cover the full path** — Trace the call chain from entry point to leaf function. Every file touched by that path should be writable. Check: could the agent implement the most ambitious structural change (e.g., arity change) without hitting an off-limits file?

4. **One profiling table, full system** — Show every component with % e2e, explored status, and notes. Mark out-of-scope items inline ("out of scope") rather than splitting into separate tables. Let the agent see the whole picture.

5. **Surfaces have concrete hypotheses with reasoning** — Not "investigate chunk sizing" but "compress_layer processes one tree level at a time with a barrier between levels. Fusing 2-3 bottom levels in one parallel pass changes the work-per-task ratio fundamentally." Each surface should explain what, why it might work, and rough LoC.

6. **No numbered priority list** — Surfaces as bullets, not ordered steps. Agent picks based on profiling data, not list position.

7. **Dead ends are from THIS experiment only** — Each dead end explains the mechanism (why it failed), not just the outcome. Don't import dead ends from other experiments on different code paths.

8. **Restrictions in one place** — "What this experiment is NOT" section only. Don't repeat restrictions in scope section, target files, and scope rules.

9. **Microbench is diagnostic, not gate** — "Microbench to aim, e2e gate to decide." Optional step, not a tier.

10. **Profiling commands tested and working** — Commands should handle recompilation (find binary by timestamp, not hardcoded hash). Verified on the actual machine before launch.

11. **No contradictions** — Read the full document and check: does any section contradict another? (e.g., "structural changes in scope" but writable files don't include files needed for structural changes)

12. **Branch state is clean** — Branch reset to baseline on both local and remote before launch. No leftover commits from prior runs.

13. **Surfaces guide, not prescribe** — Give the agent freedom to discover. A quick pre-run profile doesn't replace the agent's targeted research — it will develop a better sense of the codebase than you have from a 20-second perf run. List surfaces as starting points, not as the answer.
