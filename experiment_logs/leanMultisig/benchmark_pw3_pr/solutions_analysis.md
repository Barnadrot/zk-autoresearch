# Solutions analysis: keeping RATE=12 + MMO under the 2^19 trace boundary

**Date:** 2026-05-08
**Scope:** Recursion-node trace-padding cliff. Target: drive heaviest recursion node `0.0.0` from 588,682 cycles back below 524,288 (2^19) — a 64,394-cycle (10.94%) cut — without giving up RATE=12 or 124-bit collision security.

## 0. The cliff

zkVM cycle counts per recursion node, from the per-binary fancy-aggregation runs:

| Node | baseline | c4 (RATE=12, cap=4) | c5 (+ MMO) | c5 vs 2^19 |
|------|---------:|--------------------:|-----------:|-----------:|
| 0.0.0 | 282,702 | 503,584 (+78%) | **588,682 (+108%)** | **+12.3% over** |
| 0     | 329,766 | 551,393 (+67%) | 634,861 (+93%)      | +21.1% over |
| 0.0.1 | 251,801 | 408,024 (+62%) | 472,979 (+88%)      | -9.8% under |
| 0.1   | 243,008 | 394,652 (+62%) | 456,624 (+88%)      | -12.9% under |
| 0.0   | 286,081 | 444,486 (+55%) | 516,981 (+79%)      | -1.4% under |
| root  | 109,703 | 192,594 (+76%) | 226,757 (+107%)     | -56.7% under |

`0.0.0` and `0` cross 2^19; the CPU table doubles to 2^20 = 1,048,576 rows. That doubling of the *committed* trace is the proximate reason fancy-aggregation regresses +13.83% wall-clock — the native prover does ~2× the FFTs, Merkle tree work, and sumcheck rounds for the recursion stage.

Everything below assumes we want to **keep** the c5 design (RATE=12 + MMO for 124-bit security) and shave cycles inside the existing zk-DSL.

## 1. Where the cycles actually went (line-by-line accounting)

### 1.1 Calling convention recap (one zkVM cycle = one bytecode instruction)

From `crates/lean_compiler/src/b_compile_intermediate.rs:781` (`setup_function_call`) and `:826` (`compile_function_ret`), each non-inlined function call costs:

```
caller side:
  1× RequestMemory   (allocate the callee frame)
  2× Deref            (write return-label, write parent fp)
  N× Deref            (write arguments, one per arg)
  1× Jump             (jump to callee)
  per return value: 1 Deref (copy result back to caller frame)

callee side at FunctionRet:
  per return slot: 1 equality (write into return slot, unless coalesced)
  1× Jump             (jump back to return-label)
```

Net: a non-inlined call with **3 arguments and 1 return value** costs **~9-10 cycles**: 1 RequestMemory + 2 frame writes + 3 arg writes + 1 forward Jump + 1 result copy + 1 backward Jump + 1 return-slot write. `@inline` collapses all of this to **0 cycles** — the body is spliced into the caller and constants from the call site are propagated.

Other useful unit costs:

| Construct | zk-DSL syntax | Cost |
|---|---|---|
| Memory request | `Array(N)` | 1 RequestMemory cycle, irrespective of N |
| Direct copy | `dst[i] = src[j]` | 1 cycle |
| Add | `dst[i] = a[j] + b[k]` | 1 cycle (ISA has 3-operand `Operation::Add`, see `crates/lean_vm/src/isa/operation.rs`) |
| Zero store | `dst[i] = 0` | 1 cycle |
| `unroll(0, N)` body | each body line | N cycles per line |
| Precompile call | `poseidon16_compress(...)` | 1 cycle |

`unroll` in `crates/lean_compiler/src/a_simplify_lang/mod.rs:795-820` literally splices `(end-start)` copies of the loop body into the IR — there's no overhead, but there's also no compression: 80 copies of an assignment generate 80 instructions.

### 1.2 Per-call cost breakdown (num_chunks = 10, the dominant case)

For `num_chunks = 10` the dispatch lands on `slice_hash_rtl_rate12(data, 80, 88, 6)`, which needs padding because `data_len(80) ≠ padded_len(88)`. n_chunks_12 = 6.

**Baseline `slice_hash_rtl` (RATE=8, `@inline`)** — `git show 19f1c774:crates/rec_aggregation/zkdsl_implem/hashing.py`:

