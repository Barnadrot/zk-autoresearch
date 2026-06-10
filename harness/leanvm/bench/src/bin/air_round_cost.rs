//! Measures per-round cost of the batched AIR sumcheck sessions (base round 0 vs
//! extension-field rounds) to validate the univariate-skip cost model (h1, pw13).
//! Read-only diagnostic: drives the real AirSumcheckSession on synthetic columns.

use std::collections::BTreeMap;
use std::time::Instant;

use backend::*;
use lean_vm::*;
use sub_protocols::*;

fn run_table(table: Table, log_n: usize) {
    let n: usize = 1 << log_n;
    let n_cols = table.n_columns();
    let n_shift = table.n_shift_columns();

    let mut rng = 0x12345678u64;
    let mut next_f = move || {
        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        F::from_usize((rng >> 33) as usize % ((1 << 31) - (1 << 24)))
    };

    let cols: Vec<ArenaVec<F>> = (0..n_cols)
        .map(|_| (0..n).map(|_| next_f()).collect::<Vec<F>>().into_iter().collect())
        .collect();
    let col_refs: Vec<&[F]> = cols.iter().map(|c| c.as_slice()).collect();
    let shifted = compute_shifted_columns(n_shift, &col_refs);

    let mut flat_and_shift: Vec<&[F]> = col_refs.clone();
    flat_and_shift.extend(shifted.iter().map(|c| c.as_slice()));
    let packed = MleGroupRef::<EF>::Base(flat_and_shift).pack();

    let eq_factor: Vec<EF> = (0..log_n).map(|i| EF::from_usize(7 + i * 13)).collect();
    let logup_alphas: Vec<EF> = (0..LOG_MAX_BUS_WIDTH).map(|i| EF::from_usize(3 + i)).collect();
    let alpha = EF::from_usize(11);
    let alpha_powers: Vec<EF> = alpha.powers().collect_n(table.n_constraints());
    let extra = ExtraDataForBuses::new(&eval_eq(&logup_alphas), alpha_powers);

    macro_rules! make_session {
        ($t:expr) => {{
            let s = AirSumcheckSession::new(packed, eq_factor.clone(), EF::from_usize(42), *$t, extra, n);
            Box::new(s) as Box<dyn OuterSumcheckSession<EF> + '_>
        }};
    }
    let mut session = delegate_to_inner!(&table => make_session);

    println!("table={} log_n={} cols={}+{} degree={}", table.name(), log_n, n_cols, n_shift, session.bare_degree());
    let mut per_round = Vec::with_capacity(log_n);
    for round in 0..log_n {
        let t0 = Instant::now();
        let poly = session.compute_bare_round_poly();
        let t_poly = t0.elapsed().as_secs_f64() * 1e3;
        let t1 = Instant::now();
        session.process_challenge(EF::from_usize(5 + round), &poly);
        let t_fold = t1.elapsed().as_secs_f64() * 1e3;
        per_round.push(t_poly + t_fold);
        if round < 8 {
            println!("  round {:2}: poly {:8.3} ms  fold {:8.3} ms", round, t_poly, t_fold);
        }
    }
    let total: f64 = per_round.iter().sum();
    let sum_from = |k: usize| -> f64 { per_round.iter().skip(k).sum() };
    println!(
        "  total {:8.3} ms | rounds>=1: {:7.3} ms ({:.1}%) | rounds>=4: {:7.3} ms ({:.1}%) | rounds>=5: {:7.3} ms ({:.1}%)",
        total,
        sum_from(1), 100.0 * sum_from(1) / total,
        sum_from(4), 100.0 * sum_from(4) / total,
        sum_from(5), 100.0 * sum_from(5) / total,
    );
}

fn main() {
    let log_n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(18);
    // One prove_loop at a time discipline: this is not prove_loop, but keep it serial-friendly.
    run_table(Table::poseidon16(), log_n);
    run_table(Table::execution(), log_n.min(20));
    run_table(Table::extension_op(), 15);
}
