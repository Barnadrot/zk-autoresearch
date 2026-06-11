use backend::precompute_dft_twiddles;
use goldilocks::Goldilocks;
use rec_aggregation::{
    SingleMessageAggregateSignature, init_aggregation_bytecode, verify_single_message_aggregate,
};

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("usage: reference_verify <proof_file>");
        std::process::exit(2);
    });

    let bytes = std::fs::read(&path).unwrap_or_else(|e| {
        eprintln!("[reference_verify] cannot read {}: {}", path, e);
        std::process::exit(2);
    });

    eprintln!("[reference_verify] proof size: {} bytes", bytes.len());

    init_aggregation_bytecode();
    precompute_dft_twiddles::<Goldilocks>(1 << 24);

    let sig = match SingleMessageAggregateSignature::from_bytes(&bytes) {
        Some(s) => s,
        None => {
            eprintln!("[reference_verify] FAIL: cannot deserialize proof");
            std::process::exit(1);
        }
    };

    match verify_single_message_aggregate(&sig) {
        Ok(_) => {
            eprintln!("[reference_verify] PASS — proof verified successfully");
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("[reference_verify] FAIL: {:?}", e);
            std::process::exit(1);
        }
    }
}