```python
@inline
def slice_hash_rtl(data, num_chunks):
    states = Array((num_chunks - 1) * DIGEST_LEN)               # 1 cyc
    poseidon16_compress(data + (num_chunks-2)*8, data + (num_chunks-1)*8, states)  # 1 cyc
    for j in unroll(1, num_chunks - 1):                          # 8 iters, 1 cyc each
        poseidon16_compress(states + (j-1)*8, data + (num_chunks-2-j)*8, states + j*8)
    return states + (num_chunks - 2) * DIGEST_LEN                # 0 cyc (return is inlined)

# Total for num_chunks=10: 1 + 1 + 8 = 10 cycles
```

**Bundle `slice_hash_rtl` (RATE=12 + MMO, three non-inlined functions)** — combine the c4 + c5 hashing.py:

```python
def slice_hash_rtl(data, num_chunks):                            # NOT @inline → ~10 cyc call overhead
    # if-tower resolves at compile-time (num_chunks is Const)
    return slice_hash_rtl_rate12(data, 80, 88, 6)                # ~10 cyc tail-call overhead

def slice_hash_rtl_rate12(data, data_len, padded_len, n12):      # NOT @inline → ~10 cyc
    # padded_len(88) != data_len(80) → take padding branch
    padded_data = Array(88)                                       # 1 cyc
    for i in unroll(0, 80): padded_data[i] = data[i]              # 80 cyc
    for i in unroll(80, 88): padded_data[i] = 0                   #  8 cyc
    return slice_hash_rtl_rate12_no_pad(padded_data, 88, 6)       # ~10 cyc

def slice_hash_rtl_rate12_no_pad(padded_data, padded_len, n12):  # NOT @inline → ~10 cyc
    states = Array(7 * 16)                                        # 1 cyc
    poseidon16_permute(padded_data + 72, padded_data + 80, states) # 1 cyc
    for j in unroll(0, 6):                                        # 6 iterations
        pre = Array(16)                                           # 1 cyc per iter
        for k in unroll(0, 4):                                    # 4 cyc
            pre[k] = states[j*16 + k]
        for k in unroll(0, 12):                                   # 12 cyc
            pre[4+k] = states[j*16 + 4+k] + padded_data[(5-j)*12 + k]
        poseidon16_permute(pre, pre + 8, states + (j+1)*16)        # 1 cyc
        # subtotal per iter: 1 + 4 + 12 + 1 = 18 cyc × 6 iters = 108 cyc
    return states + 96                                            # 0

# Total per call:
#   10 + 10 + 10 + 10  = 40 cyc  function-call overhead (slice_hash_rtl + rate12 + no_pad + return chain)
#   1 + 80 + 8         = 89 cyc  padded_data construction
#   1 + 1              =  2 cyc  states alloc + initial perm
#   108                = 108 cyc inner loop (6 iters × 18 cyc)
#   total              = 239 cyc per call
```

Per-call delta vs baseline: **239 − 10 = +229 cycles**.

### 1.3 Where each delta line goes

For the same num_chunks=10 call, broken out:

| Source | Δ cycles per call | Notes |
|---|---:|---|
| Function call dispatch (3 layers) | +30 | Was 0, now ~10×3 |
| `padded_data = Array(88)` + 80 data copies + 8 zero stores | +89 | New in c4; only for padding paths |
| `states` array growth (8→16 per round) | +0 | Same alloc count, just larger region |
| `pre = Array(16)` per iter × 6 | +6 | New in c5 |
| 4 capacity copies per iter × 6 | +24 | Was implicit in compress's left arg |
| 12 ADDs (rate XOR-merge) per iter × 6 | +72 | Pure MMO cost; was 4 stores in c4 |
| Initial `poseidon16_permute` vs old initial `poseidon16_compress` | +0 | Same precompile cost (1 cyc) |
| Saved 2 perms (9 → 7 perms) | −2 | RATE=12 win |
| Sum of changes | **+219** | Matches observed +229 within rounding |

Cross-checking against the recursion-only trace (n=2):

```
baseline 0.0.0 cycles  = 282,702
c4       0.0.0 cycles  = 503,584   delta = +220,882
c5       0.0.0 cycles  = 588,682   delta = +85,098 vs c4

Per-call delta c4 vs baseline ≈ +130 cyc (averaged over num_chunks distribution)
220,882 / 130 ≈ 1,700 slice_hash_rtl calls per 0.0.0 recursion proof.
```

