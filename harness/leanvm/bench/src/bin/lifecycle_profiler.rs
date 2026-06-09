use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, AtomicBool, Ordering::Relaxed};
use std::time::Instant;

const NUM_BUCKETS: usize = 12;
// Bucket boundaries: <=8, <=16, <=32, <=64, <=128, <=256, <=512, <=4K, <=64K, <=1M, <=16M, >16M
const BUCKET_LIMITS: [usize; NUM_BUCKETS] = [8, 16, 32, 64, 128, 256, 512, 4096, 65536, 1048576, 16777216, usize::MAX];
const BUCKET_LABELS: [&str; NUM_BUCKETS] = ["<=8B", "<=16B", "<=32B", "<=64B", "<=128B", "<=256B", "<=512B", "<=4KB", "<=64KB", "<=1MB", "<=16MB", ">16MB"];

fn bucket_index(size: usize) -> usize {
    for (i, &limit) in BUCKET_LIMITS.iter().enumerate() {
        if size <= limit { return i; }
    }
    NUM_BUCKETS - 1
}

struct BucketCounters {
    alloc_count: [AtomicU64; NUM_BUCKETS],
    alloc_bytes: [AtomicU64; NUM_BUCKETS],
    dealloc_count: [AtomicU64; NUM_BUCKETS],
    dealloc_bytes: [AtomicU64; NUM_BUCKETS],
}

impl BucketCounters {
    const fn new() -> Self {
        const Z: AtomicU64 = AtomicU64::new(0);
        Self {
            alloc_count: [Z; NUM_BUCKETS],
            alloc_bytes: [Z; NUM_BUCKETS],
            dealloc_count: [Z; NUM_BUCKETS],
            dealloc_bytes: [Z; NUM_BUCKETS],
        }
    }

    fn reset(&self) {
        for i in 0..NUM_BUCKETS {
            self.alloc_count[i].store(0, Relaxed);
            self.alloc_bytes[i].store(0, Relaxed);
            self.dealloc_count[i].store(0, Relaxed);
            self.dealloc_bytes[i].store(0, Relaxed);
        }
    }

    fn snapshot(&self) -> BucketSnapshot {
        let mut s = BucketSnapshot::default();
        for i in 0..NUM_BUCKETS {
            s.alloc_count[i] = self.alloc_count[i].load(Relaxed);
            s.alloc_bytes[i] = self.alloc_bytes[i].load(Relaxed);
            s.dealloc_count[i] = self.dealloc_count[i].load(Relaxed);
            s.dealloc_bytes[i] = self.dealloc_bytes[i].load(Relaxed);
        }
        s
    }
}

#[derive(Default, Clone)]
struct BucketSnapshot {
    alloc_count: [u64; NUM_BUCKETS],
    alloc_bytes: [u64; NUM_BUCKETS],
    dealloc_count: [u64; NUM_BUCKETS],
    dealloc_bytes: [u64; NUM_BUCKETS],
}

impl BucketSnapshot {
    fn live_count(&self) -> [i64; NUM_BUCKETS] {
        let mut out = [0i64; NUM_BUCKETS];
        for i in 0..NUM_BUCKETS {
            out[i] = self.alloc_count[i] as i64 - self.dealloc_count[i] as i64;
        }
        out
    }

    fn live_bytes(&self) -> [i64; NUM_BUCKETS] {
        let mut out = [0i64; NUM_BUCKETS];
        for i in 0..NUM_BUCKETS {
            out[i] = self.alloc_bytes[i] as i64 - self.dealloc_bytes[i] as i64;
        }
        out
    }

    fn total_allocs(&self) -> u64 { self.alloc_count.iter().sum() }
    fn total_alloc_bytes(&self) -> u64 { self.alloc_bytes.iter().sum() }
    fn total_deallocs(&self) -> u64 { self.dealloc_count.iter().sum() }
    fn total_dealloc_bytes(&self) -> u64 { self.dealloc_bytes.iter().sum() }
    fn total_live_count(&self) -> i64 { self.total_allocs() as i64 - self.total_deallocs() as i64 }
    fn total_live_bytes(&self) -> i64 { self.total_alloc_bytes() as i64 - self.total_dealloc_bytes() as i64 }

