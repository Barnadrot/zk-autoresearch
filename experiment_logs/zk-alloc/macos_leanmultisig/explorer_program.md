# zk-alloc macOS Explorer — Deep Profiling

## Role
You are a systems performance analyst producing a diagnostic report on zk-alloc's behavior
on macOS/Apple Silicon. You do NOT optimize — you observe, measure, and document. Your
report will be consumed by a separate optimization agent.

**Hardware:** Mac (M-series Apple Silicon), macOS Sonoma+. The operator will tell you
which chip (M1/M2/M3) and RAM size.

## Context

zk-alloc is a bump+reset arena allocator for ZK proving. On **Linux (Zen 4, 64GB RAM)**
it delivers **~27% speedup** over glibc malloc. On **macOS M1 16GB** it was reported
**12x slower than expected** (105 XMSS/S vs 1292 on M4). Disabling zk-alloc (`--features
standard-alloc`) restores normal performance.

The allocator maps `8GB × (NUM_THREADS + 4)` of virtual memory in a single mmap call
at initialization. On a 10-core M1 with 16GB RAM, that's `8GB × 14 = 112GB virtual`
on a 16GB machine — a 7× overcommit. The Linux path uses `MAP_NORESERVE` to tell the
kernel not to account this against committed memory. The macOS path cannot — there is
no `MAP_NORESERVE` on macOS.

**The architecture (vendored in leanMultisig, 194 lines):**
- Single `mmap(MAP_PRIVATE | MAP_ANON)` of `REGION_SIZE = SLAB_SIZE * MAX_THREADS`
- Each thread gets a `SLAB_SIZE` (8GB) region, bump-allocates within it
- `begin_phase()` increments a generation counter; threads lazily reset on next alloc
- `end_phase()` disables arena, calls `flush_rayon()` (256 `rayon::join` no-ops)
- `madvise` after mmap is a **no-op** on the macOS path (MADV_NOHUGEPAGE is Linux-only)
- dealloc for arena pointers = no-op (just a range check)
- realloc = alloc new + `copy_nonoverlapping` + dealloc old

**Key files (read-only, do NOT modify):**
- `crates/backend/zk-alloc/src/lib.rs` — arena core (194 lines)
- `crates/backend/zk-alloc/src/syscall.rs` — mmap path (100 lines)
- `crates/backend/system-info/src/lib.rs` — `flush_rayon()`, `NUM_THREADS`, `peak_rss_bytes()`
- `crates/backend/system-info/build.rs` — `NUM_THREADS` = `available_parallelism()` at build time
- `crates/rec_aggregation/src/benchmark.rs:324,338` — `begin_phase()` / `end_phase()` calls

**Reference data from Linux (Hetzner Zen 4, AVX-512, 64GB RAM):**

| Config | glibc | zk-alloc | Speedup |
|--------|------:|--------:|---------:|
| 64GB / 16c | 3.14s | 2.31s | -26.4% |
| 64GB / 8c | 3.33s | 2.36s | -29.1% |
| 16GB / 16c | 3.18s | 2.30s | -27.5% |

Linux perf stat (zk-alloc, 64GB/8c):
- IPC: 1.46, cache miss rate: 3.69%, page faults: 4.1M, sys time: 7.9s

## What To Do

You have one job: produce a comprehensive diagnostic report. No code changes. No optimization.
Follow the steps below and document EVERY command and its output.

### Phase 1: System Characterization

Record the exact hardware and OS:
```bash
sysctl hw.ncpu hw.physicalcpu hw.memsize hw.pagesize hw.l1dcachesize hw.l2cachesize
sysctl machdep.cpu.brand_string 2>/dev/null || sysctl -a | grep brand
sw_vers
uname -m
memory_pressure  # macOS memory pressure level
vm_stat          # baseline VM counters
sysctl vm.swapusage
```

Document: chip model, core count (P+E breakdown if available), RAM, page size, L1/L2 cache,
macOS version, current memory pressure and swap state.

### Phase 2: Build Both Binaries

```bash
cd ~/zk-autoresearch/leanMultisig

# Binary 1: zk-alloc enabled (default)
RUSTFLAGS="-C target-cpu=native" cargo build --release 2>&1 | tail -5
cp target/release/lean-multisig /tmp/bench_zkalloc

# Binary 2: system allocator
RUSTFLAGS="-C target-cpu=native" cargo build --release --features standard-alloc 2>&1 | tail -5
cp target/release/lean-multisig /tmp/bench_sysalloc
```

