# leanMultisig — Poseidon1 Batch Interleaving Implementation

## Role
You are a low-level systems engineer implementing batch Poseidon1 permutation interleaving
for AVX-512 on Zen 4. You understand Montgomery multiplication latency, SIMD register
allocation, instruction-level parallelism, and how to read/verify compiler-generated assembly.

This is a focused implementation task with a clear hypothesis. You are NOT exploring
freely — you are implementing one specific optimization and measuring whether it works.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64GB RAM, AVX-512.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `exp6/batch-poseidon` (create from `exp5/poseidon1-stacked-pcs`) | Target |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` | Reference: study `permute_state_x2` pattern for Poseidon2 |

**Setup:**
```bash
cd ~/zk-autoresearch/leanMultisig
git checkout exp5/poseidon1-stacked-pcs
git checkout -b exp6/batch-poseidon
```

## The Hypothesis

Poseidon1 `permute_mut` is 30% of CPU with IPC=1.13. The bottleneck is instruction
dependency chains: each Montgomery multiply has 22-cycle latency, S-box chains two
dependent multiplies = ~44 cycle stall, 20 serial partial rounds = ~1000 cycles where
the pipeline is mostly empty.

**Fix:** Interleave two independent Poseidon states so that during state A's S-box stall,
the CPU executes state B's operations. This fills the pipeline gaps.

**Expected gain:** IPC from 1.13 → ~2.0 on Poseidon = ~40% Poseidon speedup = ~12% total.

**Reference:** Plonky3 upstream does this for Poseidon2 via `permute_state_x2` in
`poseidon2/src/`. Study that implementation.

## Iteration Budget: 5 Iterations Maximum

This experiment has a hard cap of 5 iterations. Each iteration is one attempt at making
batch interleaving work.

**Success:** Any iteration achieves ≥ -3% on the performance gate → hypothesis confirmed.
Continue refining within budget.

**Failure:** All 5 iterations fail or regress → hypothesis disproven. Log conclusion,
revert all changes, leave the branch clean for _3 to build on.

**Do not** pivot to other optimization targets. If batch interleaving doesn't work, stop.
A follow-up experiment (_3) will do open research.

## Implementation Plan

### Iter 1: Validate Preconditions

Before writing any optimization code:

1. **Confirm backend stalls dominate.**
   ```bash
   perf stat -e cycles,stalled-cycles-backend,stalled-cycles-frontend \
     ./target/release/deps/test_multisignatures-* test_type_1_aggregation --test-threads=1
   ```
   If backend stalls < 30% of cycles, the dependency chain hypothesis is wrong. Stop.

2. **Map the call sites.** Confirm the three monomorphizations:
   - 19.1% — initial Merkle commit (which `compress_layer` call?)
   - 5.6% — round Merkle commit
   - 5.2% — compiler bytecode hashing (`compile_to_low_level_bytecode`)
   
3. **Measure batch opportunity in `compress_layer`.** How many independent compress calls
   per `par_chunks_exact_mut` chunk? If chunks are size 1, there's nothing to pair.

4. **Check compiler path.** Is `compile_to_low_level_bytecode` called once (cached) or
   per-proof? If per-proof, caching alone saves 5.2%. Log finding.

Log all measurements. Commit nothing.

### Iter 2: Implement `permute_mut_x2`

Create a batch-of-2 variant that interleaves two independent Poseidon1 permutations:

```rust
fn permute_mut_x2(state_a: &mut [R; 16], state_b: &mut [R; 16]) { ... }
```

Interleave at the round level: state A's S-box → state B's S-box → state A's MDS →
state B's MDS → ... This gives the compiler maximum freedom to schedule instructions.

**Critical check:** After implementing, verify the generated assembly:
```bash
RUSTFLAGS="-C target-cpu=native" cargo asm --lib -p mt-koala-bear 'permute_mut_x2'
```
Count ZMM register usage. If > 32 registers referenced → spills → abort this approach.

### Iter 3: Integrate into `compress_layer`

Modify the Merkle tree `compress_layer` to use `permute_mut_x2` when processing pairs
of independent sibling compressions. The existing `par_chunks_exact_mut` loop processes
chunks — pair adjacent compress calls within each chunk.

Run correctness gate + performance gate.

### Iter 4-5: Refine or Fix

If iter 3 regresses: analyze why. Common failure modes:
- Register spills → try reducing state to 2×8 registers (half-width)
- LTO rearranges interleaving → try `#[inline(always)]` + `core::hint::black_box`
- Chunk sizes don't pair → adjust `par_chunks_exact_mut` chunk size to be even

If iter 3 improves but < -3%: try 3-wide interleaving (3 states, needs 48 registers →
likely spills, but worth checking if partial benefit at 2.5 states equivalent).

## Eval Gates

### Correctness Gate
```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-koala-bear -p mt-field -p mt-sumcheck -p mt-symetric --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-whir --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test --release --test test_multisignatures --quiet 2>&1
```

### Performance Gate
```bash
cd ~/zk-autoresearch
bash harness/leanmultisig/scripts/eval_paired.sh
```
Threshold: -0.5% with p < 0.05. Revert-A/B confirmation for keeps.

## Iteration Loop

1. Implement one step of the plan above.
2. `git commit`: `pw2-<iter>: <description>`
3. Run correctness gate. FAIL → `git revert HEAD`, log, move to next iter.
4. Run performance gate. `RUSTFLAGS="-C target-cpu=native"` always.
   - Gate passes → log as `keep`.
   - Gate fails → `git revert HEAD`, log as `discard`.
5. If iter 5 reached → stop regardless of outcome.

**Commit discipline:** Every change and revert gets its own commit. `git revert`, not reset.

**First build:** 10-15 minutes. Normal.

## Logging — `iters.tsv`

Append to `~/zk-autoresearch/experiment_logs/leanMultisig/experiment_poseidon_whir_2/iters.tsv`:
```
iter	tier2_criterion_pct	tier2_p	proof_kib	status	files_changed	rationale
```

## STOP AFTER 5 ITERATIONS
This is a bounded implementation experiment. After iter 5, stop and report your conclusion:
did batch interleaving work, and if not, why specifically?
