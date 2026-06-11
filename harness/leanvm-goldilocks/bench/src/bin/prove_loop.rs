use std::time::Instant;
use goldilocks::Goldilocks;
use rec_aggregation::{init_aggregation_bytecode, aggregate_single_message_signatures, verify_single_message_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

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
        eprintln!("prove_loop: zkalloc_global enabled");
        zk_alloc::enable_arena();
    }

    #[cfg(not(feature = "zkalloc_global"))]
    eprintln!("prove_loop: no zkalloc_global — system allocator");

    eprintln!("prove_loop: {n_proofs} proofs, {N_SIGS} sigs, log_inv_rate={LOG_INV_RATE}, field=Goldilocks");

    let setup_start = Instant::now();
    precompute_dft_twiddles::<Goldilocks>(1 << 24);
    init_aggregation_bytecode();
    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();
    let setup_ms = setup_start.elapsed().as_millis();

    eprintln!("setup: {setup_ms}ms, rss: {}MB", rss_kb() / 1024);
    println!("proof,seconds,rss_mb,proof_kib");

    for i in 0..n_proofs {
        let data = raw_xmss.clone();
        let start = Instant::now();
        let sig = aggregate_single_message_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).expect("prove failed");
        let secs = start.elapsed().as_secs_f64();
        let verify = std::env::var("VERIFY").is_ok();
        if verify {
            let vstart = Instant::now();
            match verify_single_message_aggregate(&sig) {
                Ok(_) => eprintln!("  verify OK ({:.3}s)", vstart.elapsed().as_secs_f64()),
                Err(e) => {
                    eprintln!("  VERIFY FAILED: {:?}", e);
                    std::process::exit(1);
                }
            }
        }
        let proof_kib = sig.to_bytes().len() / 1024;
        let rss = rss_kb() / 1024;
        println!("{i},{secs:.3},{rss},{proof_kib}");
        eprintln!("proof {}/{n_proofs}: {secs:.3}s, rss: {rss}MB, proof: {proof_kib}KiB", i + 1);
    }
}
