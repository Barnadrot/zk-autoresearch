use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1400;
const LOG_INV_RATE: usize = 1;

fn main() {
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();

    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    let n_iters: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2);

    for i in 0..n_iters {
        let data = raw_xmss.clone();
        let _proof = xmss_aggregate(&[], data, &message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
        eprintln!("iter {}/{} done", i + 1, n_iters);
    }
}
