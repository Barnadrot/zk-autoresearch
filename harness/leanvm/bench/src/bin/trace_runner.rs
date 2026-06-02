use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, aggregate_type_1};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

fn main() {
    utils::init_tracing();
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();

    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    let data = raw_xmss.clone();
    let _proof = aggregate_type_1(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
    eprintln!("done");
}
