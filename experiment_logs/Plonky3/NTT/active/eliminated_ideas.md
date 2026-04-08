## Eliminated ideas (do not re-attempt)

These ideas have been ruled out analytically or by benchmark. Do NOT re-derive them.

---

### Benchmark regressions (measured, not valid)

- **`vpsubd t` + `vptestmd t, SIGN_BIT` for Sub** (iter #002, −1.45%): Using sign bit of raw `vpsubd` result to detect underflow. Regressed — `vpcmpltud lhs, rhs` can run in parallel with `vpsubd`, but `vptestmd t` must wait for the subtraction to complete, serializing the critical path.

- **Manual first-iteration peel for `scale_applied` in `second_half`** (iter #003, −0.56%): Peeling the first iteration of the layer loop to avoid the `scale_applied` runtime bool. LLVM already handles this branch hoisting automatically; the manual version hurts codegen.

---

### Analytically eliminated (never benchmark these)

**`backwards` bool via const generics** (iter #009): Making `backwards` a const generic parameter to give LLVM two specialized versions. LLVM already hoists the `if backwards { ... } else { ... }` branch outside the inner loop. Zero benefit.

**`TwiddleFreeButterfly` anywhere in coset forward DFT** (iter #009): For `first_half_general`, `first_half_general_oop`, `second_half_general` — in the coset LDE case, twiddles[layer][0] = `shift^{2^layer}` where `shift ≠ 1`. None of the coset twiddles are 1, so `TwiddleFreeButterfly` (which assumes twiddle=1) cannot apply anywhere in the forward coset DFT.

**`TwiddleFreeButterfly` last layer of `second_half`** (iter #009): For the non-coset IDFT last layer (layer=log_h−1=19, layer_rev=0), only 1 block out of 512 per thread has twiddle=1 (thread 0, block 0 only, since `bitrev_twiddles[0]=1`). Not worth specializing.

**`ScaledDitButterfly` in `second_half_general`** (iter #009): There is no scale in the forward DFT / coset DFT path. `second_half_general` never receives a scale parameter. Cannot apply.

**`ScaledDitButterfly` in `first_half_general`** (iter #009): No scale in forward DFT. Cannot apply.

**`ScaledTwiddleFreeButterfly` for thread 0 block 0 in `second_half`** (iter #009): Thread 0's first block in `second_half`'s first layer has `twiddle=1` and `twiddle_times_scale=scale`, so it could use a cheaper butterfly. But this saves only 512 muls out of 503M total — well under 0.001%. Negligible.

**Pre-broadcast hoisting for constant-twiddle layer=0 of `first_half_general`** (near-miss, −0.41%): For layer=0, all blocks in a submat share the same twiddle. Hoisting the broadcast outside the blocks loop saves ~1024 `vpbroadcastd` per submat, but this is ~1024 cycles vs ~106K cycles of muls. Negligible savings, and restructuring hurts LLVM. Borderline result but tested twice (−0.41%).

**Two row-pairs simultaneously for ILP in `apply_to_rows`** (iter #009): Processing 2 row-pairs per loop iteration to help pipeline the 21-cycle mul latency. LLVM already pipelines independent chains across loop iterations automatically. No gain.

**`DifButterflyZeros` in hot path** (iter #009): `DifButterflyZeros` is not called anywhere in the `coset_lde_batch` hot path. Irrelevant.

**`confuse_compiler` prevents LLVM hoisting twiddle-derived computations** (iter #009): In the `mul(x2, twiddle_packed)` inner loop, `confuse_compiler` is applied to `prod_evn * MU` and `prod_odd * MU` where `prod_*` depends on `lhs`. Since `lhs` changes each iteration, these cannot be hoisted. The only twiddle-derived computation that could be hoisted is `rhs_odd = movehdup_epi32(rhs)` — but LLVM already hoists this since `rhs` is loop-invariant. No opportunity here.

**Scalar×vector `mul` specialization when `rhs` is a broadcast** (iter #009 analysis): If `rhs` is a broadcast, `rhs_odd == rhs_evn`, so `movehdup_epi32(rhs)` is redundant. Saves 1 instruction per mul. But LLVM already hoists `rhs_odd = movehdup_epi32(twiddle_packed)` outside the apply_to_rows loop since `twiddle_packed` is loop-invariant. Net saving: 0.

**Memory bandwidth as bottleneck — do not re-derive** (analyzed repeatedly): Compute bound ~1.38s at 3GHz, observed ~2.68s. Gap is memory bandwidth (matrix is 1GB >> L3 cache). Twiddle prefetch tried (−0.97%). Arithmetic optimizations help only marginally since we are bandwidth-limited. Do not re-derive this bound.

**Fused add/sub in butterfly** (analyzed): `(a+b) mod P` and `(a−b) mod P` require two different underflow conditions — no single comparison covers both operations simultaneously. Cannot be fused into one comparison.

**Lazy reduction (skip final `vpcmpltud`+`vpaddd_mask` in `mul`)** (analyzed): Omitting the final modular reduction in `mul` produces values outside [0,P) that cannot be used as inputs to subsequent `mul` calls (Montgomery form requires inputs in range). Correctness violation.

**Reverse twiddle slice access pattern** (analyzed): Rust's `Zip::next_back()` correctly handles mismatched-length iterators. No bug, no performance opportunity.

**Combining `apply_to_rows_oop` with `ScaledDitButterfly`** (iter #009): `first_half_general_oop` calls `dit_layer_oop` which uses `DitButterfly`, not `ScaledDitButterfly`. There is no scale in the forward DFT. Cannot apply.

---

### Unimplemented (API crash — not benchmarked, not eliminated)

**Type-level dispatch to remove `scale_applied` bool in `second_half`** (iter #009, never implemented): Making scale a const generic or type parameter to let LLVM specialize `second_half` at compile time. Different from the runtime peel (iter #003, −0.56%). Has not been benchmarked — consider for a future iteration.
