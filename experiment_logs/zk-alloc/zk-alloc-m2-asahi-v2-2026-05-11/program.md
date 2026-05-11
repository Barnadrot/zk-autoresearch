# zk-alloc on M2 Asahi — v2 (allocator-only, target +10-15% vs glibc)

## Role

You are a systems performance engineer specializing in custom allocators on aarch64 / Apple Silicon. Your job: **find allocator-side wins for the leanMultisig prove_loop on M2 Asahi Linux that push us from the current +6% vs glibc baseline to +10-15% vs glibc.**

The surface you can change is **strictly zk-alloc internals**:
- `crates/backend/zk-alloc/src/lib.rs`
- `crates/backend/zk-alloc/src/syscall.rs`
- `crates/backend/zk-alloc/tests/*` (only if a regression test is needed)

**You may NOT change Poseidon, the WHIR Merkle code, AIR constraints, the harness, the recursive verifier, or any application code.** This is allocator tuning only. If you find a non-allocator surface that would yield more, surface it via `queue/needs-decision/` and continue with allocator work.

## Hardware (read this — it determines the lever set)

Apple Silicon M2 / Asahi Fedora 42, kernel 6.14.2-401.asahi.fc42.aarch64+16k:
- 10 cores: **6 P-core (avalanche, 8-wide decode, 128 KiB L1D, ~330-entry ROB)** + 4 E-core (blizzard, 3-wide decode, 64 KiB L1D)
- 16 GiB RAM + 8 GiB swap
- **16 KiB native page size, 32 MiB THP**
- NEON 128-bit SIMD (no AVX-512, no AMX, no Metal)
- No SMT

**Measured baseline IPC for prove_loop with zk-alloc (2026-05-11): 2.93 weighted** (3.72 P, 1.87 E). This is roughly 3× Hetzner Zen 4's leanMultisig IPC of 0.91. **M2 is NOT latency-bound by the Montgomery dependency chain the way Hetzner is** — superscalar OOO hides the chain. **The allocator wins on M2 come from different surfaces than on Hetzner:** TLB pressure (16 KiB pages cover less memory per entry), L1 cache pressure (P-core L1D is 128 KiB but shared with rayon workers), working-set-vs-RAM tightness (16 GiB total), and per-core lock contention shape (10 cores, no SMT, 2 clusters).

## The 6% baseline — what's already working

Measured 2026-05-11, 5-round paired N=5, clean memory state:
- glibc baseline: 2.7197 s avg warm proof
- zk-alloc: 2.5581 s avg warm proof
- **Δ = −5.94%** (range across rounds: −4.39 to −6.99)

This is the floor. Your candidate must NEVER regress below this against glibc. Run a `glibc-vs-current-zk-alloc` paired comparison at the start of the experiment (Phase 0) and on every keep, in addition to the per-iter and cumulative gates.

## Why v2 exists (the v1 lesson you inherit)

The previous experiment (`zk-alloc-m2-asahi`, ran 2026-05-11) shipped 3 "kept" iters (THP + pretouch + adaptive cap + size routing). Today's clean-state DD showed the rollup **regresses by +3.62%** vs the pre-experiment baseline (p ≈ 0, t = 11.30). Root causes:

1. **N=3 paired gate is insufficient on M2.** Higher round-to-round variance than Hetzner. v1's "−0.97%" cumulative claim was within the noise envelope. **N=5 minimum on every gate.**

2. **Per-iter gates miss cumulative drift.** Iter 8's local −2.51% was measured at 1 GiB pretouch. Iter 19's adaptive cap dropped pretouch to ~390 MiB on this box, silently giving back most of iter 8's win — but iter 19's local gate compared against an iter-18-revert baseline that ALSO had 1 GiB pretouch, so it saw +0.29% noise while the cumulative was +3pp regression. **Cumulative gate (HEAD vs Phase-0 baseline) every 3 iters and on every keep. If cumulative disagrees with per-iter sum, stop and investigate.**

3. **Pretouch tradeoffs on 16 GiB hardware are sharp.** iter 8's THP + 14 GiB anon-rss OOM-killed the gate twice. Adaptive cap (iter 19) avoided the OOM but voided iter 8's TLB-coverage benefit. **The whole pretouch class of optimizations is off-limits at iter ≤ 6 unless you can prove peak anon-rss stays under 12 GiB AND the cumulative gate confirms no working-set displacement.**

