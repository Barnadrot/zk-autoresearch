# leanMultisig — Poseidon1 call-site attribution (Group K #1 from blind survey)

## Role

You are a performance instrumentation engineer. Your job: deliver **exact per-call-site attribution data for every Poseidon1 invocation in the leanMultisig prove_loop workload**, so the team can stop estimating from `%-of-cycles` profiles and rank optimization candidates against ground truth.

You do NOT optimize. You do NOT change protocol behavior. You instrument, measure, classify, and report. The output is a single artifact: a comprehensive call-site report.

You are running on Hetzner CCX33 (AMD Ryzen 7 PRO 8700GE Zen 4, 8c/16t, 64 GiB RAM, AVX-512).

## Why this matters (one paragraph context, do not over-read)

Today's profile (`brain/report/profiling_leanmultisig_main.md` and `brain/report/post_pr216_profile.md`) splits Poseidon1 into "~30% of cycles, distributed across permute_mut monomorphizations" — but **cycle attribution is sample-based and breaks down post-PR-216 because of `#[inline]` collapsing multiple call sites into one frame**. A blind survey identified 49 optimization candidates ranked by guessed magnitude; ranking those is the actual blocker. This experiment delivers the ranking truth.

## Repo & setup

| Repo | Path | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `instrument/poseidon-call-sites-2026-05-11` (branch from current `origin/main`) |

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout origin/main
git checkout -b instrument/poseidon-call-sites-2026-05-11
```

## Procedure

### Phase 1 — Enumerate call sites (~30 min)

Find every Poseidon1 invocation reachable from `prove_loop`. Use grep + read; do not skip sites:

```bash
grep -rn "permute_mut\|compress_mut\|hash_slice\|mmo_hash\|sample_many\|observe_scalars" crates/ \
  --include="*.rs" \
  -l
```

For each call site found, record:
- Source file + line
- Caller context (what subsystem: Merkle / FS / bytecode / XMSS / recursive verifier / etc.)
- Input shape (state width, RATE, OUT, single perm vs sponge)

**Expected call-site classes** (do not limit yourself to these; enumerate exhaustively):
- WHIR Merkle first layer (`first_digest_layer` / leaf hashing)
- WHIR Merkle round layer (`compress_layer` / internal compression)
- WHIR query-phase Merkle verification
- Fiat-Shamir challenger (`Challenger::observe`, `Challenger::sample_many`)
- Compiler bytecode hashing
- XMSS chain hashing (`crates/xmss/`)
- Recursive aggregation verifier (`crates/rec_aggregation/`)
- AIR-side Poseidon evaluation (`crates/lean_vm/src/tables/poseidon_16/`)
- Anywhere else that the grep surfaces

Save the enumeration to `experiment_logs/leanMultisig/poseidon_call_sites_2026-05-11/call_sites_inventory.md`.

### Phase 2 — Instrument with feature-gated atomic counters (~1-2 hours)

Add per-call-site atomic counters in `crates/utils/src/` (or a new `crates/poseidon-telemetry/` if cleaner). Each counter is `AtomicU64` keyed by site. **Feature-gate behind `poseidon-call-sites`** so production builds pay zero cost:

```rust
// crates/poseidon-telemetry/src/lib.rs (suggested)
#[cfg(feature = "poseidon-call-sites")]
pub mod counters {
    use std::sync::atomic::{AtomicU64, Ordering};
    pub static MERKLE_FIRST_LAYER: AtomicU64 = AtomicU64::new(0);
    pub static MERKLE_ROUND_COMPRESS: AtomicU64 = AtomicU64::new(0);
    pub static FS_CHALLENGER_OBSERVE: AtomicU64 = AtomicU64::new(0);
    pub static FS_CHALLENGER_SAMPLE: AtomicU64 = AtomicU64::new(0);
    pub static BYTECODE_HASH: AtomicU64 = AtomicU64::new(0);
    pub static XMSS_CHAIN: AtomicU64 = AtomicU64::new(0);
    pub static RECURSIVE_VERIFIER: AtomicU64 = AtomicU64::new(0);
    pub static AIR_POSEIDON_EVAL: AtomicU64 = AtomicU64::new(0);
    // ...one per site you found
}

#[macro_export]
macro_rules! bump_counter {
    ($name:ident) => {
        #[cfg(feature = "poseidon-call-sites")]
        $crate::counters::$name.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    };
}
```

At each Poseidon1 call site, insert:
```rust
poseidon_telemetry::bump_counter!(MERKLE_FIRST_LAYER);
// existing permute_mut / compress / hash call
```

**Hard constraints on the instrumentation:**
- Counters MUST be feature-gated. Default builds compile to zero code.
- Use `Ordering::Relaxed` — we don't need synchronization, only correct totals.
- Do NOT add allocation. Counters are static atomics.
- Do NOT add logging at the call site. Only the counter bump.
- Do NOT change protocol behavior. Bit-identical proof outputs verified at the end.

### Phase 3 — Dump + verify (~30 min)

Add a dump function called at the end of `prove_loop` main (also feature-gated):

```rust
#[cfg(feature = "poseidon-call-sites")]
{
    eprintln!("poseidon_call_sites_counters:");
    eprintln!("  merkle_first_layer       = {}", MERKLE_FIRST_LAYER.load(Ordering::Relaxed));
    eprintln!("  merkle_round_compress    = {}", MERKLE_ROUND_COMPRESS.load(Ordering::Relaxed));
    // ...
}
```

Build with the feature:
```bash
cd ~/zk-autoresearch/harness/leanmultisig/bench
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop \
    --features "zkalloc_global,poseidon-call-sites"