    fn diff(&self, before: &BucketSnapshot) -> BucketSnapshot {
        let mut out = BucketSnapshot::default();
        for i in 0..NUM_BUCKETS {
            out.alloc_count[i] = self.alloc_count[i] - before.alloc_count[i];
            out.alloc_bytes[i] = self.alloc_bytes[i] - before.alloc_bytes[i];
            out.dealloc_count[i] = self.dealloc_count[i] - before.dealloc_count[i];
            out.dealloc_bytes[i] = self.dealloc_bytes[i] - before.dealloc_bytes[i];
        }
        out
    }
}

static COUNTERS: BucketCounters = BucketCounters::new();
static ENABLED: AtomicBool = AtomicBool::new(false);

// Timeline logging: we log alloc events to stderr with timestamps
static TIMELINE_ENABLED: AtomicBool = AtomicBool::new(false);
static START_TIME: AtomicU64 = AtomicU64::new(0);

struct TrackingAlloc;
unsafe impl GlobalAlloc for TrackingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if ENABLED.load(Relaxed) {
            let idx = bucket_index(layout.size());
            COUNTERS.alloc_count[idx].fetch_add(1, Relaxed);
            COUNTERS.alloc_bytes[idx].fetch_add(layout.size() as u64, Relaxed);

            if TIMELINE_ENABLED.load(Relaxed) && layout.size() >= 4096 {
                let ts = START_TIME.load(Relaxed);
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64;
                let relative = now.saturating_sub(ts);
                eprintln!("T\t0\t{}\tA\t{}", layout.size(), relative);
            }
        }
        ptr
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if ENABLED.load(Relaxed) {
            let idx = bucket_index(layout.size());
            COUNTERS.dealloc_count[idx].fetch_add(1, Relaxed);
            COUNTERS.dealloc_bytes[idx].fetch_add(layout.size() as u64, Relaxed);

            if TIMELINE_ENABLED.load(Relaxed) && layout.size() >= 4096 {
                let ts = START_TIME.load(Relaxed);
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64;
                let relative = now.saturating_sub(ts);
                eprintln!("T\t0\t{}\tD\t{}", layout.size(), relative);
            }
        }
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static A: TrackingAlloc = TrackingAlloc;

use koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, aggregate_single_msg_signatures};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

fn print_snapshot(label: &str, snap: &BucketSnapshot) {
    eprintln!("\n=== {} ===", label);
    eprintln!("Total: {} allocs ({:.2} MB), {} deallocs ({:.2} MB), {} live ({:.2} MB)",
        snap.total_allocs(), snap.total_alloc_bytes() as f64 / 1e6,
        snap.total_deallocs(), snap.total_dealloc_bytes() as f64 / 1e6,
        snap.total_live_count(), snap.total_live_bytes() as f64 / 1e6,
    );
    let live_c = snap.live_count();
    let live_b = snap.live_bytes();
    eprintln!("{:<10} {:>12} {:>12} {:>12} {:>12} {:>12} {:>12}",
        "Bucket", "Allocs", "AllocMB", "Deallocs", "DeallocMB", "LiveCnt", "LiveMB");
    for i in 0..NUM_BUCKETS {
        if snap.alloc_count[i] > 0 || snap.dealloc_count[i] > 0 {
            eprintln!("{:<10} {:>12} {:>12.2} {:>12} {:>12.2} {:>12} {:>12.2}",
                BUCKET_LABELS[i],
                snap.alloc_count[i], snap.alloc_bytes[i] as f64 / 1e6,
                snap.dealloc_count[i], snap.dealloc_bytes[i] as f64 / 1e6,
                live_c[i], live_b[i] as f64 / 1e6,
            );
        }
    }
}

