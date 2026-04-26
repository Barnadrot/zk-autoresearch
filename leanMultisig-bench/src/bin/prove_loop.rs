use std::time::Instant;
use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1400;
const LOG_INV_RATE: usize = 1;

type PhaseBoundaryFn = unsafe extern "C" fn();

unsafe extern "C" {
    fn dlopen(filename: *const u8, flags: i32) -> *mut std::ffi::c_void;
    fn dlsym(handle: *mut std::ffi::c_void, symbol: *const u8) -> *mut std::ffi::c_void;
}

const RTLD_DEFAULT: *const u8 = std::ptr::null();
const RTLD_NOW: i32 = 2;

fn resolve_ffi(name: &[u8]) -> Option<PhaseBoundaryFn> {
    unsafe {
        let handle = dlopen(RTLD_DEFAULT, RTLD_NOW);
        if handle.is_null() { return None; }
        let sym = dlsym(handle, name.as_ptr());
        if sym.is_null() { return None; }
        Some(std::mem::transmute(sym))
    }
}

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/statm")
        .ok()
        .and_then(|s| s.split_whitespace().nth(1)?.parse::<u64>().ok())
        .map(|pages| pages * 4)
        .unwrap_or(0)
}

fn main() {
    let n_proofs: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);

    let phase_boundary = resolve_ffi(b"zk_alloc_phase_boundary\0");
    let deactivate = resolve_ffi(b"zk_alloc_deactivate\0");

    if phase_boundary.is_some() {
        eprintln!("prove_loop: zk_alloc FFI detected — phase boundaries enabled");
    } else {
        eprintln!("prove_loop: no zk_alloc FFI — running without phase boundaries");
    }

    eprintln!("prove_loop: {n_proofs} proofs, {N_SIGS} sigs, log_inv_rate={LOG_INV_RATE}");

    let setup_start = Instant::now();
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();
    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();
    let setup_ms = setup_start.elapsed().as_millis();

    eprintln!("setup: {setup_ms}ms, rss: {}MB", rss_kb() / 1024);
    println!("proof,seconds,rss_mb");

    // First phase_boundary is warmup — initializes arena without activating
    if let Some(pb) = phase_boundary {
        unsafe { pb(); }
    }

    for i in 0..n_proofs {
        if let Some(pb) = phase_boundary {
            unsafe { pb(); }
        }
        let data = raw_xmss.clone();
        let start = Instant::now();
        let _proof = xmss_aggregate(&[], data, &message, BENCHMARK_SLOT, LOG_INV_RATE);
        let secs = start.elapsed().as_secs_f64();
        if let Some(da) = deactivate {
            unsafe { da(); }
        }
        let rss = rss_kb() / 1024;
        println!("{i},{secs:.3},{rss}");
        eprintln!("proof {}/{n_proofs}: {secs:.3}s, rss: {rss}MB", i + 1);
    }
}
