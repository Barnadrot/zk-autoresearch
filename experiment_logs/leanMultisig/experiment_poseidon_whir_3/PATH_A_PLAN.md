# Path A: MMO Sponge Leaf Hash via Full-Output Poseidon-16 Precompile

**Status (as of 2026-05-08):** Research foundation complete (Rust core + unit tests). Implementation of the `poseidon16_permute` precompile + zk-DSL plumbing is the next step.

## Problem statement

The pw3-30b through pw3-33 series shipped a sponge `RATE=12, capacity=4` for WHIR Merkle leaf hashing, achieving **-5.30% prover throughput**. The construction is end-to-end verified (Rust prover/verifier + zk-DSL recursion verifier all pass), but its **collision security is `c·log₂(p)/2 = 4·31/2 = 62 bits`** — far below the 124-bit target.

We confirmed this against three primary sources:
- **Coratger-Khovratovich-Wagner-Mennink 2026** ("The Billion Dollar Merkle Tree", eprint 2026/089): Their position-binding bound `4q²/(|H|−1)` for the same-permutation oSponge gives 123 bits **only when sponge rate=cap=digest_size=8 elements**, i.e., the baseline RATE=8.
- **SAFE proof paper (eprint 2023/520):** Formally proves indifferentiability up to `|F_p|^(c/2)` queries — the same `c·log₂(p)/2 = 62`-bit bound. Domain separation does NOT double the bound; the original SAFE paper's "c·log₂|F| bits" claim was loose.
- **Beetle (CHES 2018):** Bound `min{c−log r, b/2, r}` ≈ 115.5 bits is for **AEAD** (privacy+integrity), not hash collision. Doesn't help.

**Conclusion:** Standard sponge constructions with capacity=4 over a 31-bit field cannot give 124-bit collision. Beetle and SAFE do not solve this.

## What works: Davies-Meyer / Matyas-Meyer-Oseas (MMO) feedforward

The construction that achieves 124-bit collision while preserving RATE=12:

```
state = 0  (16 elements)
for each rate-sized message block M (added to rate positions, NOT overwritten):
    pre = state + (M, 0_cap)        # ADD message, don't overwrite
    state = pre + perm(pre)          # full-state feedforward
output = state[..8]
```

**Why 124-bit:** The chaining variable is the FULL 16-element state (496 bits), so MMO compression has `b/2 = 248`-bit collision in the random-permutation model. After truncating output to 8 elements (248 bits), output birthday gives `output_bits/2 = 124` bits collision.

**Cost vs current RATE=12 oSponge:** ~16 field additions per absorb step extra (negligible — Poseidon-16 dominates at hundreds of cycles per call).

## Already implemented (this PR / branch)

**File:** `crates/backend/symetric/src/sponge.rs`

Four new public functions (gated to scalar/packed types via `T: PrimeCharacteristicRing` trait bound):

- `mmo_hash_slice<T, Comp, WIDTH, RATE, OUT>(comp, data) -> [T; OUT]`
- `mmo_precompute_zero_suffix_state<T, Comp, WIDTH, RATE, OUT>(comp, n_zero_chunks) -> [T; WIDTH]`
- `mmo_hash_rtl_iter<T, Comp, I, WIDTH, RATE, OUT>(comp, rtl_iter) -> [T; OUT]`
- `mmo_hash_rtl_iter_with_initial_state<T, Comp, I, WIDTH, RATE, OUT>(comp, iter, initial_state) -> [T; OUT]`

Three unit tests in `mod tests` confirm:
- `mmo_hash_slice` and `mmo_hash_rtl_iter` agree on equivalent inputs (RTL vs sequential).
- MMO digest differs from oSponge digest on multi-block inputs (sanity that we are not silently falling back).
- `mmo_precompute_zero_suffix_state` is consistent with directly hashing a zero-suffixed message.

These primitives are **unused by current callers** — they exist as documented research artifacts ready for path A's wire-up step.

## Verified-not-working alternatives

Before settling on MMO + new precompile, the following were ruled out:

