//! Proof-transcript mutation fuzzer for leanVM Goldilocks.
//!
//! Generates one valid proof, then mutates random bytes in the serialized
//! transcript and verifies the verifier REJECTS every mutation.
//!
//! Usage:
//!   cargo run --release --bin fuzz_proof_rejection [-- --mutations N --seed S]

use backend::precompute_dft_twiddles;
use goldilocks::Goldilocks;
use rec_aggregation::{
    SingleMessageAggregateSignature, aggregate_single_message_signatures, init_aggregation_bytecode, verify_single_message_aggregate,
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

    eprintln!("[fuzz] proof-transcript mutation fuzzer (Goldilocks)");
    eprintln!("[fuzz] mutations={} seed={}", n_mutations, seed);

    init_aggregation_bytecode();
    precompute_dft_twiddles::<Goldilocks>(1 << 24);
    let message = message_for_benchmark();
    let slot: u32 = BENCHMARK_SLOT;
    let signatures = get_benchmark_signatures();
    let raws = signatures[0..3].to_vec();

    eprintln!("[fuzz] generating valid proof (3 signatures)...");
    let valid_sig = aggregate_single_message_signatures(&[], raws, message, slot, 2).unwrap();
    let valid_bytes = valid_sig.to_bytes();
    eprintln!("[fuzz] proof size: {} bytes", valid_bytes.len());

    let recovered = SingleMessageAggregateSignature::from_bytes(&valid_bytes).unwrap();
    verify_single_message_aggregate(&recovered).unwrap();
    eprintln!("[fuzz] valid proof passes verification ✓");

    let mut rng_state = seed;
    let mut accepted = 0usize;
    let mut rejected = 0usize;
    let mut deser_fail = 0usize;

    for i in 0..n_mutations {
        let mut mutated = valid_bytes.clone();

        let strategy = simple_rng(&mut rng_state) % 4;
        match strategy {
            0 => {
                let pos = (simple_rng(&mut rng_state) as usize) % mutated.len();
                let bit = (simple_rng(&mut rng_state) % 8) as u8;
                mutated[pos] ^= 1 << bit;
            }
            1 => {
                let n = 2 + (simple_rng(&mut rng_state) as usize) % 7;
                for _ in 0..n {
                    let pos = (simple_rng(&mut rng_state) as usize) % mutated.len();
                    mutated[pos] = (simple_rng(&mut rng_state) & 0xFF) as u8;
                }
            }
            2 => {
                let n = 1 + (simple_rng(&mut rng_state) as usize) % 32;
                mutated.truncate(mutated.len().saturating_sub(n));
            }
            3 => {
                let len = 4 + (simple_rng(&mut rng_state) as usize) % 61;
                let start = (simple_rng(&mut rng_state) as usize) % mutated.len();
                let end = (start + len).min(mutated.len());
                for b in &mut mutated[start..end] {
                    *b = 0;
                }
            }
            _ => unreachable!(),
        }

        if mutated == valid_bytes {
            deser_fail += 1;
            if (i + 1) % 50 == 0 {
                eprintln!("[fuzz] progress: {}/{} (rejected={} deser_fail={} accepted={})", i + 1, n_mutations, rejected, deser_fail, accepted);
            }
            continue;
        }

        match SingleMessageAggregateSignature::from_bytes(&mutated) {
            None => { deser_fail += 1; }
            Some(sig) => {
                match verify_single_message_aggregate(&sig) {
                    Ok(_) => {
                        accepted += 1;
                        let mut diff_start = usize::MAX;
                        let mut diff_end = 0;
                        let mut n_diff = 0;
                        for (pos, (&orig, &mutd)) in valid_bytes.iter().zip(mutated.iter()).enumerate() {
                            if orig != mutd {
                                if diff_start == usize::MAX { diff_start = pos; }
                                diff_end = pos;
                                n_diff += 1;
                            }
                        }
                        eprintln!("[fuzz] ACCEPTED mutation {}! strategy={} — VERIFIER BUG", i, strategy);
                        eprintln!("[fuzz]   diff: {} bytes at {}..={} (len={})", n_diff, diff_start, diff_end, valid_bytes.len());
                        if n_diff <= 64 {
                            let s = diff_start.saturating_sub(4);
                            let e = (diff_end + 5).min(valid_bytes.len());
                            eprintln!("[fuzz]   original: {:?}", &valid_bytes[s..e]);
                            eprintln!("[fuzz]   mutated:  {:?}", &mutated[s..e]);
                        }
                    }
                    Err(_) => { rejected += 1; }
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