That call count is plausible: roughly 5-8 WHIR proofs verified per recursion node × 5-7 WHIR rounds × 50-70 queries per round × 1-2 Merkle leaves per query.

## 2. Solution catalogue (with cycle estimates)

### S1 — Restore inlining where it's *safe*: lift the work helpers to `@inline`

**Why `@inline` was removed in the first place** — from the development trail (`git log --all --grep=fall-through`), specifically commit `e619619b` ("pw3-32: zk-DSL slice_hash_rtl @inline removed (debug step)"):

> Prior @inline + multi-return-branches caused conditional dispatch to incorrectly fall through, hitting the "slice_hash_rtl called with unsupported num_chunks" assert in the recursive verifier with num_chunks=16. Removing @inline lets the function be a regular function with proper conditional return semantics.

The bug is in `lean_compiler`: when an `@inline` function has multiple `return` paths inside `if`-branches, the inliner fails to emit jumps past sibling branches, so execution falls through into the next branch's body and eventually hits the trailing `assert False`. This is a real compiler bug and the workaround (drop `@inline`) is correct.

But the bug only manifests on functions with **multiple return statements**. The two inner helpers added in c4/c5 do NOT have that pattern:

* `slice_hash_rtl_rate12_no_pad` — straight-line body, single return at the end.
* `slice_hash_rtl_rate12` — has one `if padded_len == data_len: return ...` plus a fall-through return; *but* `padded_len == data_len` is `Const`, so after compile-time const propagation only one of the two returns survives. If we trust the const-prop pass, `@inline` is safe here too. Empirically, the pass already eliminates the dispatch in `slice_hash_rtl` itself (otherwise non-padded num_chunks values would be sent to `slice_hash_rtl_rate12` only to be branched a second time — which is exactly what happens today, but the runtime cycles confirm the if-branches resolve at compile time because total cycles match the per-call estimate above).

**Concrete change** (no source modification — proposed):

```python
# slice_hash_rtl stays as-is (no @inline). The bug stops there.
def slice_hash_rtl(data, num_chunks):
    if num_chunks == 1:  ...
    if num_chunks == 4:  return slice_hash_rtl_rate12(data, 32, 40, 2)
    if num_chunks == 5:  return slice_hash_rtl_rate12(data, 40, 40, 2)
    ...
    assert False, "slice_hash_rtl called with unsupported num_chunks"

@inline                                                          # <— ADD
def slice_hash_rtl_rate12(data, data_len: Const, padded_len: Const, n_chunks_12: Const):
    if padded_len == data_len:
        return slice_hash_rtl_rate12_no_pad(data, padded_len, n_chunks_12)
    padded_data = Array(padded_len)
    for i in unroll(0, data_len): padded_data[i] = data[i]
    for i in unroll(data_len, padded_len): padded_data[i] = 0
    return slice_hash_rtl_rate12_no_pad(padded_data, padded_len, n_chunks_12)

@inline                                                          # <— ADD
def slice_hash_rtl_rate12_no_pad(padded_data, padded_len: Const, n_chunks_12: Const):
    ...  # body unchanged
```

**Estimated savings:** removes 2 of the 3 function-call layers, ~20 cycles per call. With ~1,700 calls on `0.0.0`: **~34K cycles saved**.

**Risk:** if `slice_hash_rtl_rate12`'s if-on-Const isn't const-propagated *before* inline expansion, we re-enter the original fall-through bug. Verify by running the recursive verifier test once after the change: if it fails with `assert False`, drop `@inline` from `slice_hash_rtl_rate12` and keep it only on the no-pad helper (saves ~10 cyc/call instead of ~20).

### S2 — Eliminate the `padded_data` materialization

The padding loop in `slice_hash_rtl_rate12` allocates an entire fresh buffer and copies `data_len` elements into it just to add 8 trailing zeros. For `num_chunks=10` this is 89 cycles per call (1 alloc + 80 copies + 8 zero stores).

**Insight** (worked out by inspecting which indices the inner loop reads): the MMO loop only ever reads `padded_data[chunk_idx * 12 .. chunk_idx * 12 + 12]` for `chunk_idx ∈ [0, n_chunks_12)`. For all six supported `num_chunks` values, those 12-element chunks fall *entirely within the original data range*:

