# leanMultisig — Poseidon/WHIR Minmax (follow-on to perf/poseidon-fft-mmo)

## Role

You are a performance researcher minmaxing the Poseidon/WHIR component of the leanMultisig
XMSS aggregation prover. The starting baseline is the **perf/poseidon-fft-mmo** branch
(submitted as PR #216 to upstream), which already shipped:

- FFT MDS in AIR `mds_air_16` (50 mults vs Karatsuba 72)
- WHIR Merkle leaf sponge: RATE=8 → RATE=12, capacity=4
- MMO feedforward sponge for 124-bit collision security at RATE=12
- `#[inline]` on cross-crate hot path for thin-LTO codegen

That bundle was **-5.58% e2e wall-clock** vs `origin/main` under the production profile.
The Poseidon component itself is ~40% of e2e cycles, so the **component-level speedup is
~17%** by Amdahl's lower bound. The structural surface this PR opened is what we're now
mining — not yet-another-LTO-rescue on micro-ops.

You form your own hypotheses, validate them with measurement, and decide what to try next.
The **5 seeded directions below are the priority list** — start there, in order. After
those (or in parallel if one is blocked), freeroam: form your own hypotheses on the
Poseidon/WHIR surface and chase them.

**Hardware:** Hetzner AX42-U — AMD Ryzen 7 PRO 8700GE (Zen 4), 8c/16t, 64 GB, AVX-512.

## Repo & branch

| Repo | Path | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `pw-minmax` (create from `perf/poseidon-fft-mmo`) |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` (reference) |

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch myfork
git checkout perf/poseidon-fft-mmo
git checkout -b pw-minmax
```

If `perf/poseidon-fft-mmo` has been merged upstream by the time you start, branch from
`origin/main` instead and verify the merged commits are in place.

## Baseline numbers (production profile, prove_loop fat LTO)

| Metric | Value |
|--------|-------|
| Warm-proof avg (proofs 2-5 of `prove_loop 5`) | **2.002 s** |
| XMSS/s | 774 |
| Proof size | 345 KiB |
| Cold proof (proof 1) | ~2.83 s |

Re-confirm before your first iteration. Run `prove_loop` once to verify the baseline
matches; if it doesn't, debug your environment before optimizing.

## Component-level reasoning

The current PR's e2e -5.58% extracts ~17% from the Poseidon/WHIR surface (≈30-35% of
e2e cycles by deep profile). Same-effort gains *outside* this surface translate to e2e
at ~0.14× per component-level point, while gains *inside* this surface translate at
~0.32× per point. **Stay on this surface unless you find a better-leveraged target.**

Scoring rule for the upstream-PR view: `net = throughput_pct - 3 × proof_size_increase_pct`.
Reductions in proof size are valued at the same 3× ratio. Aim for **net ≥ +5** on each
keep, allowing the bundle to clear +10 with three good landings.

## Seeded directions (do these first, in this order)

### Direction 1 — Wider Merkle tree (arity-3 or arity-4)

**Hypothesis:** With RATE=12 absorbs in place, an arity-4 Merkle tree halves the absorbs
per path traversal vs arity-2. The recursive verifier is path-traversal heavy, so the
e2e impact is large. Predicted magnitude: **-3 to -5% e2e**.

**Where:**
- `crates/whir/src/merkle.rs` — `build_merkle_tree_koalabear`, level reduction.
- `crates/backend/symetric/src/merkle.rs` — `compress_layer`, tree walk.
- `crates/rec_aggregation/zkdsl_implem/` — verifier program needs the corresponding
  arity in path checks. **This will likely grow proof size; budget for it.**

**Risk:** Prior exp5 ruled out arity-4 — but at RATE=8, where the Merkle compression
cost wasn't favorable. Re-evaluate with RATE=12 in mind: each 4-ary node now absorbs
in one call vs two before. If the verifier program grows the proof past +3% net, the
direction is dead in this form.

### Direction 2 — Verifier program shrink (proof size only)

