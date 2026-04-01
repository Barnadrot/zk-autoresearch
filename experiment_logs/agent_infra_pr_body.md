## Summary

Infrastructure improvements accumulated across Experiment 3 (20 iterations).

**Reliability fixes**
- Retry on Anthropic 529 overloaded errors with exponential backoff (30s→60s→120s→240s)
- Fix retry scope: wrap full stream block including SSE iteration, not just connection setup
- Fix retry match: overload mid-stream arrives as HTTP 200 with error in SSE body — match on error string not status code

**Agent tooling**
- Add `get_assembly` tool for compiler codegen verification — agent now checks assembly before submitting changes that rely on compiler behavior
- Inject last reasoning into recovery prompt to prevent idea pivot on token budget hit
- Lower near-miss threshold to 0.5% to reduce borderline keeps

**Agent guidance (CLAUDE.md)**
- Remove extension nudge ("look for symmetric paths") — caused 4/5 iters after a kept improvement to be wasted on extensions
- Remove exhausted promising ideas section
- Add Round 3 dead ends: backwards flag extensions, first-two-layers fusion confirmed, ALU reordering flat
- Add dead end classification methodology: 1 attempt insufficient, need 3+ with different implementations before declaring dead end

**Experiment logging**
- Suppress `agent_thinking` from jsonl (full reasoning preserved in terminal log)
- Add iter_20_report.md: full Experiment 3 results, cost/token stats, behavioral analysis

## Notes

Benchmark results pending — running comprehensive multi-branch validation overnight before publishing numbers.
