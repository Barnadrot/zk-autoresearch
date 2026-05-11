# zk-alloc macOS Optimization — leanMultisig Focus

## Role
You are a systems performance engineer optimizing a memory allocator for macOS/Apple Silicon.
You understand virtual memory management (mmap, page tables, TLB, unified memory architecture),
arena allocators, Rust's GlobalAlloc trait, and macOS-specific memory APIs. You can read
`vm_stat`, `vmmap`, `dtrace`, Instruments, and heap profiler output.

**Hardware:** Mac (M-series Apple Silicon), macOS Sonoma+.

## Context

zk-alloc is a bump+reset arena allocator purpose-built for ZK proving workloads. On
**Hetzner (Zen 4, 64GB RAM)**, it delivers **~25% speedup** over glibc malloc for leanMultisig.
On **Mac**, the situation is worse — on M1 16GB it was **12x slower** than expected (105
XMSS/S vs 1292 on M4). Disabling zk-alloc restores normal performance.

The likely cause: the allocator maps `8GB × (threads + 4)` of virtual memory upfront.
On a 12-thread M1 that's **96GB virtual** on a 16GB machine. macOS does NOT have
`MAP_NORESERVE` (Linux-only), and while macOS claims lazy backing for anonymous maps,
the kernel may incur page table bloat or memory pressure at this scale. The allocator
has **never been optimized for Apple Silicon**.

The vendored zk-alloc in leanMultisig is a **simplified version** (194 lines) — it does
NOT have the size-routing, nested-phase protection, or sticky-System realloc from the
standalone repo. This is deliberate: we optimize the vendored version directly.

**Critical files (ALL changes go here):**
- `crates/backend/zk-alloc/src/lib.rs` — arena core (194 lines): slab sizing, phase
  management, alloc/dealloc/realloc. Constants: `SLAB_SIZE = 8GB`, `MAX_THREADS = NUM_THREADS + 4`.
- `crates/backend/zk-alloc/src/syscall.rs` — platform-specific mmap (100 lines). macOS
  path (lines 67-86): uses `libc::mmap(MAP_PRIVATE | MAP_ANON)`, no NORESERVE, madvise
  is a no-op.
- `crates/backend/system-info/src/lib.rs` — `flush_rayon()` (256 rayon::join calls) and
  `NUM_THREADS` (compile-time constant from build.rs).
- `crates/rec_aggregation/src/benchmark.rs` lines 324/338 — `begin_phase()`/`end_phase()`
  wrapping the prove call.

## Baseline Measurements

**Before any changes, collect these baselines:**

```bash
cd ~/zk-autoresearch/leanMultisig

# 1. zk-alloc ENABLED (default) — this should be slow
RUSTFLAGS="-C target-cpu=native" cargo run --release -- fancy-aggregation --json 2>&1 | tee /tmp/baseline_zkalloc.json

# 2. zk-alloc DISABLED — this should be fast
RUSTFLAGS="-C target-cpu=native" cargo run --release --features standard-alloc -- fancy-aggregation --json 2>&1 | tee /tmp/baseline_sysalloc.json

# 3. Memory diagnostics while proving (in another terminal)
vmmap <pid> | grep -E "TOTAL|MALLOC|mapped file" > /tmp/vmmap_zkalloc.txt
vm_stat 1 > /tmp/vmstat_during_prove.txt
```

Record: XMSS/S for 1550-sig leaf, peak RSS, total virtual size, page fault counts.

## Repo

| Repo | Path | Branch | Role |
|------|------|--------|------|
| leanMultisig | `~/zk-autoresearch/leanMultisig` | `fix/macos-zk-alloc` (create from main) | Target |

The vendored zk-alloc is at `crates/backend/zk-alloc/`. All changes go here — do NOT
modify the standalone `~/zk-autoresearch/zk-alloc` repo.

## Profiling Phase (iters 1-2)

Before optimizing, understand where time goes on macOS. Profile-driven, not guess-driven.

