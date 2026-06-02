# leanMultisig — Apple Silicon (M2 / Asahi) baseline + deep profile

This is a **one-shot, fresh-context** prompt for an autonomous agent. Read it end to
end and execute. You produce two artifacts and stop. We then sync — no optimization
iterations in this run.

## Hardware & OS

You are running on an **Apple Silicon M2** machine in **Asahi Linux** (Fedora 42,
kernel 6.14, page size **16 KiB**, aarch64). NEON SIMD (128-bit), no AVX-512, no AMX,
no Metal. This is full-performance Linux on Apple Silicon CPU — ~95-100% of macOS
native CPU perf for compute-bound work.

## Repos (already cloned by setup script)

| Repo | Path | Branch |
|------|------|--------|
| zk-autoresearch | `~/zk-autoresearch` | current |
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `main` (PR #216 merged: confirm by looking for `pw3-13`, `RATE=12`, `MMO`, `#[inline]` commits in `git log --oneline | head -20`) |
| zk-alloc | `~/zk-autoresearch/zk-alloc` | `main` |
| Plonky3 | `~/zk-autoresearch/Plonky3` | `main` (reference only) |

## Why this profile matters

On the Hetzner Zen 4 + AVX-512 production benchmark, the prover is **compute-bound,
not memory-bound**, with `IPC = 0.91`, cache-miss rate `3.57%`, LLC bandwidth at 7.8%
of DDR5 ceiling. Cycle attribution: Poseidon ≈ 40% (`permute_mut` 34% + AIR eval
6.5%), sumcheck/GKR ≈ 14%. The full reference profile lives at:

```
~/zk-autoresearch/experiment_logs/leanMultisig/benchmark_pw3_pr/profiling_main.md
```

**Read it before starting** — your M2 profile mirrors that structure section by
section so we can compare directly.

The compute-bound regime depends on **zk-alloc working correctly**. zk-alloc is the
production global allocator (`src/main.rs:5-6`). Without it (i.e. with `--features
standard-alloc`), the workload becomes allocator-bound and the profile is misleading.
Validating zk-alloc on aarch64 + 16 KiB pages is therefore prerequisite to the
baseline number, not optional. That is why steps 1 and 4 are merged below.

## Long-term context (DO NOT optimize toward this in this run)

Justin's M-series target is **1000 XMSS/s on older Macs**. Your M2 Asahi number is a
strong proxy for what's achievable on M1 macOS (M2 ≥ M1 in single-core; Asahi ≈
macOS-native CPU perf for compute-bound code). Compute and report the gap factor —
do not attempt to close it in this run.

---

## Step 1+4 — baseline with validated zk-alloc

Before recording any baseline, prove that zk-alloc compiles, links, runs, and
actually does useful work on this machine. A baseline measured with broken or
silently-degraded zk-alloc is misleading.

### 1a. Build with zk-alloc (default features)

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo build --release 2>&1 | tee /tmp/m2_build_zkalloc.log
```

Confirm build succeeds. Confirm zk-alloc symbols are in the binary:

```bash
nm target/release/lean-multisig 2>/dev/null | grep -iE "zk_alloc|ZkAllocator" | head -5
```

If link or build fails: capture full error to
`experiment_logs/leanMultisig/benchmark_m2/build_failure.md`, write the report
section "Step 1 failed" with diagnosis, and stop. Do NOT continue silently with
standard-alloc or any workaround.

### 1b. Smoke test (small instance, fail fast)

```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" timeout 120 cargo run --release -- xmss --n-signatures 100 --log-inv-rate 1 \
  > /tmp/m2_zkalloc_smoke.log 2>&1
