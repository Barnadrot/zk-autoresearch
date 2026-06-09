use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;

static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
static ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);
static LARGE_ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
static LARGE_ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);
static ENABLED: AtomicU64 = AtomicU64::new(0);

const LARGE_THRESHOLD: usize = 128 * 1024; // 128KB

struct CountingAlloc;
unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ENABLED.load(Relaxed) != 0 {
            ALLOC_COUNT.fetch_add(1, Relaxed);
            ALLOC_BYTES.fetch_add(layout.size() as u64, Relaxed);
            if layout.size() >= LARGE_THRESHOLD {
                LARGE_ALLOC_COUNT.fetch_add(1, Relaxed);
                LARGE_ALLOC_BYTES.fetch_add(layout.size() as u64, Relaxed);
            }
        }
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static A: CountingAlloc = CountingAlloc;

fn reset() {
    ALLOC_COUNT.store(0, Relaxed);
    ALLOC_BYTES.store(0, Relaxed);
    LARGE_ALLOC_COUNT.store(0, Relaxed);
    LARGE_ALLOC_BYTES.store(0, Relaxed);
}

fn snapshot() -> (u64, u64, u64, u64) {
    (
        ALLOC_COUNT.load(Relaxed),
        ALLOC_BYTES.load(Relaxed),
        LARGE_ALLOC_COUNT.load(Relaxed),
        LARGE_ALLOC_BYTES.load(Relaxed),
    )
}

fn report(label: &str, before: (u64, u64, u64, u64), elapsed_ms: u128) {
    let after = snapshot();
    let count = after.0 - before.0;
    let bytes = after.1 - before.1;
    let large_count = after.2 - before.2;
    let large_bytes = after.3 - before.3;
    eprintln!(
        "{label}: {count} allocs ({:.2} MB), {large_count} large (>128KB, {:.2} MB), {elapsed_ms}ms",
        bytes as f64 / 1e6,
        large_bytes as f64 / 1e6,
    );
}

use koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, aggregate_single_msg_signatures};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

fn main() {
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();
    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    // Warmup
    let data = raw_xmss.clone();
    let _ = aggregate_single_msg_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
    eprintln!("--- warmup done ---");

    // Measured run
    ENABLED.store(1, Relaxed);
    reset();
    let s = snapshot();
    let t = Instant::now();
    let data = raw_xmss.clone();
    let _ = aggregate_single_msg_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
    let elapsed = t.elapsed().as_millis();
    report("FULL aggregate_single_msg_signatures", s, elapsed);
}