Record: NUM_THREADS that was compiled in (check build output or `strings /tmp/bench_zkalloc | grep "built for"`)
and the resulting REGION_SIZE = 8GB × (NUM_THREADS + 4).

### Phase 3: Baseline Performance Comparison

Run each binary 3 times. Use `/usr/bin/time -l` for resource accounting:

```bash
for i in 1 2 3; do
  echo "=== zkalloc run $i ==="
  /usr/bin/time -l /tmp/bench_zkalloc fancy-aggregation --json 2>&1 | tee /tmp/zkalloc_run${i}.txt
done

for i in 1 2 3; do
  echo "=== sysalloc run $i ==="
  /usr/bin/time -l /tmp/bench_sysalloc fancy-aggregation --json 2>&1 | tee /tmp/sysalloc_run${i}.txt
done
```

From `/usr/bin/time -l` output, extract and tabulate:
- Wall clock time (real)
- User time / Sys time
- Maximum resident set size (peak RSS)
- Page faults (voluntary + involuntary context switches as proxy)
- `page reclaims` (soft faults — page found in memory but not mapped)
- `page faults` (hard faults — page had to be read from disk/swap)

Also extract from JSON: per-node time_secs, total XMSS/S, proof sizes.

### Phase 4: Virtual Memory Analysis

Run the zk-alloc binary and capture vmmap while it's proving. You'll need two terminals
(or background the analysis):

```bash
# Terminal 1: start proving
/tmp/bench_zkalloc fancy-aggregation --json &
PID=$!

# Give it a few seconds to start mmap and begin proving
sleep 5

# Terminal 2: capture vmmap
vmmap $PID > /tmp/vmmap_zkalloc_during.txt 2>&1
vmmap --summary $PID > /tmp/vmmap_zkalloc_summary.txt 2>&1
footprint $PID > /tmp/footprint_zkalloc.txt 2>&1

# Capture vm_stat delta during proving
vm_stat 1 > /tmp/vmstat_during_prove.txt &
VMSTAT_PID=$!
wait $PID
kill $VMSTAT_PID 2>/dev/null
```

Repeat for sysalloc binary.

From vmmap output, document:
- Total virtual size
- Total resident size
- The anonymous mmap region (the arena) — its virtual size vs resident size
- MALLOC zones — count, total size
- Number of VM regions
- "dirty" vs "swapped" vs "resident" breakdown

From vm_stat during proving:
- Pages active / inactive / speculative / wired
- "Pages stored in compressor" — are pages being compressed?
- "Pageouts" — is macOS swapping?
- "Page ins" — is it reading back from swap?
- Fault rate per second

### Phase 5: mmap Timing

The initial mmap call maps the entire region. Time it in isolation:

```bash
# Write a tiny Rust program that just does the mmap and times it
cat > /tmp/mmap_bench.rs << 'RUST'
use std::time::Instant;

fn main() {
    let sizes: Vec<usize> = vec![
        1 << 30,   // 1 GB
        2 << 30,   // 2 GB
        4 << 30,   // 4 GB
        8usize << 30,   // 8 GB
        16usize << 30,  // 16 GB
        32usize << 30,  // 32 GB
        64usize << 30,  // 64 GB
        96usize << 30,  // 96 GB
        128usize << 30, // 128 GB
    ];
    for size in sizes {
        let t = Instant::now();
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1, 0,
            )
        };
        let elapsed = t.elapsed();
        if ptr == libc::MAP_FAILED {
            println!("{:>4} GB: FAILED", size >> 30);
        } else {
            println!("{:>4} GB: {:>8.3} ms", size >> 30, elapsed.as_secs_f64() * 1000.0);
            unsafe { libc::munmap(ptr, size) };
        }
    }

    // Now test: mmap + touch first page of each 8GB slab (simulating thread init)
    let slab = 8usize << 30;
    for n_slabs in [4, 8, 12, 16, 20] {
        let total = slab * n_slabs;
        let t = Instant::now();
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                total,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1, 0,
            )
        };
        if ptr == libc::MAP_FAILED {
            println!("{:>2} slabs ({:>4} GB): mmap FAILED", n_slabs, total >> 30);
            continue;
        }
        let mmap_time = t.elapsed();
        // Touch first page of each slab
        let t2 = Instant::now();
        for i in 0..n_slabs {
            unsafe {
                let page = (ptr as *mut u8).add(i * slab);
                std::ptr::write_volatile(page, 0u8);
            }
        }
        let touch_time = t2.elapsed();
        println!("{:>2} slabs ({:>4} GB): mmap {:>8.3} ms, touch {:>8.3} ms",
            n_slabs, total >> 30,
            mmap_time.as_secs_f64() * 1000.0,
            touch_time.as_secs_f64() * 1000.0);
        unsafe { libc::munmap(ptr, total) };
    }
}
RUST

# Compile and run (needs libc crate — use rustc directly with extern)
# Actually, use a Cargo project:
mkdir -p /tmp/mmap_bench && cd /tmp/mmap_bench
cargo init --name mmap_bench 2>/dev/null
echo '[dependencies]
libc = "0.2"' > Cargo.toml
cp /tmp/mmap_bench.rs src/main.rs
cargo run --release 2>&1
```