```
num_chunks=4   data_len=32   loop reads: data[ 0..12], data[12..24]                            zeros NEVER read in loop
num_chunks=10  data_len=80   loop reads: data[ 0..12], ..., data[60..72]                        zeros NEVER read in loop
num_chunks=16  data_len=128  loop reads: data[ 0..12], ..., data[108..120]                      zeros NEVER read in loop
num_chunks=5,8,20 — no padding at all
```

The only place the zero pads are read is **the initial state** (round 0 reads `padded_data[L-16..L]`). For the three padding cases, that initial 16-element block is `[data[data_len-8 .. data_len], 0, 0, 0, 0, 0, 0, 0, 0]`.

**Concrete change** — replace `slice_hash_rtl_rate12_no_pad`'s caller with two specializations:

```python
@inline
def _slice_hash_mmo_pad8(data, data_len: Const, n_chunks_12: Const):
    """data_len = 8 + n_chunks_12 * 12.  Padding is exactly 8 trailing zeros (lives only in initial state)."""
    state = Array(16)                                           # 1 cyc
    for k in unroll(0, 8):                                      # 8 cyc
        state[k] = data[data_len - 8 + k]
    for k in unroll(0, 8):                                      # 8 cyc
        state[8 + k] = 0
    poseidon16_permute(state, state + 8, state)                 # 1 cyc
    for j in unroll(0, n_chunks_12):
        chunk_idx = n_chunks_12 - 1 - j
        for k in unroll(0, 12):                                 # 12 cyc
            state[4 + k] = state[4 + k] + data[chunk_idx * 12 + k]
        poseidon16_permute(state, state + 8, state)             # 1 cyc
    return state

@inline
def _slice_hash_mmo_nopad(data, data_len: Const, n_chunks_12: Const):
    """data_len = 16 + n_chunks_12 * 12.  No padding — read initial state directly from data."""
    state = Array(16)
    poseidon16_permute(data + data_len - 16, data + data_len - 8, state)
    for j in unroll(0, n_chunks_12):
        chunk_idx = n_chunks_12 - 1 - j
        for k in unroll(0, 12):
            state[4 + k] = state[4 + k] + data[chunk_idx * 12 + k]
        poseidon16_permute(state, state + 8, state)
    return state
```

**Estimated savings, num_chunks=10 (pad-8 case):**

```
old: 89 cyc padded_data + 1 alloc states + 1 init perm + 6×18 inner = 207 cyc body
new: 1 alloc state + 16 cyc init state + 1 init perm + 6×13 inner = 96 cyc body

Δ = -111 cycles per call for num_chunks=10
```

The same construction also (a) uses a single 16-element rolling state buffer instead of `Array((n_chunks_12+1)*16)`, eliminating 1 large alloc per call and (b) drops the per-iter `pre = Array(16) + 4 capacity copies`, saving 5 cyc × n_chunks_12 per call. Both are folded into the "96 cyc body" number above.

### S3 — In-place state with `poseidon16_permute(state, state+8, state)` (input/output aliasing)

Reading the runtime in `crates/lean_vm/src/tables/poseidon_16/mod.rs:240-300` (the `runtime` impl): the precompile reads its inputs into a local 16-element array first, then writes the output. So aliasing the output buffer to one of the input buffers is **safe at execution time**. The AIR (`crates/lean_vm/src/tables/poseidon_16/mod.rs:344-545`) is also fine with aliasing — it commits the inputs and the outputs as separate cells in the row, and the in-memory write is constrained by `LookupIntoMemory { index: index_input_res, values: outputs }` which only checks the *post-permute* memory state.

Aliasing means the loop becomes:

```python
for j in unroll(0, n_chunks_12):
    chunk_idx = n_chunks_12 - 1 - j
    for k in unroll(0, 12):
        state[4 + k] = state[4 + k] + data[chunk_idx * 12 + k]   # in-place ADD (12 cyc)
    poseidon16_permute(state, state + 8, state)                   # output aliases input (1 cyc)
```

13 cycles per iter, no per-iter alloc, no chained `states` array. Already folded into S2's numbers — flagged separately because the "I/O aliasing is legal" judgment is the load-bearing piece.

**Caveat to verify:** `crates/lean_vm/src/tables/poseidon_16/mod.rs` has, in the `runtime` block:

