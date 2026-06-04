# zk-autoresearch — Executor Agent Instructions

You are an agent dispatched to optimize or profile a ZK proving system. Your program.md defines the specific experiment. This file defines the rules that apply to ALL experiments.

This is an unbounded automated researcher loop. All ideas that are calculated to work MUST be attemmpted, no matter the complexity of implementing it. You have an unlimited time and token budget. 

Speed is the enemy of results. **This is researcher work, requiring depth. More papers read = more depth** The gate mechanism IS NOT intended to quickly test ideas, it is the last gate to determine whether the implemented work can stay in the codebase.

The gate will measure the effect also on recursion time and proof size and discard ideas that decrease performance on those factors. Calculate the effects in advance and understand the trade-offs

## Git Protocol

Two experiment shapes; different git discipline for each.

### Shape A — Autoresearcher (commit-eval-decide loop)

1. **Find your branch.** Read your queue entry's `branch` field. Coordinator has already checked it out in the **target repo** (e.g., `~/zk-autoresearch/leanMultisig`), not in `~/zk-autoresearch` itself. Check with `cd <target_repo> && git rev-parse --abbrev-ref HEAD`.
2. **Never commit to `main` in the target repo.** If the target repo is on `main`, stop and report — something is wrong. The orchestration repo (`~/zk-autoresearch`) stays on `main` — that's normal, don't check it.
3. **Commit per iteration on the experiment branch.** Failed iterations get `git revert`, not `git reset`.
4. **Do NOT `git push`.** Brain pushes after reviewing.
5. **Leave Cargo.lock alone** unless the experiment explicitly tracks lockfile movement.
6. **NEVER STOP** Run autonomously until you reach your goal! Do not stop waiting for input! If you are stuck, think harder, search deeper for research papers, run profiling again, and review the inspiration repos. 

### Shape B — Profiling / measurement (read-only)

1. **Do not commit anything.** Stay on `main`, write your outputs as files in the experiment dir.
2. **Bulky raw data (>1 MB) goes in `report/`** subfolder of the experiment dir (gitignored, rsynced by coordinator).
3. **Do NOT `git push`.**

## Execution Discipline

- **One prove_loop at a time.** Before running prove_loop, check `pgrep prove_loop` — if any instance is running, wait for it to finish. Never background prove_loop or run it concurrently with builds.
- **Gate runs are sacred.** Never launch any compute work while eval_paired.sh is running. No cargo builds, no profiling, no background agents doing Bash. Finish all other work BEFORE starting the gate.
- **Debug with code, not math.** When debugging numerical correctness, write a test that prints expected vs actual values. Do not derive correctness symbolically in conversation — use the computer to compute.
- A **disproven mechanism** may not be reattempted under variant implementations. If the root cause is architectural (not implementation), the hypothesis family is closed.


---

## leanMultisig Reference

KoalaBear field: p = 2^31 - 2^24 + 1. Extension: F_q = F_p[X]/(X^5 + X^2 - 1), q = p^5.

### Tables

| Table | Committed cols | Degree | Max rows | Bus domain_sep |
|---|---|---|---|---|
| EXECUTION | 20 | 5 | 2^24 | push: (ν_A, ν_B, ν_C, 0_12, aux_2) with flag_precompile |
| POSEIDON | 101 | 9 | 2^21 | pull: odd ≥ 3, encoding = 3 + 2·permute + 4·half + 8·flag_left + 16·flag_left·offset |
| EXTENSION | 29 | 6 | 2^21 | pull: multiple of 4, encoding = 4·flag_be + 8·flag_add + 16·flag_dot_product + 32·flag_eq + 64·N |

### Poseidon16 column layout (101 cols)

9 control/flags + 16 inputs + 32 full-round intermediates (2 pairs × 16) + 20 partial-round S-box outputs + 16 final full-round + 8 outputs_left = 101. Virtual: ν_A (left pointer), aux_2 (precompute data).

### Stacked PCS

All table columns + memory_acc + bytecode_acc stacked into one polynomial of size 2^ν.
ν = ceil(log2(sum of all cells)). Crossing to ν+1 doubles DFT + Merkle + sumcheck cost. Before adding columns or rows, compute whether the change pushes total cells past the next power-of-2 boundary.

### WHIR

| Param | Description |
|---|---|
| Initial folding factor | First FRI folding step |
| Subsequent folding factor | Remaining FRI folding steps |
| log_inv_rate | Reed-Solomon rate parameter |
| Security bits | 124 (Johnson bound) |

**Changing WHIR parameters triggers bytecode recompilation in the recursion circuit. This is expected — budget for recompilation time and verify the circuit closes.**

### Memory model

Write-once: set(addr, val) asserts equality if addr already written. Merkle root verification uses copy_8(computed, expected) — fails if they differ.

### Bus protocol

bus_width = 16 field elements per tuple. Format: (data_0, ..., data_N, 0_padding, domain_sep).
Balanced: sum of push = sum of pull for every tuple. Proved via LogUp-GKR.

### Recursion circuit

Python zkDSL in `crates/rec_aggregation/zkdsl_implem/`. Compiled to bytecode via `compilation.rs`.
Self-referential: bytecode size must match the guess (recompiles iteratively).
WHIR/GKR parameters are hardcoded as Python constants — changing them changes bytecode size. Budget for recompilation time when modifying column counts, WHIR params, or GKR depth.

### ISA (6 instructions)

| Instruction | Encoding |
|---|---|
| ADD | aux_1 = 1 |
| MUL | flag_mul = 1 |
| DEREF | aux_1 = 2 |
| JUMP | flag_jump = 1 |
| POSEIDON_OP | aux_2 encodes mode |
| EXTENSION_OP | aux_2 encodes op+N |

### Key file map

| What | Where |
|---|---|
| Native Merkle | crates/whir/src/merkle.rs |
| Circuit Merkle verification | crates/rec_aggregation/zkdsl_implem/hashing.py, utils.py |
| XMSS protocol hashing | crates/rec_aggregation/zkdsl_implem/xmss_aggregate.py |
| Poseidon table AIR | crates/lean_vm/src/tables/poseidon_16/mod.rs |
| Table registration | crates/lean_vm/src/tables/table_enum.rs |
| Stacked PCS | crates/sub_protocols/src/stacked_pcs.rs |
| Recursion compilation | crates/rec_aggregation/src/compilation.rs |
| WHIR config | crates/lean_prover/src/lib.rs |
| prove_loop benchmark | harness/leanmultisig/bench/src/bin/prove_loop.rs |
| Correctness gate | harness/leanmultisig/correctness/correctness.sh |
