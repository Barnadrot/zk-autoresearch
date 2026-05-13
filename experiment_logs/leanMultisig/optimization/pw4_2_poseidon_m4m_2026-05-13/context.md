# pw4_2-m4m — Context (read once at session start, do not re-read per iter)

This file is what prior experiments (pw3, pw4) found. Treat it as ground truth — do not re-attempt confirmed dead-ends, do not re-claim confirmed wins, do not re-litigate methodology that's already settled.

## Starting state

pw4 already optimized scalar-binding on the SIMD `compress_mut` path on Hetzner Zen 4 AVX-512 (three commits live on the dev branch `myfork:dev/poseidon-scalar-bind-3-keep-2026-05-13`, not yet on `origin/main`). Those wins were AVX-512-codegen-specific; whether they port to NEON on Apple Silicon is open. pw4_2-m4m starts from `origin/main` — attack different surfaces, but a scalar-binding sub-investigation in `compress_mut` IS in scope here (different ISA, different register file, the conclusion may be different than on Hetzner).

A sibling experiment `pw4_2-2026-05-13` runs in parallel on Hetzner Zen 4 AVX-512. You do not coordinate with it; each branch is independent. Cross-platform delta = valuable signal at the end (some optimizations win on both architectures, some are silicon-specific).

## Unattempted-from-pw4 surfaces (candidate pool input)

pw4 left these untouched. **The Candidate Pool in program.md is selected from this list (3-5 surfaces).**

| Surface | Predicted Δ% | Type | Notes |
|---|---|---|---|
| Tier 1 #2 chain-spanning delayed Montgomery | +3-6% | structural | Keep state[0] in wider accumulator ACROSS partial rounds, reduce only when bound forces. **NOT the pw4-10 single-rc-add range relaxation — that was a nibble, not the real chain-spanning idea.** Constraint: bound `S_max^3 · |MDS_row|_1` < accumulator width per chain length. Derive max chain length explicitly. |
| Tier 1 #4 MDS coefficient re-search ≤4-magnitude | +3-7% | structural | Current MDS uses 67, 63, 101 (forces full mul-port use). A circulant column with entries ≤ 4 maps multiplies into shifts+adds. **Cryptanalysis-gated**: if you produce a candidate matrix that proves the MDS property + branch number ≥ 17 over KoalaBear, log the matrix + the proof sketch in `iters.tsv` under `status=cryptanalysis-pending`. Move on to the next candidate; do NOT block the loop or ship this iter as a keep. The cryptanalysis review happens out-of-band, outside your session. |
| Tier 2 Jagged-PCS leaf packing | +4-8% uniform | structural | Multi-poly batched commits sharing leaves. SP1 Hypercube claims 5× on this lever. Touches `stacked_pcs.rs` + Merkle leaf assembly. pw4-27 tried a related layout-padding tweak (sub-gate); the proper Jagged-PCS work is more ambitious. |
| Tier 2 WHIR tree-pruning for shared Merkle paths | TBD | structural | Cache sibling hashes during open when many query indices share Merkle ancestors. Pure encoding optimization, no security impact. Unattempted entirely. |
| Sumcheck ⊗ eq-MLE kernel fusion (Tier 3 from pw4) | TBD | structural | `mt_sumcheck` (12%) + `mt_poly` (6%) + `sub_protocols` (9%) = 27% Hetzner, adjacent to Poseidon's 27%. **Conditional trigger:** only if first Tier-1 attempt lands ≥10% cumulative AND Poseidon share drops below sumcheck/eq-MLE in re-profile. |

## Inspiration repos (allowed, in-loop reading)

`origin/main` source only — **NO `git log`** on these repos.

- Plonky3 (`~/zk-autoresearch/Plonky3`) — Poseidon1/Poseidon2 implementations, packed-field arithmetic, FRI. Use the `neon/` and scalar paths; the `avx512/` paths in Plonky3 are not relevant to this hardware.
- SP1 (`~/zk-autoresearch/sp1`) — Hypercube / Jagged-PCS reference; sumcheck batching patterns
- Jolt (`~/zk-autoresearch/jolt`) — Dory commitments; alternative PCS shapes

All three are present at the cited paths on the executor (verified). Halo2 is NOT cloned — if you want to look at lookup-argument patterns, the Plonky3 logUp implementation is the in-tree reference.

## Verdict.md structured header (write at stop time)

When stop criterion trips, the verdict.md MUST start with this YAML header before any prose:

```yaml
---
experiment: pw4_2-poseidon
start_commit: c868330c
final_commit: <SHA>
cumulative_pct: <number, e.g., -3.42>
cumulative_p_value: <number>
keeps:
  - hypothesis_id: h1
    iter_id: pw4_2-N
    delta_pct: <number>
    surface: <one-line description>
discards: <count>
orphans: <count, with delta_pcts>
dead_ends_confirmed:
  - <one-line description>
methodology_notes: <free-form prose, but minimal>
---
```

Body below the header is free-form prose.

## Two attempts per hypothesis — examples of when to retry

**Retry warranted (attempt 2):**
- Hypothesis: "scalar-bind these 5 vars should let codegen keep them in ZMM registers". Attempt 1: codegen still spills due to lifetime overlap. Diagnostic (perf annotate) shows spills on var 3 and var 5. Attempt 2: reorder lifetimes via explicit blocks, recompile. Different mechanism, same hypothesis.

**Retry NOT warranted (declare dead-end):**
- Hypothesis: "this rayon nesting cleanup wins on prove_loop too". Attempt 1: −0.08%. Diagnostic shows it's a different workload's bottleneck. The hypothesis is class-mismatched; retrying won't fix that.

The diagnostic step is what distinguishes the two. Run perf + read disassembly + reason about WHY. Don't skip.
