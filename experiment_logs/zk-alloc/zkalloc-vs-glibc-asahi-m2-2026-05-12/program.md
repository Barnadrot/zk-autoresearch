# zk-alloc vs system malloc — paired N=5 on M2 Asahi Linux (clean re-measure)

## Role

You are a performance investigator running on **Asahi Linux 6.14 on Apple M2** (Scaleway M2-M Asahi rental). Job: re-measure the zk-alloc-vs-glibc delta cleanly with current leanMultisig + zk-alloc HEAD. The prior +3.4% number is suspected stale (predates zk-alloc PRs #11 and #12). Single deliverable: a delta number + a one-paragraph verdict.

Read-only. No source changes.

## Hardware

- Apple M2 (Mac mini, NOT M2 Pro — 8c, 4P+4E, base chip), Asahi Linux 6.14.2-401.asahi.fc42.aarch64+16k
- 16 GiB RAM, 16 KiB native page size
- NEON 128-bit, no AVX. Apple PMU exposes cycles/instructions per cluster.

## Why this re-measure

Canonical zk-alloc vs glibc deltas in memory `project_leanmultisig_uses_zkalloc.md`:

| Workload / Platform | OS / libc | zk-alloc Δ |
|---|---|--:|
| leanMultisig / Hetzner Zen 4 + AVX-512 | Linux / glibc | **+25%** |
| leanMultisig / MacBook M4 | macOS | +10% |
| leanMultisig / M2-L Scaleway (measured 2026-05-12) | macOS Sequoia | +9.24% |
| **leanMultisig / M2 Asahi** | **Linux / glibc** | **+3.4% — SUSPECTED STALE** |

The +3.4% Asahi number predates recent zk-alloc shipped PRs (#9 slab routing, #11 size-routing fix, #12 assert-flat-phase). One of those may have unlocked a larger Asahi win. Today's macOS M2 Pro +9.24% on the same chip family suggests the Asahi number should at minimum match the macOS one.

## Phase 1 (only phase) — paired N=5

Build two binaries from current `origin/main` of leanMultisig:

```bash
cd ~/zk-autoresearch/leanMultisig
git fetch origin
git checkout origin/main
git rev-parse --short HEAD  # record for verdict
git log -1 --pretty=format:'%h %s' -- ../zk-alloc  # also record zk-alloc HEAD

cd ~/zk-autoresearch/harness/leanmultisig/bench

# zk-alloc binary (production config — fat LTO, target-cpu=native)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop --features zkalloc_global
cp target/release/prove_loop /tmp/prove_loop_zkalloc
md5sum /tmp/prove_loop_zkalloc

# system malloc binary (glibc default — no zkalloc_global feature)
RUSTFLAGS="-C target-cpu=native" cargo build --release \
    --bin prove_loop
cp target/release/prove_loop /tmp/prove_loop_sysmalloc
md5sum /tmp/prove_loop_sysmalloc
```

Confirm each binary prints the expected allocator banner at launch (zkalloc prints `zkalloc_global — #[global_allocator] mode`; sysmalloc has no allocator banner).

**Memory hygiene** (Linux equivalent of `sudo purge`):

```bash
sudo sync && sudo swapoff -a && sudo swapon -a
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

**Paired N=5 with alternating order:**

```bash
ROUNDS=5
ITERS=5
for r in $(seq 1 $ROUNDS); do
    if [ $((r % 2)) -eq 1 ]; then ORDER="sysmalloc first"; A=/tmp/prove_loop_sysmalloc; B=/tmp/prove_loop_zkalloc
    else                          ORDER="zkalloc first"; A=/tmp/prove_loop_zkalloc; B=/tmp/prove_loop_sysmalloc
    fi
    echo "=== Round $r ($ORDER) ==="
    A_TIME=$(/usr/bin/time -p "$A" $ITERS 2>&1 | awk '/real/{print $2}')
    sleep 1
    B_TIME=$(/usr/bin/time -p "$B" $ITERS 2>&1 | awk '/real/{print $2}')
    echo "A: $A_TIME, B: $B_TIME"
done | tee phase_1_paired.log
```

Compute per-round delta as `(zkalloc − sysmalloc) / sysmalloc`. Negative = zk-alloc wins.

## Phase 2 — Verdict writeup

Single file: `verdict.md`. Include:

1. **Headline number** — mean Δ ± stddev, range. State leanMultisig HEAD + zk-alloc HEAD shas.
2. **Per-round table** — 5 rows.
3. **Comparison to prior stale +3.4%** — explicitly state whether the number moved and by how much. Hypothesize which PR (#9 / #11 / #12) most likely contributed if the gap is large.
4. **Cross-platform table** — Hetzner +25%, MacBook M4 +10%, macOS M2 Pro +9.24%, **Asahi M2 (this run) — measured**, plus the stale +3.4% in parentheses.
5. **Question to answer:** Why is Asahi the SMALLEST Linux number despite running on the same M2 silicon? Speculate based on the new measurement (could it be page-size 16 KiB vs Hetzner 4 KiB? CPU microarch? Working-set fit differences?). One paragraph.

## Stop criterion

`verdict.md` exists with 5 rounds of data, the headline delta, comparison to prior, and the cross-platform table.

## Hard constraints

- **Read-only.** No leanMultisig / zk-alloc source changes.
- **N=5 paired with alternating order.** Order bias is real.
- **Memory hygiene before the run.** Swap-cycle + drop_caches.
- **No PR push.** Brain handles whatever decision follows.
- **No profiling scope-creep.** Just the delta + verdict.
- **Build with `RUSTFLAGS="-C target-cpu=native"` and `--features zkalloc_global` for the zkalloc binary.** Production config.

## Why this matters

The stale +3.4% Asahi number is the OUTLIER in the cross-platform zk-alloc table. If the re-measure brings Asahi into family with macOS (~+9-10%) or Hetzner (~+25%), the paper/deployment story becomes clean. If it stays an outlier, that itself is the finding — and points to an Apple-Silicon-on-Linux memory-subsystem effect worth a follow-up investigation.

---
*Tight re-measure. Drafted 2026-05-12 after macOS M2 Pro +9.24% result surfaced that the Asahi +3.4% reference predates recent zk-alloc PRs.*