Record: at what size does mmap start taking measurably longer? Does it fail at any size?
How long does touching the first page of each slab take?

### Phase 6: Page Fault Profiling During Proving

Quantify page faults during the actual prove:

```bash
# vm_stat with 1-second intervals, start before prove
vm_stat 1 > /tmp/vmstat_zkalloc.txt &
VS=$!

# Run prove
/usr/bin/time -l /tmp/bench_zkalloc fancy-aggregation --json > /tmp/zkalloc_prove.json 2>&1

kill $VS 2>/dev/null

# Same for sysalloc
vm_stat 1 > /tmp/vmstat_sysalloc.txt &
VS=$!
/usr/bin/time -l /tmp/bench_sysalloc fancy-aggregation --json > /tmp/sysalloc_prove.json 2>&1
kill $VS 2>/dev/null
```

Parse the vm_stat output: plot (or tabulate) per-second fault rate, compressor pages,
pageouts for both allocators.

### Phase 7: Thread Utilization Estimation

The arena allocates 8GB per thread but threads may use much less. Without code changes,
estimate utilization indirectly:

```bash
# vmmap shows per-region dirty pages — the dirty size of the anonymous mapping
# tells us how much was actually touched
vmmap $PID 2>/dev/null | grep -A5 "TOTAL"
# Also look for the specific large anonymous region
vmmap $PID 2>/dev/null | grep -E "^__DATA|anonymous|VM_ALLOCATE" | head -20
```

If vmmap shows the anonymous region (e.g. 112GB virtual) with only X MB dirty/resident,
that tells us actual utilization. Compare dirty pages × page_size against REGION_SIZE.

### Phase 8: Compressor and Swap Deep-Dive

macOS compresses inactive pages instead of swapping immediately. Large virtual mappings
that get partially written and then abandoned (between phases) may trigger compressor work:

```bash
# Before prove
vm_stat | grep -E "compressor|Compress|Decompress|Swapins|Swapouts"
sysctl vm.swapusage

# After prove
vm_stat | grep -E "compressor|Compress|Decompress|Swapins|Swapouts"
sysctl vm.swapusage

# Delta = compressor/swap activity caused by the prove
```

### Phase 9: Sample-Based CPU Profile

```bash
# Use the `sample` tool (built into macOS, no SIP issues)
/tmp/bench_zkalloc fancy-aggregation --json &
PID=$!
sleep 3  # let it get into proving
sample $PID 10 -f /tmp/sample_zkalloc.txt  # sample for 10 seconds
wait $PID

# Look for time in mmap, madvise, vm_fault, page table ops
grep -E "mmap|madvise|vm_fault|page|kern|syscall|alloc" /tmp/sample_zkalloc.txt | head -40
```

If dtrace is available (SIP disabled):
```bash
# Count syscalls during prove
sudo dtrace -n 'syscall:::entry /pid == $target/ { @[probefunc] = count(); }' \
  -c '/tmp/bench_zkalloc fancy-aggregation --json' 2>&1 | tail -30
```

### Phase 10: macOS-Specific madvise Options

