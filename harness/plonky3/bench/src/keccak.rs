use std::time::Instant;

use clap::Parser;
use p3_baby_bear::BabyBear;
use p3_challenger::{HashChallenger, SerializingChallenger32};
use p3_commit::ExtensionMmcs;
use p3_field::extension::BinomialExtensionField;
use p3_fri::{FriParameters, TwoAdicFriPcs};
use p3_keccak::{Keccak256Hash, KeccakF};
use p3_keccak_air::{KeccakAir, generate_trace_rows};
use p3_merkle_tree::MerkleTreeMmcs;
use p3_symmetric::{CompressionFunctionFromHasher, PaddingFreeSponge, SerializingHasher};
use p3_uni_stark::{StarkConfig, prove, verify};
use rand::SeedableRng;
use rand::rngs::SmallRng;

#[cfg(feature = "zkalloc")]
#[global_allocator]
static ALLOC: zk_alloc::ZkAllocator = zk_alloc::ZkAllocator;

#[cfg(all(feature = "jemalloc", not(feature = "zkalloc")))]
#[global_allocator]
static ALLOC_JE: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

type Val = BabyBear;
type Challenge = BinomialExtensionField<Val, 4>;

#[derive(Parser)]
struct Cli {
    #[arg(long, default_value = "1365")]
    num_hashes: usize,
    #[arg(long, default_value = "3")]
    repeat: usize,
    #[arg(long)]
    verify: bool,
}

fn main() {
    let cli = Cli::parse();

    let trace_rows = (cli.num_hashes * 24).next_power_of_two();
    eprintln!(
        "Keccak AIR (BabyBear): {} hashes, {} trace rows (2^{:.0}), {} iterations",
        cli.num_hashes,
        trace_rows,
        (trace_rows as f64).log2(),
        cli.repeat
    );

    let byte_hash = Keccak256Hash {};
    let u64_hash = PaddingFreeSponge::<KeccakF, 25, 17, 4>::new(KeccakF {});
    let field_hash = SerializingHasher::new(u64_hash);
    let compress = CompressionFunctionFromHasher::<_, 2, 4>::new(u64_hash);
    let val_mmcs = MerkleTreeMmcs::<
        [Val; p3_keccak::VECTOR_LEN],
        [u64; p3_keccak::VECTOR_LEN],
        _,
        _,
        2,
        4,
    >::new(field_hash, compress, 3);
    let challenge_mmcs = ExtensionMmcs::<Val, Challenge, _>::new(val_mmcs.clone());
    let challenger =
        SerializingChallenger32::<Val, HashChallenger<u8, _, 32>>::from_hasher(vec![], byte_hash);
    let fri_params = FriParameters::new_benchmark(challenge_mmcs);
    let log_blowup = fri_params.log_blowup;
    let dft = p3_dft::Radix2Bowers;
    let pcs = TwoAdicFriPcs::new(dft, val_mmcs, fri_params);
    let config = StarkConfig::new(pcs, challenger);

    #[cfg(feature = "zkalloc")]
    {
        eprintln!("allocator: zk-alloc (bump+reset arena)");
        zk_alloc::begin_phase();
    }
    #[cfg(all(feature = "jemalloc", not(feature = "zkalloc")))]
    eprintln!("allocator: jemalloc");
    #[cfg(not(any(feature = "zkalloc", feature = "jemalloc")))]
    eprintln!("allocator: system (glibc)");

    let mut rng = SmallRng::seed_from_u64(1);

    for i in 0..cli.repeat {
        #[cfg(feature = "zkalloc")]
        zk_alloc::begin_phase();

        let t = Instant::now();

        let inputs: Vec<[u64; 25]> = (0..cli.num_hashes)
            .map(|_| {
                use rand::RngExt;
                rng.random()
            })
            .collect();
        let trace = generate_trace_rows::<Val>(inputs, log_blowup);
        let proof = prove(&config, &KeccakAir {}, trace, &[]);

        let elapsed = t.elapsed().as_secs_f64();

        if cli.verify {
            verify(&config, &KeccakAir {}, &proof, &[]).expect("verification failed");
        }

        #[cfg(feature = "zkalloc")]
        {
            let (count, bytes) = zk_alloc::overflow_stats();
            let v = if cli.verify { " verified" } else { "" };
            if count > 0 {
                eprintln!(
                    "  proof {}/{}: {:.3}s{v}  OVERFLOW: {} allocs, {:.1} MB",
                    i + 1, cli.repeat, elapsed, count, bytes as f64 / (1024.0 * 1024.0)
                );
            } else {
                eprintln!("  proof {}/{}: {:.3}s{v}  (no overflow)", i + 1, cli.repeat, elapsed);
            }
            zk_alloc::reset_overflow_stats();
            zk_alloc::end_phase();
        }
        #[cfg(not(feature = "zkalloc"))]
        eprintln!("  proof {}/{}: {:.3}s{}", i + 1, cli.repeat, elapsed,
            if cli.verify { " (verified)" } else { "" });
    }
}
