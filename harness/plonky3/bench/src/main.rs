use std::time::Instant;

use clap::Parser;
use p3_baby_bear::{
    BABYBEAR_POSEIDON1_HALF_FULL_ROUNDS, BABYBEAR_POSEIDON1_PARTIAL_ROUNDS_16,
    BABYBEAR_POSEIDON1_RC_16, BABYBEAR_S_BOX_DEGREE, BabyBear, MDSBabyBearData,
};
use p3_challenger::{HashChallenger, SerializingChallenger32};
use p3_commit::ExtensionMmcs;
use p3_field::PrimeCharacteristicRing;
use p3_field::extension::BinomialExtensionField;
use p3_fri::{FriParameters, TwoAdicFriPcs};
use p3_keccak::{Keccak256Hash, KeccakF};
use p3_merkle_tree::MerkleTreeMmcs;
use p3_monty_31::MDSUtils;
use p3_poseidon1::Poseidon1Constants;
use p3_poseidon1_air::{
    FullRoundConstants, PartialRoundConstants, Poseidon1Air, generate_trace_rows,
};
use p3_symmetric::{CompressionFunctionFromHasher, PaddingFreeSponge, SerializingHasher};
use p3_uni_stark::{StarkConfig, prove, verify};

#[cfg(feature = "zkalloc")]
#[global_allocator]
static ALLOC: zk_alloc::ZkAllocator = zk_alloc::ZkAllocator;

#[cfg(all(feature = "jemalloc", not(feature = "zkalloc")))]
#[global_allocator]
static ALLOC_JE: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

type Val = BabyBear;
type Challenge = BinomialExtensionField<Val, 4>;

const WIDTH: usize = 16;
const SBOX_DEGREE: u64 = BABYBEAR_S_BOX_DEGREE;
const SBOX_REGISTERS: usize = 1;
const HALF_FULL_ROUNDS: usize = BABYBEAR_POSEIDON1_HALF_FULL_ROUNDS;
const PARTIAL_ROUNDS: usize = BABYBEAR_POSEIDON1_PARTIAL_ROUNDS_16;

#[derive(Parser)]
struct Cli {
    #[arg(long, default_value = "18")]
    log_num_hashes: usize,
    #[arg(long, default_value = "3")]
    repeat: usize,
    #[arg(long)]
    verify: bool,
}

fn babybear_air_constants() -> (
    FullRoundConstants<Val, WIDTH>,
    PartialRoundConstants<Val, WIDTH>,
) {
    let raw = Poseidon1Constants {
        rounds_f: 2 * HALF_FULL_ROUNDS,
        rounds_p: PARTIAL_ROUNDS,
        mds_circ_col: MDSBabyBearData::MATRIX_CIRC_MDS_16_COL,
        round_constants: BABYBEAR_POSEIDON1_RC_16.to_vec(),
    };
    raw.to_optimized()
}

fn make_stark_config() -> (
    StarkConfig<
        TwoAdicFriPcs<
            Val,
            p3_dft::Radix2Bowers,
            MerkleTreeMmcs<
                [Val; p3_keccak::VECTOR_LEN],
                [u64; p3_keccak::VECTOR_LEN],
                SerializingHasher<PaddingFreeSponge<KeccakF, 25, 17, 4>>,
                CompressionFunctionFromHasher<PaddingFreeSponge<KeccakF, 25, 17, 4>, 2, 4>,
                2,
                4,
            >,
            ExtensionMmcs<
                Val,
                Challenge,
                MerkleTreeMmcs<
                    [Val; p3_keccak::VECTOR_LEN],
                    [u64; p3_keccak::VECTOR_LEN],
                    SerializingHasher<PaddingFreeSponge<KeccakF, 25, 17, 4>>,
                    CompressionFunctionFromHasher<PaddingFreeSponge<KeccakF, 25, 17, 4>, 2, 4>,
                    2,
                    4,
                >,
            >,
        >,
        Challenge,
        SerializingChallenger32<Val, HashChallenger<u8, Keccak256Hash, 32>>,
    >,
    usize,
) {
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
    (config, log_blowup)
}

fn main() {
    let cli = Cli::parse();
    let num_hashes = 1usize << cli.log_num_hashes;

    eprintln!(
        "Poseidon1 AIR: 2^{} = {} hashes, {} iterations",
        cli.log_num_hashes, num_hashes, cli.repeat
    );

    let (full_constants, partial_constants) = babybear_air_constants();
    let air: Poseidon1Air<Val, WIDTH, SBOX_DEGREE, SBOX_REGISTERS, HALF_FULL_ROUNDS, PARTIAL_ROUNDS> =
        Poseidon1Air::new(full_constants.clone(), partial_constants.clone());
    let (config, log_blowup) = make_stark_config();

    #[cfg(feature = "zkalloc")]
    {
        eprintln!("allocator: zk-alloc (bump+reset arena)");
        zk_alloc::phase_boundary(); // warmup
    }
    #[cfg(all(feature = "jemalloc", not(feature = "zkalloc")))]
    eprintln!("allocator: jemalloc");
    #[cfg(not(any(feature = "zkalloc", feature = "jemalloc")))]
    eprintln!("allocator: system (glibc)");

    for i in 0..cli.repeat {
        #[cfg(feature = "zkalloc")]
        zk_alloc::phase_boundary();

        let t = Instant::now();

        let inputs: Vec<[Val; WIDTH]> = (0..num_hashes)
            .map(|i| core::array::from_fn(|j| Val::from_u32((i * WIDTH + j) as u32)))
            .collect();
        let trace = generate_trace_rows::<
            _,
            WIDTH,
            SBOX_DEGREE,
            SBOX_REGISTERS,
            HALF_FULL_ROUNDS,
            PARTIAL_ROUNDS,
        >(inputs, &full_constants, &partial_constants, log_blowup);

        let proof = prove(&config, &air, trace, &[]);

        let elapsed = t.elapsed().as_secs_f64();

        if cli.verify {
            verify(&config, &air, &proof, &[]).expect("verification failed");
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
        }
        #[cfg(not(feature = "zkalloc"))]
        eprintln!("  proof {}/{}: {:.3}s{}", i + 1, cli.repeat, elapsed,
            if cli.verify { " (verified)" } else { "" });

        #[cfg(feature = "zkalloc")]
        zk_alloc::deactivate_arena();
    }
}