1. **Per-leaf binary Merkle tree of `poseidon16_compress`**: 124-bit secure but cost is `≈ L/8` perm calls per leaf — equivalent to baseline RATE=8. No throughput gain.
2. **Single-block (L≤16) leaves**: 124-bit secure but requires WHIR commitment shape surgery; large protocol change for marginal gain.
3. **Capacity-only feedforward with overwrite-message**: Effective chaining is just the 4-element capacity; still `c·log₂(p)/2 = 62`-bit. Doesn't help.
4. **Two `poseidon16_compress` calls per absorb (one for low half, one for high half)**: Each call evaluates the full perm — net 6 elements / perm-call, *worse* than RATE=8.

The only construction that gives RATE>8 with 124-bit collision **and** uses the existing 16→8 truncated permutation primitive is to expose the full 16-element output of the perm via a new precompile.

## Implementation roadmap

### Step 1: Extend Poseidon16 AIR to expose 16-element output

**File:** `crates/lean_vm/src/tables/poseidon_16/mod.rs`

Existing AIR already computes `output[i] = state_perm[i] + input[i]` for all 16 positions in `eval_last_2_full_rounds_16` (line ~481-483) — it just only commits the first 8 to the `outputs` column. So the AIR/perm evaluation does **not** change; we only need to expose the additional 8.

Changes:
- Add fields to `Poseidon1Cols16<T>`:
  - `pub flag_full_output: T` (1 col, after `flag_hardcoded_left`)
  - `pub index_input_res_high: T` (1 col, near other index columns)
  - `pub outputs_high: [T; WIDTH / 2]` (8 cols, at end of struct)
- Add column index constants:
  - `POSEIDON_16_COL_FLAG_FULL_OUTPUT`
  - `POSEIDON_16_COL_INDEX_INPUT_RES_HIGH`
  - `POSEIDON_16_COL_OUTPUTS_HIGH_START`
- Add precompile name: `POSEIDON16_PERMUTE_NAME = "poseidon16_permute"`. Append to `ALL_POSEIDON16_NAMES`.
- Add data-bit shift: `POSEIDON_FULL_OUTPUT_SHIFT = 1 << 30` (safely beyond `8 * MAX_LOG_MEMORY_SIZE = 2^29` to avoid encoding clashes with `hardcoded_offset`).

AIR constraints to add (in `Air::eval`):
- `assert_bool(flag_full_output)`.
- `flag_full_output * flag_half_output = 0` (mutually exclusive).
- `flag_full_output * (index_input_res_high - index_input_res - DIGEST_LEN) = 0`.
- For `i in 0..8`: `flag_full_output * (outputs_high[i] - state_perm[i+8] - inputs[i+8]) = 0`.
- For `i in 0..8`: `(1 - flag_full_output) * outputs_high[i] = 0` (zero when not in permute mode).
- Update `precompile_data_reconstructed` to include `flag_full_output * POSEIDON_FULL_OUTPUT_SHIFT`.

Lookups to add (in `lookups()`):
```rust
LookupIntoMemory {
    index: POSEIDON_16_COL_INDEX_INPUT_RES_HIGH,
    values: (POSEIDON_16_COL_OUTPUTS_HIGH_START..POSEIDON_16_COL_OUTPUTS_HIGH_START + DIGEST_LEN).collect(),
},
```

For non-permute rows: `outputs_high` is constrained to zero, and `index_input_res_high` is set in the trace to `zero_vec_ptr` (a memory region pre-filled with zeros). The lookup `m[zero_vec_ptr + i] = 0` is then trivially satisfied. Soundness: a malicious prover gains nothing by varying `index_input_res_high` because the lookup forces `m[that_address + i] = 0`, which would conflict with any non-zero memory at that address.

### Step 2: Update executor and trace generator

**File:** `crates/lean_vm/src/tables/poseidon_16/mod.rs` (executor)

In `execute()`:
- Read `full_output: bool` from `PrecompileCompTimeArgs::Poseidon16`.
- If `full_output`, call `set_slice(index_res_a, &output)` where `output` has all 16 elements (need to compute the second half via running the perm twice — actually the existing `poseidon16_compress(input)` only returns 8; we need a `poseidon16_permute(input) -> [T; 16]` helper).

