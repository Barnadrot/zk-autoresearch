// Criterion benchmark for leanMultisig DFT autoresearch loop.
//
// Measures: xmss_aggregate — full leaf proving cycle for N XMSS signatures.
// This covers the entire hot path: DFT (WHIR commitments), Poseidon2, Sumcheck.
//
// Target: lower median latency with p < 0.05 and improvement > 0.20%.
//
// N_SIGS is kept small enough to keep bench time under ~10s per run.
// Tune it based on throughput on the server (~700-800 XMSS/s → 100 sigs ≈ 130ms).

use criterion::{BatchSize, Criterion, criterion_group, criterion_main};
use mt_koala_bear::KoalaBear;
use rec_aggregation::{init_aggregation_bytecode, xmss_aggregate};
use xmss::signers_cache::{BENCHMARK_SLOT, get_benchmark_signatures, message_for_benchmark};
use backend::precompute_dft_twiddles;

const N_SIGS: usize = 100;
const LOG_INV_RATE: usize = 1;

fn bench_xmss_leaf(c: &mut Criterion) {
    // One-time setup — excluded from measurement
    precompute_dft_twiddles::<KoalaBear>(1 << 24);
    init_aggregation_bytecode();

    let raw_xmss: Vec<_> = get_benchmark_signatures()[..N_SIGS].to_vec();
    let message = message_for_benchmark();

    c.bench_function(&format!("xmss_leaf_{N_SIGS}sigs"), |b| {
        b.iter_batched(
            || raw_xmss.clone(),
            |data| xmss_aggregate(&[], data, &message, BENCHMARK_SLOT, LOG_INV_RATE),
            BatchSize::LargeInput,
        );
    });
}

criterion_group!(benches, bench_xmss_leaf);
criterion_main!(benches);
