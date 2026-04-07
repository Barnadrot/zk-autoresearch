# Sonnet vs Claude — Improvement Ideas

Ideas observed during experiment runs for improving agent behavior.
Format: idea, which model/experiment it applies to, priority.

---

## CLAUDE.md / Prompt

- **Decision rule reframed: "identify 2–3 candidates, select most promising, implement even if uncertain"** — agent repeatedly analyzed ideas until finding a flaw, then discarded them in a loop. Old rule ("pick one and implement") didn't prevent circular exploration. New rule: once 2 ideas ruled out in a row, stop and implement next best. Benchmark resolves uncertainty, not more reasoning. Sonnet, experiment_2_dft.

- **Proven Techniques section pulls agent toward cold code** — reframe header: "already applied — read to avoid duplication, not to find targets." Agent (iter 1, 2) started by scanning proven techniques and applied pre-broadcast to `DifButterflyZeros` which is not in the hot path. Sonnet, experiment_2_dft.

- **Add `dit_layer_uniform` as near-miss anchor** — specialized first layer of `first_half_general` with single pre-broadcast twiddle. Rejected twice due to `debug_assert!` only, never benchmarked. Gives agent a concrete hot-path target instead of free-exploring. Sonnet, experiment_2_dft.

## loop.py

- **No open items yet**

---

## Observations

- Agent opening statement ("focusing on proven techniques and near misses") varies per-agent instance, not a systemic prompt issue.
- `DifButterflyZeros::apply_to_rows` pre-broadcast kept at +0.74%, p=0.03 — suggests it IS in the hot path somewhere (possibly `Radix2DFTSmallBatch` path called during benchmark warmup, or via a different code path than expected).
