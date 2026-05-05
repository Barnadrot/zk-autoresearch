// Identical to xmss_leaf.rs but WITHOUT the zkalloc global_allocator.
// Always uses glibc. Used as the baseline half of eval_paired.sh.

use criterion::{BatchSize, Criterion, criterion_group, criterion_main};
use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 1400;
const LOG_INV_RATE: usize = 1;

fn bench_xmss_leaf(c: &mut Criterion) {
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();

    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    c.bench_function(&format!("xmss_leaf_{N_SIGS}sigs"), |b| {
        b.iter_batched(
            || raw_xmss.clone(),
            |data| xmss_aggregate(&[], data, &message, BENCHMARK_SLOT, LOG_INV_RATE).unwrap(),
            BatchSize::LargeInput,
        );
    });
}

criterion_group!(benches, bench_xmss_leaf);
criterion_main!(benches);