echo "exit_code=$?"
```

Must produce a valid proof and exit 0. If it OOMs, panics, hangs, or returns a
non-zero exit code, **stop and document the failure**. This would be a major
diagnostic finding — it would mean zk-alloc has an aarch64 or 16 KiB-page problem
distinct from the macOS Mach-VM issue Thomas/Emile reported. Capture stderr
verbatim, save it as `experiment_logs/leanMultisig/benchmark_m2/zkalloc_failure.md`,
write the report section, and stop.

### 1c. zk-alloc vs standard-alloc on the production workload

Run both full-size workloads (1550 sigs, log_inv_rate=1). The xmss CLI does its own
warmup proof so a single invocation per allocator is enough; if the second per-proof
time is unstable, do 2 more runs and take the median.

```bash
# zk-alloc (default) — production config
RUSTFLAGS="-C target-cpu=native" cargo run --release -- \
  xmss --n-signatures 1550 --log-inv-rate 1 \
  2>&1 | tee /tmp/m2_zkalloc_1550.log

# standard-alloc (libmalloc/glibc baseline) — comparison only
RUSTFLAGS="-C target-cpu=native" cargo run --release --features standard-alloc -- \
  xmss --n-signatures 1550 --log-inv-rate 1 \
  2>&1 | tee /tmp/m2_stdalloc_1550.log
```

Extract from each: `XMSS/s`, `time per proof`, `proof KiB`, `cycles`, `memory`,
`poseidons`, `extension-ops`. The xmss CLI prints these in a tracing line.

### 1d. Validation + baseline verdict

The decision rule:

- **If zk-alloc XMSS/s ≥ standard-alloc XMSS/s:** zk-alloc is healthy on this
  machine. The **M2 baseline is the zk-alloc number.** Proceed to step 2.
- **If zk-alloc is slower than standard-alloc** by more than a small margin (~3%):
  this **replicates the macOS regression on Asahi**, isolating it to Apple Silicon
  hardware / 16 KiB pages rather than Mach VM. **This is a major diagnostic
  finding** — document it carefully in the report, but **continue to step 2** using
  the zk-alloc build (we still want the profile to compare to Hetzner's zk-alloc
  profile; standard-alloc would change too many variables).

Compute and report:

- `m2_asahi_xmss_s = <zk-alloc XMSS/s>`
- `gap_to_target = 1000 / m2_asahi_xmss_s`
- One-line phrasing: "M2 Asahi sits at X XMSS/s; the 1000-target is Yx away."

---

## Step 2 — deep profile (zk-alloc build only)

Mirror the structure of `benchmark_pw3_pr/profiling_main.md`. Six sections.

### Setup: enable perf for unprivileged use

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1
```

(The setup script already wrote this to `/etc/sysctl.d/99-perf.conf`, but the live
sysctl may not be set if perf was attempted before the file landed.)

### Q1 — Compute-bound vs memory-bound on M2

```bash
cd ~/zk-autoresearch/leanMultisig
perf stat -e task-clock,cycles,instructions,cache-references,cache-misses,branches,branch-misses \
  target/release/lean-multisig xmss --n-signatures 1550 --log-inv-rate 1 \
  2>&1 | tee /tmp/m2_perf_stat.log
```

Compute and report:

- IPC (instructions / cycles)
- Cache-miss rate (cache-misses / cache-references, %)
- Branch-miss rate
- Estimated DRAM bandwidth via cache-misses × 64 B / wall-clock — report as % of
  M2 DRAM theoretical ceiling (M2 unified memory ≈ 100 GB/s for the standard
  M2; if you can't establish the exact spec for this machine, document the
  assumption)
- Verdict: compute-bound or memory-bound. **Compare directly to Hetzner's**
  `IPC=0.91, cache-miss=3.57%, LLC=7.8% of DDR5 ceiling`.

### Q2 — Cycle attribution per function

```bash
sudo perf record -g --call-graph=dwarf -F 999 -o /tmp/m2_perf.data -- \
  target/release/lean-multisig xmss --n-signatures 1550 --log-inv-rate 1
sudo perf report --stdio --no-children --max-stack=20 -i /tmp/m2_perf.data \
  | head -200 > /tmp/m2_perf_report.txt
```

Extract:

- Top 15 hottest functions with %
- For `permute_mut`: each monomorphization separately, with its %
- AIR Poseidon eval cost
- Sumcheck/GKR cost
- Anything >5% that is NOT in the Hetzner top-15 (those are M2-specific finds)

### Q3 — Per-monomorphization Poseidon breakdown