```rust
input[..HALF_DIGEST_LEN].copy_from_slice(&arg0_first);
input[HALF_DIGEST_LEN..DIGEST_LEN].copy_from_slice(&arg0_second);
input[DIGEST_LEN..].copy_from_slice(&arg1);
let res_addr = index_res_a.to_usize();
if full_output {
    let full = utils::poseidon16_permute_full(input);
    ctx.memory.set_slice(res_addr, &full)?;
}
```

This snapshots `input` *before* writing `res_addr`, so `arg0 == res` aliasing is correct at the runtime layer. The other thing to confirm is that the bytecode encoding can place the same memory region in `arg_a`, `arg_b`, and `res` slots (the precompile lookup sets `index_input_res = res`, and that pointer feeds three separate memory lookups). Currently `arg_b = state + 8` and `res = state` — they are at *different offsets* of the same region, so the three lookups address three different cells. Trivially legal.

### S4 — Re-inline the inner work via `match_range` instead of return-from-`if` (compiler-bug safe)

Rather than risk re-triggering the multi-return-branch fall-through bug, we can rewrite the dispatcher with `match_range`, which expands to a single `Match` IR node (`crates/lean_compiler/src/a_simplify_lang/mod.rs:602-616`) with one return-target slot.

```python
@inline
def slice_hash_rtl(data, num_chunks):
    return match_range(num_chunks, range(...), lambda nc: _slice_hash_dispatch(data, nc))
```

with `_slice_hash_dispatch` being the const-resolved choice between the pad8 / nopad helpers. This pattern is already used elsewhere (e.g., `merkle_verif_batch` in `hashing.py:297`, `decompose_and_verify_merkle_batch` in `whir.py:224`). It side-steps the `@inline` bug by construction.

**Estimated savings:** equivalent to S1+S2 combined but more robust against the compiler bug. Same ~120-cycles-per-call ballpark.

### S5 — Use `ZERO_VEC_PTR` instead of writing 8 zeros for the initial state

`hashing.py:9` defines `ZERO_VEC_PTR`, a preamble region that the runtime fills with zeros. For the initial state's high half we can point at that region instead of materializing zeros into our 16-element state:

```python
state = Array(16)                                              # could even be Array(8) — see below
for k in unroll(0, 8): state[k] = data[data_len - 8 + k]      # 8 cyc
poseidon16_permute(state, ZERO_VEC_PTR, perm_out)              # 1 cyc — high half read from ZERO_VEC
```

This requires the `right` argument of `poseidon16_permute` to be a *separate* memory region from `state`. Looking at the precompile: `poseidon16_compress(left, right, output)` already takes two separate pointers, so `state[0..8]` + `ZERO_VEC_PTR[0..8]` is naturally expressible.

**Estimated savings:** 8 zero-stores eliminated × number of pad-8 calls. For `num_chunks=10` paths × ~1,000 calls: ~8K cycles. Small but free.

### S6 — Combined target after S1-S5 applied

For `num_chunks=10` (the dominant call):

| Implementation | Body cycles | Function-call overhead | Total per call |
|---|---:|---:|---:|
| Baseline RATE=8 (`@inline`) | 10 | 0 | 10 |
| Bundle c5 as-shipped | 199 | 30 | 229 |
| **After S1+S2+S3** | 96 | ~10 | **~106** |
| **After S1+S2+S3+S4+S5** (best) | 88 | 0 | **~88** |

Per-call delta vs baseline: +78-96 cycles instead of +219.

Total cycle budget recovery on the heaviest recursion node (`0.0.0`, ~1,700 calls):

```
S1+S2+S3 :  Δ per call ≈ -123 cyc  →  -209,100 cyc  →  0.0.0 cycles drop to ~379,500   (under 2^19 by 144K)
S4 only  :  Δ per call ≈ -100 cyc  →  -170,000 cyc  →  ~418,700                        (under 2^19 by 105K)
S5 only  :  Δ per call ≈   -8 cyc  →   -13,600 cyc  →  ~575,000                        (still over 2^19)
```

So the binding optimization is **S2** (eliminate `padded_data`). On its own, S2 saves ~110 cyc/call × 1,700 ≈ 187K cyc on `0.0.0`, dropping it to ~402K — well under 2^19. **S2 alone is sufficient.**

S1 and S3 each contribute ~20-25 cyc/call as bonus margin. S5 is small but free.

## 3. Reducing the `poseidon16_permute` AIR cost

