// Criterion benchmark for leanMultisig DFT autoresearch loop.
//
// Measures: xmss_aggregate — full leaf proving cycle for N XMSS signatures.
// This covers the entire hot path: DFT (WHIR commitments), Poseidon2, Sumcheck.
//
// Target: lower median latency with p < 0.05 and improvement > 0.20%.
//
// N_SIGS is kept small enough to keep bench time under ~10s per run.
// Tune it based on throughput on the server (~700-800 XMSS/s → 100 sigs ≈ 130ms).

#[cfg(feature = "zkalloc_global")]
#[global_allocator]
static GLOBAL: zk_alloc::ZkAllocator = zk_alloc::ZkAllocator;

use criterion::{BatchSize, Criterion, criterion_group, criterion_main};
use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, aggregate_type_1};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

fn bench_xmss_leaf(c: &mut Criterion) {
    // One-time setup — excluded from measurement
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();

    #[cfg(feature = "zkalloc_global")]
    zk_alloc::init();

    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    c.bench_function(&format!("xmss_leaf_{N_SIGS}sigs"), |b| {
        b.iter_batched(
            || {
                #[cfg(feature = "zkalloc_global")]
                zk_alloc::begin_phase();
                raw_xmss.clone()
            },
            |data| {
                let result = aggregate_type_1(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
                #[cfg(feature = "zkalloc_global")]
                zk_alloc::end_phase();
                result
            },
            BatchSize::LargeInput,
        );
    });
}

// noise_threshold tuned for Hetzner Zen 4 idle σ ≈ 0.51% (per profiling memory).
// 0.7% is just above σ so genuine sub-fast-tier (1.0%) wins still classify as
// "improved" rather than "within noise threshold" — matches the eval_ship_gate.sh
// confirmation tier's role. Re-tune for substantially different hardware noise floors.
criterion_group!(
    name = benches;
    config = Criterion::default().noise_threshold(0.007);
    targets = bench_xmss_leaf
);
criterion_main!(benches);