**Hypothesis:** The current PR added +2.0% proof size from per-known-`num_chunks`
dispatch in `slice_hash_rtl`. A loop-based or table-driven dispatch reclaims most of
that with no throughput loss. Predicted: **0% throughput, -1.5 to -2% proof size.**

**Where:** `crates/rec_aggregation/zkdsl_implem/hashing.py` — `slice_hash_rtl` and
its helpers. The current code dispatches per known `num_chunks` (2, 3, …) by emitting
a dedicated absorb sequence; consolidate to a single parameterized loop.

**Risk:** `@inline` interactions in the zk-DSL bit us in pw3-32 (multi-return-from-
conditional caused dispatch fall-through). Test correctness gate carefully; do not
re-add `@inline` to the rewritten function until you verify dispatch behavior.

### Direction 3 — Batched AIR Poseidon (2 hashes per row)

**Hypothesis:** With FFT MDS in the AIR (50 mults vs 72), the per-call cost dropped
enough that fitting two AIR Poseidon evaluations in one row may be net-positive. Half
the trace rows for the same hash count. Predicted: **-2 to -4% e2e on AIR-eval-heavy
proofs**, lower bound 0% if column count blows up.

**Where:** `crates/lean_vm/src/tables/poseidon_16/mod.rs` — `Poseidon16Precompile::eval`,
column layout (`POSEIDON_16_COL_*`), and `eval_last_2_full_rounds_16`. Adjacent code in
`crates/lean_vm/src/tables/poseidon_16/trace_gen.rs` for the witness side.

**Risk:** AIR width budget. Doubling the hash slots ~doubles the column count for this
table — verify that doesn't overflow the air-eval cycle budget or push past the 2^19
trace-cliff that bit pw3 recursion.

### Direction 4 — MMO precompute generalization

**Hypothesis:** `mmo_precompute_zero_suffix_state` already shows that constant-prefix/
suffix elision saves a perm call. There are other Merkle/sponge callsites where the
input has a known constant prefix (genesis hashes, system constants, padding patterns
beyond zero-suffix). Generalizing the precompute to those patterns saves perm calls in
the build path. Predicted: **-1 to -2% e2e**.

**Where:** `crates/backend/symetric/src/sponge.rs` — generalize the precompute to
arbitrary known constant chunks. Update `crates/whir/src/merkle.rs` and any other
`mmo_hash_slice` callsite to use it where the prefix is statically known.

**Risk:** Each callsite needs explicit opt-in. Don't over-generalize the API; this is
a focused win on a small number of high-traffic callsites. Stop adding callers once
gains plateau.

### Direction 5 — Davies-Meyer mode A/B vs MMO

**Hypothesis:** Davies-Meyer feedforward (XOR input into state pre-permute, output is
post-state) has similar collision security to MMO at width=16, capacity=4, but skips a
post-perm state copy. Predicted: **-0.5 to -1% e2e**.

**Where:** `crates/backend/symetric/src/sponge.rs` — implement `dm_hash_slice` alongside
`mmo_hash_slice`. Wire one Merkle leaf hash callsite to DM behind a feature flag for
the A/B; do NOT replace MMO globally until A/B confirms a win.

**Risk:** Security analysis differs (DM has known weakness against fixed-input attacks
in some constructions). Validate the security argument before shipping; this experiment
may end as a documented null with a security write-up rather than a code change.

## After the five — freeroam

Once you've worked through the seeded list (or hit a hard blocker on each), form your
own hypotheses. The Poseidon/WHIR surface is dominant (40% of cycles); look for what's
under-explored. Possible angles, not a task list:

- **AIR partial-round skip** under z>4 (degree-split; took -13% in `experiment_logup_sumcheck_v2`
  but never integrated with the current Poseidon AIR shape).
- **Merkle build chunk size tuning** — the rayon worker hot loop now inlines absorbs;
  ideal chunk size may have shifted.
- **`compile_to_low_level_bytecode` caching** — was 5.2% in the deep profile. Verify
  whether it's per-proof or amortized; if per-proof, caching is a free win.
- **Stacked PCS column layout** — already optimized in exp5 but the surface may have
  changed under RATE=12.
