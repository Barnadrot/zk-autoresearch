// Callgrind driver for the leanMultisig autoresearch iai gate.
//
// Runs xmss_aggregate at a reduced signature count to keep valgrind wall time
// tolerable while still exercising the full sumcheck hot path. The eval_iai.sh
// script runs this under `valgrind --tool=callgrind --toggle-collect=<hot_kernel>`
// and extracts instruction counts for symbols prefixed with `mt_sumcheck::` and
// related hot-path namespaces.
//
// The hot_kernel function is the collection window — setup (signatures,
// bytecode, twiddles) runs before --toggle-collect fires.

use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;
use mt_koala_bear::KoalaBear;

const LOG_INV_RATE: usize = 1;

// N_SIGS is kept small so callgrind wall time stays tolerable.
// 50 sigs ≈ 70ms native → a few seconds under callgrind.
const N_SIGS: usize = 25;

// Kept as a plain (but non-inlined) Rust function; callgrind matches the
// mangled symbol via `--toggle-collect=*iai_hot_kernel*` so no_mangle isn't
// required and we avoid edition-dependent attribute syntax.
#[inline(never)]
pub fn iai_hot_kernel() {
    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();
    let _ = xmss_aggregate(&[], raw_xmss, &message, BENCHMARK_SLOT, LOG_INV_RATE);
}

fn main() {
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();
    iai_hot_kernel();
}