Test which madvise flags macOS supports (for the future optimization agent):
```bash
cat > /tmp/madvise_test.rs << 'RUST'
use std::ptr;

fn main() {
    let size = 1usize << 30; // 1 GB
    let p = unsafe {
        libc::mmap(ptr::null_mut(), size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_ANON, -1, 0)
    };
    assert_ne!(p, libc::MAP_FAILED);

    // Touch some pages
    for i in (0..size).step_by(16384) {
        unsafe { ptr::write_volatile((p as *mut u8).add(i), 1); }
    }

    let advices = [
        ("MADV_FREE", libc::MADV_FREE),
        ("MADV_DONTNEED", libc::MADV_DONTNEED),
        ("MADV_FREE_REUSABLE", 7),  // macOS-specific
        ("MADV_FREE_REUSE", 8),     // macOS-specific
        ("MADV_CAN_REUSE", 9),      // macOS-specific
        ("MADV_ZERO_WIRED_PAGES", 6), // macOS-specific
    ];

    for (name, advice) in advices {
        let ret = unsafe { libc::madvise(p as *mut libc::c_void, size, advice) };
        println!("{:30s}: ret={}, errno={}", name, ret,
            if ret != 0 { *unsafe { libc::__error() } } else { 0 });
    }

    unsafe { libc::munmap(p, size) };
}
RUST

mkdir -p /tmp/madvise_test && cd /tmp/madvise_test
cargo init --name madvise_test 2>/dev/null
echo '[dependencies]
libc = "0.2"' > Cargo.toml
cp /tmp/madvise_test.rs src/main.rs
cargo run --release 2>&1
```

Document which madvise flags work and which don't.

## Output

Write the full diagnostic report to:
`~/zk-autoresearch/experiment_logs/zk-alloc/macos_leanmultisig/explorer_report.md`

Structure:
```markdown
# zk-alloc macOS Diagnostic Report

**Date:** YYYY-MM-DD
**Machine:** [chip] / [RAM] / [macOS version]
**leanMultisig commit:** [hash]
**NUM_THREADS (compiled):** [N]
**REGION_SIZE:** [N] GB

## 1. System Baseline
[Phase 1 output]

## 2. Performance Comparison
[Phase 3 results — table with wall time, RSS, page faults for both allocators]

## 3. Virtual Memory Layout
[Phase 4 — vmmap analysis, region sizes, resident vs virtual]

## 4. mmap Scaling
[Phase 5 — mmap timing at different sizes, failure points]

## 5. Page Fault Profile
[Phase 6 — per-second fault rate during proving, both allocators]

## 6. Slab Utilization Estimate
[Phase 7 — how much of 8GB/thread is actually touched]

## 7. Compressor / Swap Activity
[Phase 8 — compressor pages, swap usage delta]

## 8. CPU Profile
[Phase 9 — where CPU time goes, syscall overhead]

## 9. Available madvise Flags
[Phase 10 — which macOS-specific flags work]

## 10. Comparison with Linux Reference

| Metric | Linux (Zen 4, 64GB) | macOS (this Mac) |
|--------|--------------------:|------------------:|
| Speedup vs system alloc | -27% | ? |
| Peak RSS | 10137 MB | ? |
| Page faults | 4.1M | ? |
| Sys time | 7.9s | ? |
| IPC | 1.46 | N/A |
| mmap virtual | 128GB | ? |
| mmap resident | ? | ? |

## 11. Diagnosis

[Root cause hypothesis with evidence. What is ACTUALLY causing the slowdown?
Possible causes ranked by evidence strength:
- Page table bloat from massive virtual mapping
- Kernel memory pressure checks on mmap
- Compressor thrashing between phases
- Swap reservation
- TLB pressure from 16KB pages spanning huge virtual range
- Something else entirely]

## 12. Recommendations for Optimizer

[Ordered list of what the optimization agent should try first, based on evidence.
Include specific numbers: "slab utilization peaks at X GB, so SLAB_SIZE can be
reduced to Y" or "mmap of Z GB takes N ms, which is X% of prove time."]
```

## Constraints
- **Do NOT modify any source code.** Read-only investigation.
- **Do NOT push anything.**
- **Do NOT run optimization experiments.** This is diagnosis only.
- Always use `RUSTFLAGS="-C target-cpu=native"` for builds.
- Document every command and its raw output in the report.
- If a tool (dtrace, Instruments) is unavailable due to SIP, document that and use alternatives.
- Run each benchmark at least 3 times for consistency.
- If proving takes very long (>5 minutes), document that itself — it may be the bug manifesting.

## NEVER STOP
Run all 10 phases. Write explorer_report.md before stopping.
