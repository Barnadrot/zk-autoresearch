//! Proof-transcript mutation fuzzer.
//!
//! Generates one valid proof, then mutates random bytes in the serialized
//! transcript and verifies the verifier REJECTS every mutation. A mutation
//! that passes verification indicates a verifier bug.
//!
//! Usage:
//!   cargo run --release --bin fuzz_proof_rejection [-- --mutations N --seed S]

use backend::precompute_dft_twiddles;
use mt_koala_bear::KoalaBear;
use rec_aggregation::{
    SingleMessageAggregateSignature, aggregate_single_msg_signatures, init_aggregation_bytecode, verify_single_message_aggregate,
};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};

fn simple_rng(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

fn main() {
    let mut n_mutations: usize = 200;
    let mut seed: u64 = 42;

    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--mutations" => { i += 1; n_mutations = args[i].parse().unwrap(); }
            "--seed" => { i += 1; seed = args[i].parse().unwrap(); }
            _ => {}
        }
        i += 1;
    }

    eprintln!("[fuzz] proof-transcript mutation fuzzer");
    eprintln!("[fuzz] mutations={} seed={}", n_mutations, seed);

    // --- Generate one valid proof ---
    init_aggregation_bytecode();
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    let message = message_for_benchmark();
    let slot: u32 = BENCHMARK_SLOT;
    let signatures = get_benchmark_signatures();
    let raws = signatures[0..3].to_vec();

    eprintln!("[fuzz] generating valid proof (3 signatures)...");
    let valid_sig = aggregate_single_msg_signatures(&[], raws, message, slot, 2).unwrap();
    let valid_bytes = valid_sig.compress();
    eprintln!("[fuzz] proof size: {} bytes", valid_bytes.len());

    // Sanity: valid proof passes verification
    let recovered = SingleMessageAggregateSignature::decompress(&valid_bytes).unwrap();
    verify_single_message_aggregate(&recovered).unwrap();
    eprintln!("[fuzz] valid proof passes verification ✓");

    // --- Mutation loop ---
    let mut rng_state = seed;
    let mut accepted = 0usize;
    let mut rejected = 0usize;
    let mut deser_fail = 0usize;

    for i in 0..n_mutations {
        let mut mutated = valid_bytes.clone();

        // Pick mutation strategy
        let strategy = simple_rng(&mut rng_state) % 4;
        match strategy {
            0 => {
                // Single byte flip
                let pos = (simple_rng(&mut rng_state) as usize) % mutated.len();
                let bit = (simple_rng(&mut rng_state) % 8) as u8;
                mutated[pos] ^= 1 << bit;
            }
            1 => {
                // Multi-byte corruption (2-8 bytes)
                let n = 2 + (simple_rng(&mut rng_state) as usize) % 7;
                for _ in 0..n {
                    let pos = (simple_rng(&mut rng_state) as usize) % mutated.len();
                    mutated[pos] = (simple_rng(&mut rng_state) & 0xFF) as u8;
                }
            }
            2 => {
                // Truncation (remove last 1-32 bytes)
                let n = 1 + (simple_rng(&mut rng_state) as usize) % 32;
                mutated.truncate(mutated.len().saturating_sub(n));
            }
            3 => {
                // Zero a region (4-64 bytes)
                let len = 4 + (simple_rng(&mut rng_state) as usize) % 61;
                let start = (simple_rng(&mut rng_state) as usize) % mutated.len();
                let end = (start + len).min(mutated.len());
                for b in &mut mutated[start..end] {
                    *b = 0;
                }
            }
            _ => unreachable!(),
        }

        // Try decompress + verify
        match SingleMessageAggregateSignature::decompress(&mutated) {
            None => {
                deser_fail += 1;
            }
            Some(sig) => {
                match verify_single_message_aggregate(&sig) {
                    Ok(_) => {
                        accepted += 1;
                        eprintln!(
                            "[fuzz] ACCEPTED mutation {}! strategy={} \
                             — VERIFIER BUG: mutated proof passed verification",
                            i, strategy,
                        );
                    }
                    Err(_) => {
                        rejected += 1;
                    }
                }
            }
        }

        if (i + 1) % 50 == 0 {
            eprintln!("[fuzz] progress: {}/{} (rejected={} deser_fail={} accepted={})", i + 1, n_mutations, rejected, deser_fail, accepted);
        }
    }

    eprintln!();
    eprintln!("[fuzz] === RESULTS ===");
    eprintln!("[fuzz] mutations:   {}", n_mutations);
    eprintln!("[fuzz] rejected:    {} (verifier caught corruption)", rejected);
    eprintln!("[fuzz] deser_fail:  {} (deserialization caught corruption)", deser_fail);
    eprintln!("[fuzz] accepted:    {}", accepted);

    if accepted > 0 {
        eprintln!("[fuzz] FAIL — {} mutated proofs passed verification!", accepted);
        std::process::exit(1);
    } else {
        eprintln!("[fuzz] PASS — all mutations rejected.");
    }
}