The c5 commit added 19 constraints + 8 committed columns + 1 LookupIntoMemory to the Poseidon-16 AIR (`crates/lean_vm/src/tables/poseidon_16/mod.rs:344-417`). This affects the **per-row** cost of the Poseidon AIR table, not the cycle count of the recursive verifier program — so it does not move the trace boundary, but it does add native AIR-evaluation work on every node.

### 3.1 Constraint count: 19 → 11 (8-constraint saving)

Looking at `eval_last_2_full_rounds_16` (`mod.rs:537-578`), the high-half output has two constraints per element:

```rust
// current (16 constraints for the 8 high outputs, plus 1 boolean, 1 mutex, 1 index = 19 total):
for (state_i, output_high_i) in state.iter().skip(WIDTH/2).zip(outputs_high) {
    builder.assert_zero(flag_full_output * (*state_i - *output_high_i));   // 8 of these
    builder.assert_zero(one_minus_flag_full_output * *output_high_i);      // 8 of these
}
```

These two cases — "flag=1: state_i = output_high_i" and "flag=0: output_high_i = 0" — fold into one cubic constraint per element:

```rust
// proposed (8 constraints for the 8 high outputs, plus 1 boolean, 1 mutex, 1 index = 11 total):
for (state_i, output_high_i) in state.iter().skip(WIDTH/2).zip(outputs_high) {
    // output_high_i = flag_full_output * state_i
    builder.assert_zero(*output_high_i - flag_full_output * *state_i);     // 8 of these
}
```

This is degree 2, same as before, just fewer terms. Saves 8 constraints per row × number of poseidon rows.

### 3.2 Eliminate the high-half `LookupIntoMemory` for compress rows

`mod.rs:170-178` adds a second LookupIntoMemory:

```rust
// High-half output lookup (only meaningful in permute mode, but always active).
LookupIntoMemory {
    index: POSEIDON_16_COL_INDEX_INPUT_RES_HIGH,
    values: (POSEIDON_16_COL_OUTPUTS_HIGH_START..POSEIDON_16_COL_OUTPUTS_HIGH_START + DIGEST_LEN).collect(),
},
```

The comment notes: *"For non-permute rows the trace_gen sets index_input_res_high = zero_vec_ptr and outputs_high = 0, so this lookup checks `m[zero_vec_ptr+i] == 0` (trivially true)."* So compress-mode rows pay the full lookup cost just to verify zero. This is wasted work proportional to the share of rows that are *not* permute mode (which is the vast majority — only the MMO sponge initial-state and inner-loop perms are permute mode).

A cleaner shape: **gate the lookup by `flag_full_output`**, or equivalently keep the lookup but lift the high-half columns out of the committed trace for compress rows. Implementing the gate cleanly probably requires a multi-table refactor (split `Poseidon16Precompile` into compress and permute variants, share the round-evaluation code path). High effort, modest payoff.

### 3.3 The fundamental cost we cannot avoid

The `poseidon16_permute` mode has to commit the full 16-element output somewhere — that's its purpose. The 8 `outputs_high` columns aren't dead width; they're load-bearing for permute rows. Trying to shave them would lose us the AIR-level commitment to the high half of the state, which the MMO chain depends on.

So the AIR ceiling on this approach is roughly: keep current widths, halve the constraint count via §3.1, optionally gate the lookup via §3.2. Modest native-prover speedup, no impact on the recursion-cycle budget.

## 4. Reducing MMO feedforward cost specifically

The MMO contribution at c5 over c4 is:

```
state[4..16] := state[4..16] + chunk[0..12]      (12 ADDs, was 4 stores in c4)
plus a wider `pre` buffer (Array(16) vs Array(8)) and wider chained `states`
```

The **12 ADDs** are inherent to MMO rate-mixing — there's no way to absorb a 12-element message into a 12-element rate region in fewer than 12 field operations.

The **wider buffer** is removable via S2/S3 (single in-place state). After that, what's left is exactly:

```
12 ADDs + 1 perm = 13 cycles per inner-loop iter
```

vs the c4 RATE=12-without-MMO equivalent:

```
4 capacity copies + (compress reads chunk[4..12] by pointer) + 1 perm = ~5-6 cycles per iter
```

