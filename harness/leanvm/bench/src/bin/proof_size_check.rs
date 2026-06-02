// proof_size_check — serialize a small Type-1 aggregate signature and print
// the postcard byte size. Used by verify_post_experiment.sh as a proof-size
// invariant check.
//
// Output (stdout):
//   proof_bytes=<N>
//
// Exit code: 0 on success, 1 on prove/serialize failure.

use backend::precompute_dft_twiddles;
use mt_koala_bear::KoalaBear;
use rec_aggregation::{aggregate_single_msg_signatures, init_aggregation_bytecode};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};

// Smaller than prove_loop's 1550 to keep this fast (~5-10s vs ~2s/proof at 1550).
// Proof size scales with N_SIGS but the invariant we want to detect is
// structural changes to the proof format, which show up at any N_SIGS.
const N_SIGS: usize = 100;
const LOG_INV_RATE: usize = 1;

fn main() {
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();
    let raw: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let msg = message_for_benchmark();

    let sig = aggregate_single_msg_signatures(&[], raw, msg, BENCHMARK_SLOT, LOG_INV_RATE)
        .unwrap_or_else(|e| {
            eprintln!("proof_size_check: aggregate_single_msg_signatures failed: {e:?}");
            std::process::exit(1);
        });

    let bytes: Vec<u8> = match postcard::to_allocvec(&sig) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("proof_size_check: postcard serialize failed: {e:?}");
            std::process::exit(1);
        }
    };

    println!("proof_bytes={}", bytes.len());
    eprintln!("proof_size_check: N_SIGS={N_SIGS} log_inv_rate={LOG_INV_RATE} bytes={}", bytes.len());
}
