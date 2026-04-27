# Experiment Template

Copy this folder to start a new experiment:

```bash
cp -r experiment_logs/template experiment_logs/<project>/<experiment_name>
```

Then fill in `program.md` with experiment-specific details.

## Files

| File | Purpose | When to create |
|------|---------|---------------|
| `program.md` | Agent instructions — the experiment definition | Before starting |
| `iters.tsv` | Iteration log — append one row per iteration | During experiment |
| `reproduce_*.sh` | Reproduction scripts for notable iterations | After keeps |

## iters.tsv Columns

The header row is a minimum — add experiment-specific columns as needed (e.g., `stage1_iai_delta` for two-tier gating).

| Column | Required | Description |
|--------|----------|-------------|
| `iter` | Yes | Iteration number (1-indexed) |
| `delta_pct` | Yes | Performance delta (negative = faster, positive = slower) |
| `gate_decision` | Yes | Gate outcome: KEEP, FAIL, SKIP |
| `base_hash` | Yes | Baseline commit (short hash) |
| `cand_hash` | Yes | Candidate commit (short hash) |
| `status` | Yes | Final decision: `keep`, `discard_wallclock`, `discard_iai`, `discard_correctness` |
| `files_changed` | Yes | Comma-separated list of modified files |
| `rationale` | Yes | One-line summary: what was tried and why it was kept/discarded |
