# zk-autoresearch — Executor Agent Instructions

You are an agent dispatched to optimize or profile a ZK proving system. Your program.md defines the specific experiment. This file defines the rules that apply to ALL experiments.

## Git Protocol

Two experiment shapes; different git discipline for each.

### Shape A — Autoresearcher (commit-eval-decide loop)

1. **Find your branch.** Read your queue entry's `branch` field. Coordinator has already checked it out in the **target repo** (e.g., `~/zk-autoresearch/leanMultisig`), not in `~/zk-autoresearch` itself. Check with `cd <target_repo> && git rev-parse --abbrev-ref HEAD`.
2. **Never commit to `main` in the target repo.** If the target repo is on `main`, stop and report — something is wrong. The orchestration repo (`~/zk-autoresearch`) stays on `main` — that's normal, don't check it.
3. **Commit per iteration on the experiment branch.** Failed iterations get `git revert`, not `git reset`.
4. **Do NOT `git push`.** Brain pushes after reviewing.
5. **Leave Cargo.lock alone** unless the experiment explicitly tracks lockfile movement.

### Shape B — Profiling / measurement (read-only)

1. **Do not commit anything.** Stay on `main`, write your outputs as files in the experiment dir.
2. **Bulky raw data (>1 MB) goes in `report/`** subfolder of the experiment dir (gitignored, rsynced by coordinator).
3. **Do NOT `git push`.**


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

**Changing ANY WHIR parameter triggers self-referential bytecode recompilation cascade.** The recursion circuit hardcodes round counts.

### Memory model

Write-once: set(addr, val) asserts equality if addr already written. Merkle root verification uses copy_8(computed, expected) — fails if they differ.

### Bus protocol

bus_width = 16 field elements per tuple. Format: (data_0, ..., data_N, 0_padding, domain_sep).
Balanced: sum of push = sum of pull for every tuple. Proved via LogUp-GKR.

### Recursion circuit

Python zkDSL in `crates/rec_aggregation/zkdsl_implem/`. Compiled to bytecode via `compilation.rs`.
Self-referential: bytecode size must match the guess (recompiles iteratively).
**All WHIR/GKR parameters are hardcoded as Python constants — changing them changes bytecode size. Any change to column counts, WHIR params, or GKR depth cascades through recursion circuit compilation.**

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