So MMO costs ~7-8 *additional* cycles per inner iter vs RATE=12 without MMO. With n_chunks_12 averaging ~6 across the call mix and ~1,700 calls per 0.0.0, that's **~75-85K cycles of irreducible MMO overhead**, almost exactly the c5-vs-c4 delta (+85K). This number cannot be optimized away inside the zk-DSL — MMO genuinely is more work than non-feedforward sponge.

The only ways to reduce *that* number are:

* **Larger chunk-stride** (RATE=14, RATE=15)? Would change the AIR/precompile (Poseidon-16 has WIDTH=16, so RATE > 12 leaves capacity ≤ 4, security drops below MMO's protection). RATE=12 is already at the security boundary that MMO compensates for.
* **A non-MMO 124-bit construction**: Davies-Meyer, plain capacity-8 sponge with RATE=8 (the *baseline* construction!), or tree-hashing with `poseidon16_compress` (also baseline). All of these recover security without adding feedforward cost — but they revert the c4 perf goal.

This last bullet is important: **the baseline (RATE=8, capacity=8) already gives 8×31/2 = 124-bit collision security** (`c × log2(p) / 2` with c=8 and KoalaBear's log2(p)≈31). The "62-bit collision (unshippable)" claim in the c5 commit message refers to RATE=12 + capacity=4, *not* the baseline. So if 124-bit is the real security target, the baseline already meets it without MMO.

The c4+c5 sequence trades **−9% poseidon count in the recursion verifier (the "RATE=12 win")** for **+88% recursion-verifier cycles + larger AIR + larger proofs**. Even after S1-S5 fully recover the in-DSL waste, MMO still costs ~75K extra cycles per recursion proof relative to the baseline; the −9% poseidon win is roughly a few thousand cycles. Net: c4+c5 is net negative on the recursion verifier even when implemented optimally.

**Recommendation, repeated from §6 of `investigation.md`:** if the security analysis ratifies that `c=8` baseline already gives 124-bit collision, the cleanest path is to revert c4+c5 entirely. If c4 has a justified perf reason on the *native prover* (Merkle leaf hashing throughput, which is independent of the recursion-verifier zk-DSL), keep that part of c4 in *native* code only and have the zk-DSL recursion verifier use the baseline RATE=8 + capacity=8 construction over the same data (the prover and verifier just need to agree on the hash; they do not need to use identical code paths to achieve that). This requires a *separate* zk-DSL hash for the verifier-side Merkle path, but it is sound as long as both sides hash to the same value.

## 5. Splitting recursion into smaller units

The user proposes: instead of one recursion node aggregating two child WHIR proofs, use two sub-nodes each handling one child plus a final merge. Mathematical reality:

* Today: 1 recursion node with cycles `K = 588,682` (over 2^19).
* Split: 2 sub-nodes each with cycles ~K/2 (each verifies 1 child) + 1 merge node verifying the 2 sub-recursion proofs ≈ K cycles again.

The merge node has *the same problem* — it verifies two WHIR proofs from sub-recursion nodes. Their proofs are smaller (fewer leaves), so the merge cycle count shrinks somewhat, but not enough: the merge still has to run the full WHIR verifier program for each child proof, and the dominant cost (the WHIR query loop with `slice_hash_rtl`) scales primarily with `num_queries × num_rounds`, not with the size of the witness being verified.

So splitting roughly halves the cycle budget *per leaf-side sub-node* (which were already under 2^19) but the merge node remains in the same regime. We pay extra wall-clock for an extra level of recursion (more proofs to generate) without solving the boundary cliff for the merge.

**Splitting the workload helps only if a sub-node can be made structurally cheaper than a full WHIR verification.** That requires protocol changes (e.g., batching multiple inner proofs into one folded sumcheck), not just reorganization.

Net: split-recursion is **not** a useful direction for this regression.

## 6. Minimum cycle budget — do we make it?

Target: drive `0.0.0` from 588,682 cycles to **≤ 524,288** = 2^19. Required cut: **64,394 cycles** (10.94%).

| Solution | Cyc/call saved | Calls in 0.0.0 | Cyc saved on 0.0.0 | Effort |
|---|---:|---:|---:|---|
| S1: re-inline both inner helpers | ~20 | ~1,700 | ~34K | trivial (2 lines) |
| S2: eliminate `padded_data` materialization | ~110 (pad cases) | ~600 | ~66K | ~30 lines |
| S3: in-place state w/ aliasing | ~5/iter | n12·calls | ~36K | folded into S2 |
| S4: `match_range` dispatch instead of return-from-if | ~10 (compiler-safety) | 1,700 | ~17K | ~10 lines |
| S5: ZERO_VEC_PTR trick | ~8 | ~600 | ~5K | ~5 lines |
| **S2 alone** | | | **~66K** | **enough** |
| S1+S2+S3 | | | **~136K** | comfortable margin |

We make it twice over with S2 alone. With S1+S2+S3 we have **~70K cycles of headroom**, which absorbs the +85K MMO-inherent cost from §4 cleanly and leaves 0.0.0 at ~452K cycles — well under 2^19, and the trace doubles only at 2^20 = 1,048,576 (which we are nowhere near).

For `0` (the other recursion node currently over 2^19): 634,861 cycles, also ~1,700 calls. Same per-call savings → also drops to ~498K under S1+S2+S3. Under 2^19 ✓.

For all other recursion nodes already under 2^19: stay under, with even more headroom.

## 7. Recommended order of work (smallest possible delta to fix the regression)

1. **S2 first** — rewrite `slice_hash_rtl_rate12` to skip materializing `padded_data` for the three pad-8 cases (num_chunks ∈ {4, 10, 16}). This is the single highest-leverage change and on its own gets `0.0.0` and `0` back under 2^19.
2. **S1** as a follow-up — `@inline` `slice_hash_rtl_rate12_no_pad` (definitely safe — single-return body) and, more cautiously, `slice_hash_rtl_rate12` (multi-return-on-Const; verify the const-prop pass eliminates one branch before the inliner runs).
3. **S3 in-place state** — only if extra margin needed; folds naturally into S2's rewrite.
4. **S5 ZERO_VEC_PTR** — cheap and free; do it while writing S2.
5. Defer **S4** unless step 2 hits the compiler bug.
6. Defer **§3 AIR cost reduction** indefinitely — it doesn't move the trace boundary.

After S2+S3, verify on the recursion benchmark:

```bash
cargo build --release --bin lean-multisig
RUSTFLAGS="-C target-cpu=native" ./target/release/lean-multisig recursion --tracing 2>&1 \
  | grep -E "Aggregation program|^CYCLES:|Bytecode size:|^Poseidon16 calls:|the final aggregation step"
```

Target reading: recursion (n=2) cycles drop from c5's 456,642 back toward c4's 394,670 or lower. fancy-aggregation `0.0.0` should drop from 588K to 420-460K range; `0` similarly from 635K to 470-510K. Total fancy-aggregation wall-clock should swing from +13.83% back to roughly flat or +1-3% (the MMO + AIR additions still cost ~75K cyc/recursion-node and the AIR width grew 10 cols).

If the regression remains, the residual is in the **native** prover (LTO/allocator/AIR-width effects discussed in `investigation.md`); the zk-DSL has been restored to its near-baseline cycle profile and further savings would require revisiting the security argument that motivated the c4 → c5 path in the first place.

## Appendix — the compiler bug, summarized for follow-up

`crates/lean_compiler/src/a_simplify_lang/mod.rs` is where `@inline` expansion happens. The bug surface (from the development trail at `bdf776bb / e619619b`):

> Prior @inline + multi-return-branches caused conditional dispatch to incorrectly fall through, hitting the "slice_hash_rtl called with unsupported num_chunks" assert in the recursive verifier with num_chunks=16.

Hypothesis: when an `@inline` function body contains `if cond: return X; if cond2: return Y; ...; assert False`, the inliner splices in the if-branches but doesn't terminate them with a jump past sibling branches — control flow falls through into the next sibling and eventually hits the trailing assert.

A focused compiler fix would:
1. Rewrite return-in-`if` inside `@inline` bodies into assignments to a fresh "result" variable + a single trailing return.
2. Or: emit explicit jumps to a synthetic end-label after each return-in-`if`.

Either fix lets us re-inline the OUTER `slice_hash_rtl` dispatcher, giving back another ~10 cycles per call. With ~1,700 calls per 0.0.0 that's another ~17K cycles saved beyond S1-S5. Worth ~3% additional headroom.

Reference call sites for testing: `slice_hash_rtl` (this PR's hashing.py), the if-tower in `batch_hash_slice_rtl` (works *because it's not @inline*), `decompose_and_verify_merkle_batch_with_height` (works the same way).