```

Run `prove_loop 5` and capture counters. Save to `counters_raw.txt`. Compute per-proof rates (divide by warm proof count = 4).

### Phase 4 — Cycle attribution cross-reference (~30 min)

Build a **non-instrumented** binary (default features, no `poseidon-call-sites`) for clean cycle profiling:

```bash
cargo build --release --bin prove_loop --features zkalloc_global
perf record -F 997 --call-graph dwarf -- target/release/prove_loop 3
perf report --stdio --no-children | head -200 > perf_report.txt
```

For each Poseidon1 call site identified in Phase 1, look up its source location in the perf report's call-stack expansion. Record:
- Cycles attributed to this site
- % of total cycles
- Cross-check: cycles ÷ count = cycles per permutation. Should be roughly constant across sites (~5000-15000 cycles per permutation on AVX-512); huge variation signals an attribution problem.

Save to `cycles_per_call_site.tsv`.

### Phase 5 — Recursed-vs-not classification (the J.3 audit, ~1-2 hours)

For each call site, classify whether its output is **reproduced inside an AIR constraint** (the recursive verifier proves it by re-computing inside its own circuit) vs **prover-side-only** (only the native prover and native verifier compute it).

For each site, write 2-3 sentences:
- What is hashed
- Where the hash output flows to
- Does the recursive AIR re-compute this hash inside a constraint? Yes/No/Audit-uncertain
- If Yes: cite the AIR constraint file/line
- If No: cite the verifier code that consumes the hash natively

This is the most cognitively demanding phase. Take your time. If a site is "Audit-uncertain," flag it clearly — the user will resolve.

**Hypothesis to test:** prover-side-only hashes can be swapped to Blake3 (~40× faster native than Poseidon1 on Zen 4) without protocol changes. Sites currently expected to be prover-side-only:
- Compiler bytecode hash
- FS challenger
- XMSS chain (some configurations)

Sites currently expected to be recursed:
- WHIR Merkle internal compression
- Recursive aggregation verifier inner Poseidon

Verify or refute these expectations with code-trace evidence.

### Phase 6 — Final report (~30 min)

Produce `experiment_logs/leanMultisig/poseidon_call_sites_2026-05-11/poseidon_call_sites_report.md`:

```markdown
# Poseidon1 call-site attribution report — 2026-05-11

## Method
<commands run, perf params, build config>

## Summary
| Call site | Calls/proof | % of total Poseidon | Cycles/proof | % of total cycles | AIR-recursed? |
|---|---|---|---|---|---|
| merkle_first_layer | N | X% | Y | Z% | YES/NO/AUDIT |
| ... | | | | | |

## Per-site detail
### merkle_first_layer
- Source: <file>:<line>
- What's hashed: <description>
- Output flows to: <consumer>
- AIR-recursed: YES (cite AIR constraint file/line) | NO (cite native consumer) | AUDIT (explain)
- Blake3 swap candidate: YES if NOT recursed, NO otherwise
- Expected impact if swapped: <% of total cycles>

(... repeat for every site ...)

## Findings
1. Total Poseidon cycles per proof: ~X (Y% of total)
2. Of that, prover-side-only (Blake3-swap-eligible): ~A (B% of total)
3. Of that, AIR-recursed (must stay Poseidon): ~C (D% of total)
4. Audit-uncertain (needs user/Emile review): ~E (F% of total)

## Implications for the optimization ranking
- Group J upper bound: B% of total cycles (the prover-side-only share)
- Group C #1 ceiling: 40% of (B + C)% (Poseidon's full share)
- Group E #1 ceiling: similar, but only Poseidon partial-round latency surface
- Group B+G affects N_merkle_compresses → the C+D portion's count, not cost
```

### Phase 7 — Draft PR body (per coordinator handoff)

Per the architecture's outbound flow, draft `experiment_logs/leanMultisig/poseidon_call_sites_2026-05-11/pr_body.md` for brain to review.

**The PR is the instrumentation itself (feature-gated, zero-cost-default).** Title: `instrument: feature-gated Poseidon1 call-site counters`. Body explains the call-site inventory + the data the report contains. Brain decides whether to upstream this to leanMultisig or keep it local to zk-autoresearch.

Do NOT push the branch. Do NOT open the PR. Brain does both.

## Stop criterion

All Phase 1-6 deliverables exist:
- `call_sites_inventory.md` — every call site found
- `counters_raw.txt` — measured counts from a feature-on run of `prove_loop 5`
- `cycles_per_call_site.tsv` — cycle attribution cross-reference
- `poseidon_call_sites_report.md` — final report with per-site detail + summary table
- `pr_body.md` — PR draft for brain

Every counter has a non-zero count after a `prove_loop 5` run. Every site has a recursed/not classification (even if AUDIT-uncertain).

## Hard constraints

- **Counters feature-gated.** Default builds compile to zero code. No production cost.
- **No protocol behavior change.** Final correctness gate (`harness/leanmultisig/correctness/correctness.sh`) must pass after instrumentation.
- **No optimization.** This is data collection only. Do not rewrite hot paths "while you're in there."
- **No PR open.** No branch push. Brain handles submission.
- **Commit-after-each-phase.** Phase 1 commit, Phase 2 commit, etc. So if the experiment is interrupted, partial progress survives.

## Hardware-specific notes

- Hetzner Zen 4 + AVX-512: same machine as PR #216 was developed on. `perf` access enabled (`perf_event_paranoid = -1` per memory).
- Use `RUSTFLAGS="-C target-cpu=native"` for the production build (or measurements don't reflect AVX-512 reality).
- Stable rust toolchain; respect the workspace's Cargo.lock if it's checked in.

## Why no iters.tsv

This isn't a perf optimization loop — there's no keep/discard. The deliverable is a single report. Phase commits give the audit trail.

---
*Experiment program. Single-pass instrumentation work. Drafted 2026-05-11 for dispatch via the coordinator pipeline.*