- **WHIR query parameter retuning** — the proof-size budget shifted (we already paid
  +2% for the verifier change). Revisit `pow_bits` and `rs_red` against the new baseline.

Form a hypothesis with a magnitude prediction before each iteration. "Try X and see"
is not a hypothesis.

## Out of scope

- `monty_31/mds.rs`, `x86_64_avx512/*` — permutation internals, hardware-limited.
- LTO mode changes (workspace `lto = "thin"` is upstream's choice; the production profile
  is fat LTO via `CARGO_PROFILE_RELEASE_LTO=fat`).
- Folding factor > 7 (proof-size cliff per exp5).
- FF=11 (1765 KiB, 14× target).

## Eval gates

### Correctness

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo test --workspace --release --quiet
RUSTFLAGS="-C target-cpu=native" cargo fmt --all -- --check
RUSTFLAGS="-C target-cpu=native" cargo clippy --workspace --all-targets -- -D warnings
```

All three must pass. fmt + clippy mirror upstream CI.

### Performance

```bash
cd ~/zk-autoresearch
bash harness/leanmultisig/scripts/eval_paired.sh --candidate pw-minmax
```

The gate builds `prove_loop` (production profile: fat LTO + `codegen-units = 1`) for
both baseline (`perf/poseidon-fft-mmo` or `origin/main` once merged) and candidate,
runs `prove_loop 5`, extracts warm-proof times (proofs 2-5), and runs Welch's t-test.

**Decision rule:**
- **Keep** if `delta_pct ≤ -1.0` AND `p_value < 0.01`.
- **Discard** otherwise.

For changes that affect proof size (most of Direction 1, Direction 2): also report
proof size delta from `cargo run --release -- xmss --n-signatures 1550 --log-inv-rate 1`
and apply the scoring rule `net = -delta_pct - 3 × proof_size_increase_pct`. Keeps must
have `net ≥ +1`.

### Reproducer command (always include in PR)

```bash
CARGO_PROFILE_RELEASE_LTO=fat \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
RUSTFLAGS="-C target-cpu=native" \
cargo run --release -- xmss --n-signatures 1550 --log-inv-rate 1
```

## Iteration loop

1. **Re-confirm baseline.** First iteration: run `prove_loop 5` on `perf/poseidon-fft-mmo`
   (or `origin/main` if merged) and verify warm avg ≈ 2.00 s. If off by more than 2%,
   debug environment before continuing.

2. **State a hypothesis** with magnitude prediction. Reference the relevant code/profile.

3. **Implement one change.** One logical change. Smallest viable diff.

4. **Commit:** `pw-minmax-<iter>: <description>`.

5. **Correctness gate.** Fail → `git revert HEAD`, log `discard`, next iter.

6. **Performance gate.** Pass → log `keep`. Fail → `git revert HEAD`, log `discard`.

7. **After each keep,** re-run profiling on the new HEAD before the next iteration —
   the bottleneck distribution shifts. Don't optimize against a stale model.

8. **After each keep, switch lever.** Don't apply the same change pattern back-to-back
   (e.g., two arity tweaks in a row). The next iter should target a different surface
   from the seeded list or freeroam.

Every iteration commits — `git revert`, never `reset`. The audit trail is the experiment.

## Logging

Append to `experiment_logs/leanMultisig/experiment_pw_minmax/iters.tsv`:

```
iter	direction	predicted_pct	measured_pct	p_value	proof_kib	net_score	status	commit	rationale
```

Use `direction` = 1-5 for seeded directions; `freeroam-<short-tag>` for self-formed
hypotheses. `predicted_pct` is your magnitude prediction *before* running the gate.

## Stop criterion

- 12 consecutive discards → pause and report findings.
- 3 successive seeded directions yielding null after one earnest attempt each →
  prioritize freeroam.
- Cumulative gain ≥ -5% e2e (i.e., -10.5% from `origin/main` baseline) → pause and
  consult before pushing further; we may want to ship the next bundle.

## Never stop

Run autonomously between checkpoints. Every iteration teaches something — discards
narrow the search space, keeps compound. Profile before, hypothesize, measure, log,
repeat. If you stall, re-profile and pick up the next direction.
