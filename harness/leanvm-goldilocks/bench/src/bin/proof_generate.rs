use backend::precompute_dft_twiddles;
use goldilocks::Goldilocks;
use rec_aggregation::{
    aggregate_single_message_signatures, init_aggregation_bytecode,
};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};

fn main() {
    let out_path = std::env::args().nth(1).unwrap_or("/tmp/soundness_proof.bin".to_string());

    init_aggregation_bytecode();
    precompute_dft_twiddles::<Goldilocks>(1 << 24);
    let message = message_for_benchmark();
    let slot: u32 = BENCHMARK_SLOT;
    let signatures = get_benchmark_signatures();
    let raws = signatures[0..3].to_vec();

    eprintln!("[proof_generate] generating proof (3 signatures, Goldilocks)...");
    let sig = aggregate_single_message_signatures(&[], raws, message, slot, 2).unwrap();
    let bytes = sig.to_bytes();
    eprintln!("[proof_generate] proof size: {} bytes", bytes.len());

    std::fs::write(&out_path, &bytes).unwrap();
    eprintln!("[proof_generate] written to {}", out_path);
}