**File:** `crates/utils/src/poseidon.rs`

Add:
```rust
pub fn poseidon16_permute(input: [KoalaBear; 16]) -> [KoalaBear; 16] {
    get_poseidon16().compress(input)  // returns [T; 16] before truncation
}
```

(Verify by reading Plonky3 `Compression::compress` impl that the 16-element output already includes the input feedforward — current AIR matches that semantics, so the existing `compress` should produce `perm(input) + input`.)

**File:** `crates/lean_vm/src/tables/poseidon_16/trace_gen.rs`

In `generate_last_2_full_rounds`:
- Extend `outputs: &mut [&mut F; WIDTH / 2]` to `outputs: &mut [&mut F; WIDTH]` (or add a parallel `outputs_high` parameter).
- Fill all 16 output cells with `state[i] + initial_state[i]`.

For non-permute rows: the trace generator should also fill `outputs_high` with the perm output (just like `outputs` is filled in half_output mode), then the AIR's zero constraint `(1 - flag_full_output) * outputs_high[i] = 0` is satisfied via the `(1 - flag_full_output)` factor.

Wait — that constraint forces `outputs_high[i] = 0` when not full_output. So trace generator must ZERO `outputs_high` for non-permute rows. Need to special-case.

### Step 3: Update PrecompileCompTimeArgs

**File:** `crates/lean_vm/src/isa/instruction.rs`

```rust
pub enum PrecompileCompTimeArgs<S> {
    Poseidon16 {
        half_output: bool,
        full_output: bool,                   // NEW
        hardcoded_offset_left: Option<S>,
    },
    ExtensionOp { ... },
}
```

Update `map_size`, `Display`, and the various match arms in:
- `crates/lean_compiler/src/instruction_encoder.rs` (precompile_data computation: add `+ POSEIDON_FULL_OUTPUT_SHIFT * (*full_output as usize)`).
- `crates/lean_compiler/src/a_simplify_lang/mod.rs` (set `full_output=true` when name == `POSEIDON16_PERMUTE_NAME`).
- `crates/lean_compiler/src/parser/parsers/function.rs` (recognize new name).

### Step 4: zk-DSL DSL placeholder

**File:** `crates/lean_compiler/snark_lib.py`

```python
def poseidon16_permute(left, right, output):
    """Apply Poseidon-16 with feedforward, writing the full 16-element output.
    output[0..8]  = perm(left || right)[0..8]  + left
    output[8..16] = perm(left || right)[8..16] + right
    """
    _ = left, right, output
```

### Step 5: zk-DSL hashing helpers

**File:** `crates/rec_aggregation/zkdsl_implem/hashing.py`

Add `mmo_slice_hash_rtl_rate12_no_pad` parallel to existing `slice_hash_rtl_rate12_no_pad`:

```python
def mmo_slice_hash_rtl_rate12_no_pad(padded_data, padded_len: Const, n_chunks_12: Const):
    # FULL 16-element state persisted between rounds.
    states = Array((n_chunks_12 + 1) * 16)

    # Round 0: state[0..16] = padded_data[len-16..len]; permute+feedforward → states[0..16].
    poseidon16_permute(padded_data + padded_len - 16, padded_data + padded_len - 8, states)

    for j in unroll(0, n_chunks_12):
        chunk_idx = n_chunks_12 - 1 - j
        # Build pre-perm state: copy current state, then ADD (not overwrite) chunk into rate positions [4..16].
        pre = Array(16)
        for k in unroll(0, 4):  # capacity stays
            pre[k] = states[j*16 + k]
        for k in unroll(0, 12):  # rate gets ADDED with chunk
            pre[4 + k] = states[j*16 + 4 + k] + padded_data[chunk_idx * 12 + k]
        # Permute + feedforward.
        poseidon16_permute(pre, pre + 8, states + (j + 1) * 16)

    # Output: first 8 of final state.
    return states + n_chunks_12 * 16
```