## Repo & setup

| Repo | Path | Branch |
|------|------|--------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | branch from `origin/fix_zkalloc` (= PR #215 tip, since Emile is busy and won't merge personally for a while). Create as `zk-alloc-m2-asahi-v2-2026-05-11` |

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git fetch myfork
git checkout origin/fix_zkalloc
git checkout -b zk-alloc-m2-asahi-v2-2026-05-11
```

PR #215 is `leanEthereum/leanMultisig:fix_zkalloc`. It includes Emile's recent zk-alloc work (rayon-flush, safe arena routing mirroring zk-alloc#9, realloc-memmove + nested-phase mirroring zk-alloc#10) plus broader AIR/Poseidon1 refactor. **You inherit ALL of that as your base.** When #215 merges upstream you can rebase.

## Phase 0 — re-confirm baseline before iter 1

Before any optimization:

1. **Memory hygiene** — cycle swap + drop caches if dirty.
2. **Build both binaries from origin/fix_zkalloc** — glibc (no features) and zk-alloc (`--features zkalloc_global`).
3. **Run 5-round paired N=5** between them.
4. **Record the baseline number** — must reproduce the −5.94% mean (or thereabouts). If it does not, debug the environment before optimizing.
5. **Save the baseline glibc + zk-alloc avgs** to `phase_0_baseline.txt`. Every cumulative gate compares against these.

## Eval gates (the v2 discipline — non-negotiable)

### Pre-gate memory hygiene

```bash
SWAP_USED=$(free | awk '/^Swap:/{print $3}')
MEM_USED=$(free | awk '/^Mem:/{print $3}')
MEM_TOTAL=$(free | awk '/^Mem:/{print $2}')
if [ "$SWAP_USED" -gt 100000 ] || [ "$MEM_USED" -gt $((MEM_TOTAL * 75 / 100)) ]; then
    sudo sync && sudo swapoff -a && sudo swapon -a
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
fi
```

Run before every gate. Refuse to gate if cleanup fails repeatedly (escalate).

### Correctness gate

`harness/leanmultisig/correctness/correctness.sh` — binary pass/fail. Must pass before any benchmark.

### Per-iter paired gate (zk-alloc vs zk-alloc, code change at HEAD)

```bash
bash harness/leanmultisig/scripts/eval_paired.sh \
  --baseline HEAD~1 --candidate HEAD \
  --n 5 --proofs 5
```

**N=5 is mandatory.** Exit 0 = keep, 1 = discard.

### Cumulative gate (HEAD vs Phase-0 zk-alloc baseline) — every 3 iters + every keep

```bash
ITER0=$(git rev-parse origin/fix_zkalloc)
bash harness/leanmultisig/scripts/eval_paired.sh \
  --baseline $ITER0 --candidate HEAD \
  --n 5 --proofs 5
```

Interpretation:
- Cumulative Δ ≤ −1.0% (p < 0.01): GREEN, continue
- Cumulative Δ in [−1.0%, +0.5%]: YELLOW, investigate before next iter
- Cumulative Δ > +0.5%: **STOP**, surface to brain via `queue/needs-decision/`

### Anti-regression gate (current build vs glibc) — every keep

Build current state with `--features zkalloc_global` AND without features (glibc baseline). Paired N=5. Verify the gap is ≤ −5% (not worse than Phase 0's −5.94%). If it is, your kept iter has invalidated zk-alloc's basic premise — discard the iter, surface to brain.

## Allocator-only lever inventory (what's available — pick from here)

These are zk-alloc-internal levers grouped by surface. **The v1 experiment exhausted some; you're picking from the unexplored ones.**

### Already explored in v1 (skip unless you have a structural new angle)

- `MIN_ARENA_BYTES` tuning at constants 4096 / 256 / 1024 / 64 — all measured, local optima identified
- `SLAB_SIZE` tuning at 4 / 8 / 16 GiB — 8 GiB confirmed local optimum
- `SLACK` tuning at 2 / 4 / 6 — 4 confirmed local optimum
- `PRETOUCH_BYTES` tuning at 0.75 / 1 / 1.25 / 1.5 GiB constants — 1 GiB confirmed local optimum if you ship pretouch (which you should NOT on 16 GiB — see hard constraint)
- Eager pre-touch via manual stride — kept locally but regresses cumulatively
- MADV_POPULATE_WRITE-based pre-touch — caused OOM, infrastructure failure
- Cache-line padding GENERATION / ARENA_ACTIVE / REGION_BASE statics — measured, sub-1% noise-bound
- Dropping `ARENA_ACTIVE` check from alloc fast path — measured 3 times, all sub-1% noise

### Underexplored on M2 — start here (priority order)

#### Direction 1 — TLB pressure: slab base-address coloring vs 16 KiB pages

**Hypothesis:** M2's 16 KiB native pages mean DTLB entries cover less working set than Hetzner's 4 KiB. The current SLAB_SIZE = 8 GiB × 14 slabs = 112 GiB virtual address span. Each slab's base address modulo TLB-set associativity determines whether per-thread slabs collide in TLB. Spread slab bases across cache colors / TLB sets explicitly.

**Where:** `ensure_region()` in `src/lib.rs`. The current code does `next_multiple_of(THP_SIZE)` for the base; consider per-slab offsets that explicitly spread mod-set-associativity.

**Predicted magnitude:** −1 to −3% (TLB pressure isolated; reduces miss rate in `compress_mut` working set).

**Risk:** Low. Address arithmetic only.

#### Direction 2 — Per-allocation fast-path microarchitecture (Apple-Silicon-specific)

**Hypothesis:** zk-alloc's `alloc()` fast path currently checks `ARENA_ACTIVE` + slab-base + size routing. On M2's 8-wide P-core decoder, the fast path's branch sequence may be suboptimally predicted. Restructure as branchless arithmetic where possible (Direction 6 in v1's pw_minmax tried this with `wrapping_sub`; revisit with explicit branchless macros).

**Where:** `pub fn alloc()` and the per-thread slab advance logic.

**Predicted magnitude:** −0.5 to −2%. Each allocation saves nanoseconds; multiplied across N allocations.

**Risk:** Low-medium. Compiler may already do this; measure carefully.

#### Direction 3 — Multi-slab parallel arena per worker

**Hypothesis:** Today each rayon worker has one slab. M2 has 10 cores, 14 slabs, SLACK=4. What if each worker had access to 2 slabs (one for sub-page, one for page-or-bigger), reducing intra-slab pointer-bump contention on shared cache lines for small allocations?

**Where:** thread_local `ARENA_PTR` machinery. Possibly add a separate small-alloc slab.

**Predicted magnitude:** −1 to −3% if small-alloc routing is on the critical path; smaller if not. Won't know without measurement.

**Risk:** Medium. Memory growth (2× slab count); verify peak RSS stays under 12 GiB.

#### Direction 4 — Apple Silicon page-aware mmap layout

**Hypothesis:** Apple Silicon's TLB hierarchy has a hardware-specific sweet spot for huge-page coverage. M2's THP is 32 MiB, but the working set per slab is probably 5-8 GiB. Audit whether the slab is accessed in a pattern that benefits from THP at all (vs base 16 KiB pages, which may be enough given the small working-set-per-slab vs DTLB-entry-count ratio).

**Where:** `ensure_region()` MADV hints. Measure both MADV_HUGEPAGE and MADV_NOHUGEPAGE on aarch64; do not assume HUGEPAGE wins.

**Predicted magnitude:** Unknown — could go either direction. Worth a controlled measurement.

**Risk:** Low. If both directions noise-bound, drop and move on.

#### Direction 5 — Conservative pretouch only on the small (< 1 GiB) range

**Hypothesis:** Iter 8's full 1 GiB-per-slab pretouch OOMs on 16 GiB. But the FIRST few pages of each slab DO get hot quickly (allocator metadata + first bump bytes). A tiny pretouch of just the first 32 MiB per slab (= one THP page) may give the synchronous-THP benefit at the high-frequency portion without the OOM cost.

**Where:** `ensure_region()` pretouch loop.

**Predicted magnitude:** −0.5 to −2% if THP promotion on the first hugepage matters; zero if khugepaged already covers this on the warm-up proof.

**Risk:** Medium. Pretouch is OFF-LIMITS at iter ≤ 6 per the hard constraint, but THIS specific variant (≤ 32 MiB per slab = ≤ 0.5 GiB total) has bounded anon-rss cost. **Bring this up at iter 7+ AND only after surfacing the plan via `queue/needs-decision/` for brain to approve.**

#### Direction 6 — Allocation metadata compression

**Hypothesis:** Each thread-local `ARENA_PTR` + slab-base entry costs cache-line padding to avoid false sharing. If the metadata layout is suboptimal (split across cache lines or overlapping with rayon's own thread-locals), reorganize.

**Where:** thread_local declarations in `lib.rs`.

**Predicted magnitude:** −0.2 to −1%. Microarchitecture.

**Risk:** Low.

## Hard constraints

- **Allocator surface only.** No Poseidon, no Merkle, no AIR, no harness changes.
- **Pretouch off-limits at iter ≤ 6.** Any pretouch-related change after iter 7 must surface via `needs-decision` first AND prove peak anon-rss ≤ 12 GiB.
- **N=5 minimum on every gate.** Non-negotiable.
- **Cumulative gate every 3 iters AND every keep.** Catches v1's hidden drift.
- **Anti-regression gate vs glibc every keep.** Defends the −5.94% floor.
- **Predicted vs measured tracking in iters.tsv.** Required column.
- **One change per iter.** Isolation is the only way to attribute.
- **Commit-eval-decide.** `git revert` on discard, never `git reset`.
- **No PR push, no PR open.** Brain handles submission.

## iters.tsv schema

Append-only tab-separated:
```
iter\tdirection\tpredicted_pct\tmeasured_local_pct\tcumulative_pct\tvs_glibc_pct\tp_value\tstatus\tcommit\trationale
```

Where:
- `direction` = the lever family (D1-D6 above, or "freeroam-<short>")
- `predicted_pct` = your magnitude estimate BEFORE running the gate
- `measured_local_pct` = per-iter paired gate result
- `cumulative_pct` = HEAD-vs-Phase-0 result (refresh every 3 iters and every keep; cells in between can be `NA`)
- `vs_glibc_pct` = anti-regression gate result (refresh every keep; `NA` between)
- `status` = keep | discard | pause-for-investigation

## Stop criteria (any halts the loop)

1. **12 consecutive discards** (same as v1)
2. **Cumulative Δ > +0.5%** at any check — STOP, escalate
3. **vs_glibc gap shrinks below 5%** on any keep — STOP, candidate has eroded zk-alloc's basic premise
4. **Memory hygiene fails ≥3 times in a row** — infrastructure escalate
5. **Net negative score after 8 iters** — direction is wrong, escalate
6. **Hit cumulative −10% target** — you're done early; ship + write verdict

## Stretch target

Cumulative Δ ≤ **−4 to −9pp on top of the −5.94% floor** = total −10 to −15% vs glibc. This is ambitious — M2's allocator surface is smaller than Hetzner's because M2's IPC profile differs (2.93 vs Hetzner's 0.91). Hitting −10% is a win; −15% is a stretch. If you find legitimate keeps that compose, push for it. If the surface is exhausted at −7%, that's still a valid result — write it up.

## Why this is allocator-only despite the broader Poseidon survey

The blind Poseidon ideas survey at `brain/report/survey-poseidon-ideas-blind-2026-05-11.md` has 49 candidates including non-allocator surfaces (Group J = Blake3 swap, Group C = NEON batch interleave, etc.). Those are for **a different experiment**. This experiment is specifically pressure-testing how much the allocator alone can deliver on M2. The Poseidon work happens elsewhere (Hetzner-side, after the call-site report lands).

## Output (per architecture convention)

In this experiment dir:
- `phase_0_baseline.txt` — confirmed baseline numbers from Phase 0
- `iters.tsv` — append-only, schema above
- `verdict.md` — on stop, final summary with cumulative numbers + lessons
- `pr_body.md` — drafted PR body, brain reviews + submits

---
*Experiment program v2. Allocator-only scope. Drafted 2026-05-11 after v1 verdict invalidated by DD. Brain reviews this program before dispatch.*
