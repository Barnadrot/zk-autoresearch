# Design: mechanism_inventory.md as Phase 1 artifact

## What it replaces

The current paper-count hook checks `report/papers/iter_N/*.pdf >= 10`. This counts files, not understanding. An agent can download 10 PDFs, skim abstracts, and extract one idea — the count is satisfied but the combination space is empty.

mechanism_inventory.md replaces the paper count with a primitive count. Each paper decomposes into typed primitives. The hook counts inventory entries, not files.

## Schema

```yaml
# report/mechanism_inventory.md (append-only across iterations)

primitives:
  - id: p1
    name: univariate-skip
    source: "Gruen 2024/108 §5-6"
    mechanism: >
      Replace first k sumcheck rounds with one univariate round over
      integer window D={0..2^k-1}. Column evals stay base-field.
    cost_model: >
      Saves (2^k - 1) EF-rounds at C_EF each. Adds one degree-d*(2^k-1)
      polynomial eval + Lagrange interpolation. Net: k*C_EF - C_interp.
    assumptions:
      pcs: any  # works with FRI, WHIR, KZG
      field: any  # field-agnostic
      arch: any  # no SIMD dependency
      extension_degree: ">= 2"  # needs EF for Schwartz-Zippel
    soundness_cost: "+(d*(2^k-1))/|EF| per skip round (Appendix A.4)"
    composable_with: [split-eq, front-loaded-batching, fd-stepping]
    status: used  # used | available | closed
    used_in: h1  # links to hypothesis pool
    iter_added: 1

  - id: p2
    name: fd-stepping
    source: "Gruen 2024/108 §5, finite-difference extension"
    mechanism: >
      Evaluate skip polynomial via forward differences instead of
      Lagrange dots. O(d) adds per node vs O(d) muls.
    cost_model: >
      Replaces d muls with d adds per window node. Speedup ~1.7x on
      the skip kernel (arch-dependent: add/mul throughput ratio).
    assumptions:
      pcs: any
      field: any
      arch: "mul-bound (add << mul throughput)"
    soundness_cost: none  # prover-only optimization
    composable_with: [univariate-skip]
    status: used
    used_in: h4
    iter_added: 2

  - id: p3
    name: power-circuit-squaring
    source: "Soukhanov 2023/1611 Example 2"
    mechanism: >
      Replace a*b with (a+b)^2 - a^2 - b^2 in GKR layer sumchecks.
      Reduces degree from 3 to 2, saves one eval point per round.
    cost_model: >
      Layer sumcheck: -33% evals. But squaring cost is arch-dependent:
      rho_sq = sq_cost / mul_cost. Need rho_sq < 0.67 to break even.
    assumptions:
      pcs: any
      field: any
      arch: "rho_sq < 0.67 (FAILS on Zen4 AVX-512: rho_sq = 1.75)"
    soundness_cost: "-1 EF/round transcript (size credit)"
    composable_with: [logup-gkr]
    status: closed  # rho_sq measured at 2.55 on target hardware
    closed_reason: "h9 kill-gate: quintic squaring 2.55x slower than mul"
    iter_added: 4

  - id: p4
    name: block-memory-lookups
    source: "Haböck 2022/1530 (logUp tuple fingerprinting)"
    mechanism: >
      Batch consecutive memory lookups into block-4 tuples. Reduces
      bus entries per Poseidon row from 32 to 8.
    cost_model: >
      LogUp data 19.7M -> 13.4M. GKR 218ms -> ~150ms. Bus constraints
      64 -> 18 per Poseidon row.
    assumptions:
      pcs: any
      field: any
      arch: any
      requires: "4-aligned operand pointers in guest allocator"
    soundness_cost: none
    composable_with: [logup-gkr, poseidon-air]
    status: closed
    closed_reason: "h3: 60-99% operand pointers unaligned; alignment retrofit = constraint 5"
    iter_added: 1

compositions:  # the novel constructs
  - id: c1
    name: front-loaded-univariate-skip
    composed_of: [p1, split-eq-existing]
    novel_contribution: >
      Front-loaded batching (all tables join round 0, drop out after n_t
      rounds) composes with univariate skip so the skip window covers every
      table's expensive early rounds. Neither paper describes this combination.
    used_in: h1
    iter_added: 1
```

## How the hook changes

Current `phase_gate.sh` counts PDFs:
```bash
PAPER_COUNT=$(find "$PAPERS_DIR" -name "*.pdf" -type f | wc -l)
```

New: count inventory primitives:
```bash
PRIMITIVE_COUNT=$(grep -c "^  - id:" "$EXPERIMENT_DIR/report/mechanism_inventory.md" 2>/dev/null || echo 0)
```

Threshold changes from 10 papers to 15 primitives (a good paper yields 2-4 primitives; 10 papers → 20-40 primitives, so 15 is a floor not a ceiling).

The hook fires on the same triggers (Write/Edit to leanVM/crates/, git commit) but checks primitive count instead of PDF count.

## What the hook message says

```
PHASE GATE: {count}/15 primitives in mechanism_inventory.md. You cannot
implement without decomposing at least 15 primitives from your paper reading.
Each paper should yield 2-4 typed primitives with: mechanism, cost_model,
assumptions (pcs/field/arch), soundness_cost, composable_with.
```

## Phase 1 flow change

Before:
1. Read 10 papers → extract 1 idea each → pick best → implement

After:
1. Read papers → decompose each into primitives → add to inventory
2. Review inventory for composition opportunities (composable_with links)
3. Build 3 hypotheses, at least 1 must be a composition (compositions section)
4. The inventory persists across iterations — it grows, never resets

## Key properties

- **Append-only across iterations.** iter_added tracks when each primitive entered. Closed primitives stay with their closed_reason — they're negative results, not deletions.
- **composable_with is the combination index.** The agent scans this field to find primitives that work together. Two primitives listing each other = candidate composition.
- **assumptions are typed.** An agent can grep for `arch: any` to find hardware-portable primitives, or `field: "64-bit"` for Goldilocks-specific ones. This prevents applying 31-bit-field tricks to Goldilocks.
- **status tracks lifecycle.** `available` → `used` (in a hypothesis) → `closed` (killed with evidence). The agent can't re-propose a closed primitive without addressing closed_reason.
- **The hook counts primitives, not papers.** Papers in /tmp/ are fine — the inventory is what matters. This solves the paper-path problem without changing curl behavior.

## What this does NOT do

- Does not replace the hypothesis pool. The pool is still 3 entries with predicted_pct, plumbing, kill_condition. The inventory feeds the pool.
- Does not require every primitive to be used. Most primitives will be `available` — they're the search space.
- Does not force composition on every iteration. The pool schema rule (design idea #2) handles that separately.

## Integration with pool schema (#2)

Add to hypothesis_pool.yaml required fields:
```yaml
  - id: h10
    primitives: [p1, p5, p12]  # links to inventory
    composition_of: [p5, p12]  # if this is a novel combination
    novel_claim: >
      Combining X with Y produces Z, which neither paper describes.
      Specifically: [one sentence stating the novel construct].
```

Hook check: at least 1 of 3 pool entries must have `composition_of` with 2+ primitives.

## Integration with risk regime split (#3)

Add to program.md Phase 1:
```
Pool admission for composed ideas requires only the soundness sketch
and inventory-based cost math. Measured priors (W1 kill-gate) come
AFTER admission, not before. Do not kill a composition at triage
because its individual parts are sub-gate — the composition may clear.
```
