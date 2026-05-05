use std::time::Instant;
use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate, xmss_verify_aggregation};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

#[cfg(feature = "zkalloc_global")]
#[global_allocator]
static ALLOC: zk_alloc::ZkAllocator = zk_alloc::ZkAllocator;

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

    #[cfg(feature = "zkalloc_global")]
    {
        eprintln!("prove_loop: zkalloc_global — #[global_allocator] mode");
    }

    let phase_boundary = resolve_ffi(b"zk_alloc_phase_boundary\0");
    let deactivate = resolve_ffi(b"zk_alloc_deactivate\0");

    #[cfg(not(feature = "zkalloc_global"))]
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
    #[cfg(feature = "zkalloc_global")]
    zk_alloc::begin_phase();
    #[cfg(not(feature = "zkalloc_global"))]
    if let Some(pb) = phase_boundary {
        unsafe { pb(); }
    }

    for i in 0..n_proofs {
        #[cfg(feature = "zkalloc_global")]
        zk_alloc::begin_phase();
        #[cfg(not(feature = "zkalloc_global"))]
        if let Some(pb) = phase_boundary {
            unsafe { pb(); }
        }
        let data = raw_xmss.clone();
        let start = Instant::now();
        let (pub_keys, proof) = xmss_aggregate(&[], data, &message, BENCHMARK_SLOT, LOG_INV_RATE).expect("prove failed");
        let secs = start.elapsed().as_secs_f64();
        #[cfg(feature = "zkalloc_global")]
        zk_alloc::end_phase();
        #[cfg(not(feature = "zkalloc_global"))]
        if let Some(da) = deactivate {
            unsafe { da(); }
        }
        let verify = std::env::var("VERIFY").is_ok();
        if verify {
            let vstart = Instant::now();
            match xmss_verify_aggregation(&pub_keys, &proof, &message, BENCHMARK_SLOT) {
                Ok(_) => eprintln!("  verify OK ({:.3}s)", vstart.elapsed().as_secs_f64()),
                Err(e) => {
                    eprintln!("  VERIFY FAILED: {:?}", e);
                    std::process::exit(1);
                }
            }
        }
        let rss = rss_kb() / 1024;
        println!("{i},{secs:.3},{rss}");
        eprintln!("proof {}/{n_proofs}: {secs:.3}s, rss: {rss}MB", i + 1);
    }
}