### Iter 1: Baseline + allocation characterization
```bash
cd ~/zk-autoresearch/leanMultisig

# 1. zk-alloc ENABLED (default)
RUSTFLAGS="-C target-cpu=native" cargo run --release -- fancy-aggregation --json 2>&1 | tee /tmp/baseline_zkalloc.json

# 2. zk-alloc DISABLED (system allocator)
RUSTFLAGS="-C target-cpu=native" cargo run --release --features standard-alloc -- fancy-aggregation --json 2>&1 | tee /tmp/baseline_sysalloc.json

# 3. Memory diagnostics while proving (in another terminal):
vmmap <pid> | grep -E "TOTAL|MALLOC|reserved|committed"
vm_stat 1 > /tmp/vmstat.txt  # watch compressor/swap activity
sysctl vm.swapusage
```

Record: XMSS/S for 1550-sig leaf, speedup %, peak RSS both modes, virtual size,
page faults, compressor pages.

### Iter 2: Where is the allocator losing time?
Profile the zk-alloc code path on macOS:
```bash
# Sample-based profiling (Instruments or cargo-instruments)
RUSTFLAGS="-C target-cpu=native" cargo instruments --release -t time -- fancy-aggregation --json

# Or dtrace if Instruments unavailable:
sudo dtrace -n 'pid$target::*zk_alloc*:entry { @[probefunc] = count(); }' -c './target/release/lean-multisig fancy-aggregation --json'
```

Key questions:
- How much time in mmap/madvise syscalls vs bump allocation?
- Is the libc::mmap wrapper slower than Linux raw syscalls?
- How much time in rayon flush (crossbeam drain) during end_phase?
- What's the TLB miss rate? (`sudo dtrace` or Instruments counters)
- What does `vmmap` show for the mmap region? How much is resident vs reserved?

**Apple Silicon note:** macOS on M-series uses **16KB pages** (not 4KB like x86). This
affects: mmap granularity, TLB coverage, alignment. The vendored zk-alloc has NO
size-routing — all allocations go to the arena during active phase. This is different
from the standalone repo which routes <4KB to System.

## Optimization Phase (iters 3+)

Form hypotheses from profiling. The allocator was designed for Linux x86 — several
assumptions may be wrong on macOS ARM64:

**Known platform differences to investigate:**
- **Virtual memory overcommit:** `SLAB_SIZE = 8GB` × `MAX_THREADS` = potentially 96-144GB
  virtual. On a 16-32GB Mac, this is a 3-9× overcommit. macOS claims lazy backing, but
  the page table creation for ~25M pages (at 4KB granularity on some Apple chips) may be
  the bottleneck. **This is the prime suspect for the 12x slowdown on M1.**
- **Page size:** 16KB on Apple Silicon vs 4KB on x86. Affects alignment, TLB coverage.
  The 16KB page means the mmap actually needs fewer page table entries than on x86 —
  so the overcommit impact should be LESS on ARM64, not more. If it's still slow, the
  bottleneck is elsewhere (kernel memory pressure checks, swap reservation, etc.).
- **mmap path:** libc wrapper vs Linux raw syscalls. The libc wrapper may do additional
  validation or logging. Compare timing of mmap alone vs the full prove.
- **Memory compressor:** macOS compresses inactive pages rather than swapping. Large
  virtual mappings may trigger compressor activity on the slab regions that were
  touched in previous phases.
- **MADV_FREE_REUSABLE:** macOS-specific madvise hint that marks pages as reusable
  without unmapping. Could be used in `end_phase()` to tell the kernel to reclaim
  slab pages between phases without needing a new mmap.
- **madvise is a NO-OP on macOS** in the current code. The `madvise_nohugepage` call
  after mmap does nothing on non-Linux. There may be macOS-specific advisories worth using.
- **Slab sizing:** The single most impactful lever. Reducing `SLAB_SIZE` from 8GB to
  e.g. 1-2GB would cut virtual from 96GB to 12-24GB. The question: does leanMultisig
  actually USE 8GB per thread? Profile peak bump pointer per slab to find out.

**Do not just tune constants blindly.** The 25% speedup on Hetzner comes from eliminating
malloc/free overhead in the hot allocation path. If macOS is much slower, something is
ACTIVELY HURTING — find what, don't guess. The diagnosis phase (iters 1-2) is critical.

