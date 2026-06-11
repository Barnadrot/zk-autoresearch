use criterion::{BatchSize, Criterion, criterion_group, criterion_main};
use goldilocks::Goldilocks;
use rec_aggregation::{init_aggregation_bytecode, aggregate_single_message_signatures};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1550;
const LOG_INV_RATE: usize = 1;

fn bench_xmss_leaf(c: &mut Criterion) {
    precompute_dft_twiddles::<Goldilocks>(1 << 24);
    init_aggregation_bytecode();

    #[cfg(feature = "zkalloc_global")]
    zk_alloc::enable_arena();

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
                let result = aggregate_single_message_signatures(&[], data, message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap();
                #[cfg(feature = "zkalloc_global")]
                zk_alloc::end_phase();
                result
            },
            BatchSize::LargeInput,
        );
    });
}

criterion_group!(
    name = benches;
    config = Criterion::default().noise_threshold(0.007);
    targets = bench_xmss_leaf
);
criterion_main!(benches);