Note: the field-add in `pre[4+k] = states[...] + padded_data[...]` may need the `add_be` precompile or zk-DSL operator-overloaded `+` (verify what's supported).

### Step 6: Update WHIR recursion verifier

**File:** `crates/rec_aggregation/zkdsl_implem/hashing.py`

Switch `slice_hash_rtl_rate12` (and the `slice_hash_rtl` dispatch) to use `mmo_slice_hash_rtl_rate12_no_pad`.

Note: `merkle_verify` (which uses `poseidon16_compress` directly for INTERNAL nodes) does NOT change — internal node compression is already a 124-bit-secure 2:1 MMO truncated, only the LEAF hash needs MMO.

### Step 7: Re-enable MMO in Rust core

Re-apply the (already prototyped, then reverted) call-site changes:
- `crates/backend/symetric/src/merkle.rs:108`: `hash_slice` → `mmo_hash_slice`. Tighten trait bound `F: Default + Copy + PartialEq` → `F: PrimeCharacteristicRing + PartialEq`.
- `crates/whir/src/merkle.rs:99,283,319`: `precompute_zero_suffix_state` → `mmo_precompute_zero_suffix_state`; `hash_rtl_iter` → `mmo_hash_rtl_iter`; `hash_rtl_iter_with_initial_state` → `mmo_hash_rtl_iter_with_initial_state`. Update trait bounds on `WhirMerkleTree::new`, `first_digest_layer`, `first_digest_layer_with_initial_state` to require `F: PrimeCharacteristicRing` and `P: PackedValue + Default + PrimeCharacteristicRing`.
- `crates/backend/fiat-shamir/src/verifier.rs:87`: `hash_slice` → `mmo_hash_slice`.

(These edits were prototyped in this branch, tested with `cargo test -p mt-whir --release` and passed, then reverted to keep the tree clean while the precompile work is pending.)

### Step 8: Tests + benchmark

```bash
cargo test -p mt-whir --release          # already passes with MMO Rust core
cargo test --release --test test_multisignatures  # blocked on steps 1–6
bash harness/leanmultisig/scripts/eval_paired.sh  # confirm ~5% throughput vs RATE=8 baseline preserved
```

## Estimated effort

- **Step 1 (AIR):** 4–6 hours. Most fragile — requires careful constraint design, soundness review, and verification that existing tests pass unchanged.
- **Steps 2–3 (executor + ISA):** 2–3 hours.
- **Step 4 (DSL placeholder):** 30 minutes.
- **Step 5 (DSL hashing):** 2–4 hours. Trickier than it looks — need to handle padding, RTL ordering, packed/scalar paths.
- **Step 6 (recursion verifier):** 1–2 hours wiring + debugging.
- **Step 7 (Rust re-enable):** 30 minutes (already prototyped).
- **Step 8 (tests + bench):** 1–2 hours.

**Total: 11–18 hours of focused work.**

## Risk register

- **AIR constraint bugs:** highest risk. The "soundness via zero_vec_ptr trick" needs careful review — make sure a malicious prover cannot exploit the freedom in `index_input_res_high` for non-permute rows.
- **Memory bus consistency:** the `(1 - flag_full_output) * outputs_high[i] = 0` constraint must be satisfied identically by trace generator + AIR. If trace generator fills `outputs_high` from the perm output (non-zero), the AIR constraint fails.
- **Codegen / dispatch bugs:** the new precompile flag bit must thread through `precompile_data` correctly in encoder.rs AND get reconstructed identically in the AIR.
- **zk-DSL `add` semantics:** may need to use `add_be` precompile rather than infix `+` in the rate-positions ADD step.
- **Allocation in DSL:** `Array((n_chunks_12 + 1) * 16)` is bigger than the existing `Array((n_chunks_12 + 1) * 8)`. Verify program-level allocation pressure is acceptable.

## Why not just revert RATE=12 → 8?

Path C (revert) is the 1-line option that loses the 5.30% throughput win. Path A is the clean shippable answer that preserves it. Path B (Poseidon-24 leaf hash) gives less throughput than path A and is more work. Path A wins.