fn main() {
    let use_timeline = std::env::args().any(|a| a == "--timeline");

    eprintln!("=== LIFECYCLE PROFILER ===");
    eprintln!("Timeline logging: {}", if use_timeline { "ON (>=4KB allocs)" } else { "OFF" });

    // Phase 0: One-time setup (not tracked)
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();
    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();
    eprintln!("--- setup complete ---");

    // Enable tracking
    ENABLED.store(true, Relaxed);
    COUNTERS.reset();

    // Take baseline snapshot after setup
    let baseline = COUNTERS.snapshot();

    // ---- PROOF 1 ----
    eprintln!("\n--- starting proof 1 ---");
    if use_timeline {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64;
        START_TIME.store(now, Relaxed);
        TIMELINE_ENABLED.store(true, Relaxed);
    }
    let t1 = Instant::now();
    let data = raw_xmss.clone();
    let proof1 = aggregate_single_msg_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
    let elapsed1 = t1.elapsed();
    TIMELINE_ENABLED.store(false, Relaxed);

    let after_proof1 = COUNTERS.snapshot();
    let proof1_delta = after_proof1.diff(&baseline);
    eprintln!("--- proof 1 done in {:.2}s ---", elapsed1.as_secs_f64());
    print_snapshot("PROOF 1 (cumulative)", &proof1_delta);

    // Drop proof1 result to free its allocations
    std::mem::drop(proof1);

    let after_drop1 = COUNTERS.snapshot();
    let post_drop1 = after_drop1.diff(&baseline);
    print_snapshot("AFTER DROPPING PROOF 1 RESULT", &post_drop1);

    // ---- BOUNDARY POINT (where phase_boundary would fire) ----
    eprintln!("\n====== BOUNDARY BETWEEN PROOFS ======");
    let boundary_snap = after_drop1.diff(&baseline);
    let live_c = boundary_snap.live_count();
    let live_b = boundary_snap.live_bytes();
    eprintln!("LIVE at boundary: {} allocs, {:.2} MB",
        boundary_snap.total_live_count(),
        boundary_snap.total_live_bytes() as f64 / 1e6,
    );
    eprintln!("These are allocations from proof 1 that were NOT freed.");
    eprintln!("If phase_boundary() resets slabs, these would cause use-after-free.\n");

    // Reset counters for proof 2 delta measurement
    let pre_proof2 = COUNTERS.snapshot();

    // ---- PROOF 2 ----
    eprintln!("--- starting proof 2 ---");
    let t2 = Instant::now();
    let data = raw_xmss.clone();
    let proof2 = aggregate_single_msg_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
    let elapsed2 = t2.elapsed();

    let after_proof2 = COUNTERS.snapshot();
    let proof2_delta = after_proof2.diff(&pre_proof2);
    eprintln!("--- proof 2 done in {:.2}s ---", elapsed2.as_secs_f64());
    print_snapshot("PROOF 2 (delta)", &proof2_delta);

    // Drop proof2 and check final state
    std::mem::drop(proof2);

    let final_snap = COUNTERS.snapshot();
    let from_baseline = final_snap.diff(&baseline);
    print_snapshot("FINAL STATE (from baseline)", &from_baseline);

    // ---- Q1 ANALYSIS: Cross-proof survivors ----
    eprintln!("\n====== Q1: CROSS-PROOF SURVIVOR ANALYSIS ======");
    eprintln!("Survivors = allocations still live at boundary between proofs");
    eprintln!("Live count: {}", boundary_snap.total_live_count());
    eprintln!("Live bytes: {:.2} MB", boundary_snap.total_live_bytes() as f64 / 1e6);
    eprintln!("\nSurvivors by size class:");
    for i in 0..NUM_BUCKETS {
        if live_c[i] > 0 {
            eprintln!("  {}: {} allocs, {:.2} MB", BUCKET_LABELS[i], live_c[i], live_b[i] as f64 / 1e6);
        }
    }

    // Compare proof1 vs proof2 allocation patterns
    eprintln!("\n====== PROOF 1 vs PROOF 2 COMPARISON ======");
    eprintln!("{:<10} {:>14} {:>14} {:>10}",
        "Bucket", "Proof1 Allocs", "Proof2 Allocs", "Delta%");
    for i in 0..NUM_BUCKETS {
        if proof1_delta.alloc_count[i] > 0 || proof2_delta.alloc_count[i] > 0 {
            let p1 = proof1_delta.alloc_count[i] as f64;
            let p2 = proof2_delta.alloc_count[i] as f64;
            let pct = if p1 > 0.0 { ((p2 - p1) / p1) * 100.0 } else { 0.0 };
            eprintln!("{:<10} {:>14} {:>14} {:>9.1}%",
                BUCKET_LABELS[i], proof1_delta.alloc_count[i], proof2_delta.alloc_count[i], pct);
        }
    }
}
