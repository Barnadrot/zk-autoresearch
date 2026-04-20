# Baseline Profile — xmss_leaf_1400sigs

**Date:** 2026-04-18  
**Build:** `RUSTFLAGS="-C target-cpu=native -C force-frame-pointers=yes" cargo build --release`  
**Tool:** `perf record -g --call-graph=fp -F 997` (40,657 samples)  
**Hardware:** AMD EPYC 9R14 (Zen 4), 8 vCPUs, AVX-512, c7a.2xlarge  

## Top Functions by Self Time

| % Self | Function | Category |
|--------|----------|----------|
| 13.02% | `Poseidon1KoalaBear16::permute_mut` (h05e5) | Merkle tree hashing |
| 8.03% | `Poseidon16Precompile::eval` (Air::eval) | **AIR constraint eval** |
| 6.59% | `Poseidon1KoalaBear16::permute_mut` (h7413) | Merkle tree hashing |
| 4.38% | kernel (0xffffffffaea00fd0) | KVM / page faults |
| 3.03% | `eval_2_full_rounds_16` | **AIR constraint eval** |
| 1.99% | `handle_gkr_quotient_with_fold` closure | GKR quotient sumcheck |
| 1.91% | `array::drain::Drain::call_mut` | Iterator internals |
| 1.86% | `eval_last_2_full_rounds_16` | **AIR constraint eval** |
| 1.73% | `rayon::bridge_producer_consumer::helper` | Rayon overhead |
| 1.39% | `Poseidon1KoalaBear16::permute_mut` (h63a7) | Merkle tree hashing |
| 1.37% | `PackedQuinticExtensionField::from_ext_slice` | Field packing |
| 1.37% | `eval_eq_basic` | Eq polynomial eval |
| 1.22% | `fold_and_compute_product_sumcheck` (h768d) | WHIR product sumcheck |
| 1.21% | `fold_and_compute_gkr_quotient_split_eq` (hf0fc) | GKR quotient sumcheck |
| 1.02% | `fold_and_compute_product_sumcheck` (h9004) | WHIR product sumcheck |
| 1.02% | `eval_eq_with_packed_output` | Eq polynomial eval |
| 0.85% | `__memmove_avx512_unaligned_erms` | Memcpy/memmove |
| 0.69% | `compute_gkr_quotient_split_eq` (hb7ed) | GKR quotient sumcheck |
| 0.64% | `ConstraintFolderPacked::assert_zero` | **AIR constraint folder** |
| 0.62% | `Vec::from_iter` | Allocation |
| 0.59% | `AirBuilder::assert_eq` | **AIR constraint folder** |
| 0.55% | `compute_gkr_quotient_split_eq` (hfb3d) | GKR quotient sumcheck |
| 0.52% | `_int_malloc` | Heap allocation |
| 0.49% | `fold_and_compute_gkr_quotient_split_eq` (h28d4) | GKR quotient sumcheck |
| 0.47% | `ExecutionTable::eval` (Air::eval) | **AIR constraint eval** |

## Grouped by Functional Area

| Area | % Self | Notes |
|------|--------|-------|
| **Merkle tree hashing** (Poseidon1 permute_mut) | **21.0%** | 3 monomorphizations of permute_mut. This is OUTSIDE sumcheck — it's the commitment layer. |
| **AIR constraint eval** (Air::eval + round functions) | **14.4%** | Poseidon16 Air::eval (8.03%), eval_2_full_rounds (3.03%), eval_last_2_full_rounds (1.86%), ExecutionTable::eval (0.47%), other tables (~1%) |
| **AIR constraint folder** (assert_zero, assert_eq) | **1.2%** | ConstraintFolderPacked::assert_zero (0.64%), AirBuilder::assert_eq (0.59%) |
| **GKR quotient sumcheck** | **4.9%** | handle_gkr_quotient_with_fold (1.99%), fold_and_compute_gkr_quotient_split_eq (1.21% + 0.49%), compute_gkr_quotient_split_eq (0.69% + 0.55%) |
| **WHIR product sumcheck** | **2.2%** | fold_and_compute_product_sumcheck (1.22% + 1.02%) |
| **Eq polynomial** | **2.4%** | eval_eq_basic (1.37%), eval_eq_with_packed_output (1.02%) |
| **Field packing / conversion** | **1.4%** | from_ext_slice (1.37%) |
| **Rayon overhead** | **1.7%** | bridge_producer_consumer (1.73%) |
| **Allocation** | **1.1%** | _int_malloc (0.52%), Vec::from_iter (0.62%) |
| **Memcpy** | **0.9%** | memmove_avx512 (0.85%) |
| **Kernel** | **~7%** | KVM page faults, scheduling |
| **Iterator/closure dispatch** | **~6%** | FnMut::call_mut (multiple instances), Drain, Map::fold |

## Key Insights

1. **Merkle tree hashing is #1 at 21%.** This was NOT in the experiment 2 target list at all. `Poseidon1KoalaBear16::permute_mut` is the Poseidon permutation used for Merkle tree commitments, not for AIR constraint evaluation. Three different monomorphizations suggest it's called from different commitment contexts.

2. **AIR constraint eval is 14.4% self, not 91%.** The "91% of sumcheck compute" estimate from experiment 2 was about instruction mix WITHIN the sumcheck kernel, not e2e. The actual e2e breakdown shows AIR constraint eval is significant but not dominant.

3. **ConstraintFolderPacked::assert_zero is only 0.64%.** Pre-broadcasting alpha powers would optimize this function, but it's <1% of total time. The real cost is in the Air::eval implementations themselves (8.03% for Poseidon16 alone), which compute constraint expressions.

4. **GKR quotient sumcheck is 4.9%.** Non-trivial, partially explored in experiment 2.

5. **Iterator/closure overhead is ~6%.** `FnMut::call_mut` appears multiple times totaling ~5%, plus `Drain` and `Map::fold`. These are compiler-generated thunks for closures passed through generic APIs. May indicate vtable/indirect-call overhead.

6. **Allocation overhead is ~1.1%.** `_int_malloc` at 0.52% + `Vec::from_iter` at 0.62%. These are the per-element Vec allocations in the sumcheck inner loop.

## Profiling Caveats

- Frame-pointer based call graph; some frames may be missing for leaf functions that don't set up frames despite `-C force-frame-pointers=yes`
- KVM virtualization adds ~7% kernel overhead not present on bare metal
- `--profile-time 10` runs ~2 iterations of the benchmark; sampling is adequate (40K samples)
- Kernel symbols are unresolved (restricted /proc/kallsyms)
