use std::hint::black_box;

use criterion::{Criterion, criterion_group, criterion_main};
use mt_koala_bear::symmetric::Permutation;
use mt_koala_bear::{KoalaBear, default_koalabear_poseidon1_16};
use backend::{Field, PrimeCharacteristicRing};

type FPacking = <KoalaBear as Field>::Packing;
const WIDTH: usize = 16;

fn bench_permute_packed(c: &mut Criterion) {
    let perm = default_koalabear_poseidon1_16();

    // Non-zero state to exercise all arithmetic paths
    let mut init_state: [FPacking; WIDTH] = [FPacking::ZERO; WIDTH];
    for (i, s) in init_state.iter_mut().enumerate() {
        *s = FPacking::from(KoalaBear::from_u64((i as u64 + 1) * 0x1234567));
    }

    c.bench_function("poseidon_permute_packed", |b| {
        let mut state = init_state;
        b.iter(|| {
            perm.permute_mut(&mut state);
            black_box(&state);
        });
    });
}

fn bench_compress_in_place(c: &mut Criterion) {
    let perm = default_koalabear_poseidon1_16();

    let mut init_state: [FPacking; WIDTH] = [FPacking::ZERO; WIDTH];
    for (i, s) in init_state.iter_mut().enumerate() {
        *s = FPacking::from(KoalaBear::from_u64((i as u64 + 1) * 0x1234567));
    }

    c.bench_function("poseidon_compress_packed", |b| {
        let mut state = init_state;
        b.iter(|| {
            perm.compress_in_place(&mut state);
            black_box(&state);
        });
    });
}

fn bench_permute_scalar(c: &mut Criterion) {
    let perm = default_koalabear_poseidon1_16();

    let mut init_state: [KoalaBear; WIDTH] = [KoalaBear::ZERO; WIDTH];
    for (i, s) in init_state.iter_mut().enumerate() {
        *s = KoalaBear::from_u64((i as u64 + 1) * 0x1234567);
    }

    c.bench_function("poseidon_permute_scalar", |b| {
        let mut state = init_state;
        b.iter(|| {
            perm.permute_mut(&mut state);
            black_box(&state);
        });
    });
}

criterion_group!(benches, bench_permute_packed, bench_compress_in_place, bench_permute_scalar);
criterion_main!(benches);