Hetzner shows three `permute_mut` monomorphizations: 19.1% (initial Merkle commit),
5.6% (round Merkle), 5.2% (compiler bytecode). On M2, narrower SIMD (NEON 128-bit
vs AVX-512 512-bit) may shift these. Report each share for M2 and compare side-by-side.

### Q4 — Memory & allocation behavior

- Peak RSS (`/proc/$(pgrep lean-multisig)/status` `VmHWM`, captured during the run; if you can't grab it live, the xmss CLI's tracing line shows "used X.X GiB" — record that)
- Page-fault counts:
  ```bash
  perf stat -e page-faults,minor-faults,major-faults \
    target/release/lean-multisig xmss --n-signatures 1550 --log-inv-rate 1 \
    2>&1 | tee /tmp/m2_perf_pagefaults.log
  ```
- Compare to Hetzner: Hetzner with zk-alloc shows ~10.8 GiB arena pre-touch and few
  major faults. Does M2 with 16 KiB pages show different fault behavior than
  Hetzner with 4 KiB pages? With 4× larger pages, expected page-fault count is
  roughly 4× lower for the same arena size — verify this empirically.

### Q5 — Cross-architecture comparison table

A side-by-side table: M2 Asahi vs Hetzner Zen 4 + AVX-512. Same workload (`xmss
--n-signatures 1550 --log-inv-rate 1`), same prover, same zk-alloc allocator.
Columns:

- Wall-clock per proof
- XMSS/s
- IPC
- Cache-miss rate
- Estimated DRAM bandwidth utilization
- Top 5 functions and their %

After the table, write 2-3 sentences on the most striking differences in plain
language.

### Q6 — Implications for M2-specific perf work

3-5 bullets, data-driven. Examples to illustrate the format (do NOT predetermine —
let what you measured drive the bullets):

- "Poseidon is X% on M2 vs 40% on Hetzner because [reason from data]. NEON-specific
  Poseidon micro-tuning would have [more / less / similar] leverage than on Hetzner."
- "Sumcheck moved from 14% on Hetzner to Y% on M2 — [becomes / doesn't become] a
  viable target."
- "Memory bandwidth utilization is Z% of M2's ~100 GB/s ceiling vs 7.8% of DDR5
  ceiling on Hetzner — [memory-touchy / compute-touchy] code is [more / less] of a
  bottleneck here."
- Pick one or two M2-specific candidates that emerge from the profile (PGO on
  aarch64, 16 KiB-page-friendly arena layout, NEON-specific FMA pairing — only
  list ones the profile actually points at).

This section seeds the next experiment. Don't run it; just propose.

---

## Output

Write **one** report file:

```
experiment_logs/leanMultisig/benchmark_m2/m2_profile.md
```

Structure:

1. Hardware/software environment (`uname -a`, `cargo --version`, `getconf PAGESIZE`, `nproc`, `free -h`)
2. Step 1+4 results: zk-alloc validation + baseline numbers + gap-to-target
3. Step 2 deep profile: Q1 through Q6
4. Raw `perf stat` and `perf report` output appended at the end (entire `/tmp/m2_perf_stat.log`, top of `/tmp/m2_perf_report.txt`)

Do NOT create an `iters.tsv` — this is not an iterative experiment.

If anything in step 1 fails permanently (build, link, smoke test): write the report
with a "Step 1 FAILED" section explaining what happened, save the failure artifact
under `benchmark_m2/`, and stop. Do not proceed to step 2.

If step 1 surfaces the zk-alloc-slower-than-standard-alloc finding: continue with
step 2 on the zk-alloc build, document the regression as a major finding in step 1d
of the report, and explicitly call out in Q6 that the M2 zk-alloc story now needs
its own follow-up.

## Final ping

When done, post a 5-line summary in this exact shape:

```
M2 Asahi baseline + profile complete.
- zk-alloc validation: PASS / FAIL (one-line reason if FAIL)
- XMSS/s (zk-alloc / standard-alloc): X / Y
- Gap to 1000 XMSS/s: Zx
- Verdict (compute-bound / memory-bound / other): <one phrase>
- Top profile finding: <one sentence>
```

Then stop. No further work — we sync on the report before designing the next step.