## Eval Gates

### Correctness Gate
```bash
cd ~/zk-autoresearch/leanMultisig
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-koala-bear -p mt-field -p mt-sumcheck -p mt-symetric --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test -p mt-whir --release --quiet 2>&1
RUSTFLAGS="-C target-cpu=native" cargo test --release --test test_multisignatures --quiet 2>&1
```

### Performance Gate
Compare zk-alloc-enabled vs standard-alloc on `fancy-aggregation --json`:
```bash
# Your change (zk-alloc enabled, default)
RUSTFLAGS="-C target-cpu=native" cargo run --release -- fancy-aggregation --json 2>&1 | tee /tmp/run_zkalloc.json

# Reference (system allocator)
RUSTFLAGS="-C target-cpu=native" cargo run --release --features standard-alloc -- fancy-aggregation --json 2>&1 | tee /tmp/run_sysalloc.json
```

Run each **3 times**, take median XMSS/S for the 1550-sig leaf node.

**Metric:** speedup = (zkalloc_xmss_s / sysalloc_xmss_s - 1) × 100%

**Gate thresholds:**
- **Current baseline:** ~10% faster than system allocator (measure this first!)
- **Keep threshold:** improvement must increase the speedup gap by ≥ 2 percentage points
  (e.g., 10% → 12% is a keep, 10% → 11% is noise)
- **Target:** ≥ 20% faster than system allocator (close the gap with Hetzner's ~25%)
- **Hard floor:** zk-alloc must NEVER be slower than system allocator. Any regression below
  0% speedup is an immediate revert.

**Memory constraint:** Peak RSS with zk-alloc must not exceed 1.5× standard-alloc peak RSS.
Virtual size must stay under 2× physical RAM (< 32GB on 16GB machine).

### Memory Validation
After every fix iteration:
```bash
vmmap <pid> | grep TOTAL
vm_stat | grep -E "Compressor|Swapouts"
```

## Iteration Loop

### Phase 0: Diagnose
Iters 1-3 are diagnosis only. Log findings in iters.tsv with `status=wip`.

### Phase 1: Hypothesize
1. **What** you expect to change.
2. **Predicted magnitude** — micro/medium/structural.
3. **Why** — reference diagnosis data.

### Phase 2: Implement
One fix per iteration. Commit, gate, keep/discard.

### Phase 3: Gate
Correctness first. Then performance comparison (zk-alloc vs standard-alloc).

### Phase 4: Validate cross-config
After a keep, test with different workloads:
- 1550-sig leaf (heavy, ~15s)
- 508-sig leaf (lighter)
- Recursion nodes (different allocation pattern)

## Logging — `iters.tsv`

Append to `~/zk-autoresearch/experiment_logs/zk-alloc/macos_leanmultisig/iters.tsv`:
```
iter	xmss_per_s_zkalloc	xmss_per_s_sysalloc	peak_rss_mb	virtual_size_gb	status	files_changed	rationale
```

## What This Experiment Is NOT

- Do NOT optimize leanMultisig prover code. Only change zk-alloc and its integration
  (`crates/backend/zk-alloc/`, `crates/backend/system-info/`).
- Do NOT change the prover's begin_phase/end_phase call pattern.
- Do NOT modify test expected values or security parameters.
- Do NOT change NEON SIMD code — the architectural gap (128-bit vs 512-bit) is not fixable.
- You MAY read system allocator source (mimalloc, jemalloc) for macOS mmap patterns.
- You MAY change `SLAB_SIZE`, `SLACK`, mmap flags, madvise calls, and the macOS syscall path.

## Stop Criterion

This is an optimization experiment. Stop when:
- zk-alloc speedup over system allocator reaches **≥ 20%** (target), OR
- 12 stop points accumulated (same weighted scheme as research experiments:
  micro-discard = 1 point, medium = 0.5, structural = 0), OR
- You've confirmed the remaining gap is due to fundamental platform differences
  (e.g., libc mmap overhead that can't be bypassed) and documented the evidence

## NEVER STOP
Run autonomously until stopped or stop criterion hit.
