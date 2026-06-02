use backend::*;
use lean_vm::*;

const N_TRIALS: usize = 20;

struct ConstraintCollector {
    flat: Vec<EF>,
    shift: Vec<EF>,
    constraints: Vec<EF>,
}

impl ConstraintCollector {
    fn new(flat: Vec<EF>, shift: Vec<EF>) -> Self {
        Self { flat, shift, constraints: Vec::new() }
    }
}

impl AirBuilder for ConstraintCollector {
    type F = F;
    type IF = EF;
    type EF = EF;
    fn flat(&self) -> &[EF] { &self.flat }
    fn shift(&self) -> &[EF] { &self.shift }
    fn assert_zero(&mut self, x: EF) { self.constraints.push(x); }
    fn assert_zero_ef(&mut self, x: EF) { self.constraints.push(x); }
}

fn simple_rng(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

fn random_ef(state: &mut u64) -> EF {
    EF::from(F::from_u64(simple_rng(state)))
}

fn eval_constraints_for_table(
    table: &Table,
    flat: &[EF],
    shift: &[EF],
    extra_data: &ExtraDataForBuses<EF>,
) -> Vec<EF> {
    let mut collector = ConstraintCollector::new(flat.to_vec(), shift.to_vec());
    match table {
        Table::Execution(inner) => inner.eval(&mut collector, extra_data),
        Table::Poseidon16(inner) => inner.eval(&mut collector, extra_data),
        Table::ExtensionOp(inner) => inner.eval(&mut collector, extra_data),
    }
    collector.constraints
}

fn gaussian_rank(matrix: &[Vec<EF>]) -> usize {
    if matrix.is_empty() { return 0; }
    let n_rows = matrix.len();
    let n_cols = matrix[0].len();
    let mut mat: Vec<Vec<EF>> = matrix.to_vec();
    let mut rank = 0;

    for col in 0..n_cols {
        let mut pivot = None;
        for row in rank..n_rows {
            if mat[row][col] != EF::ZERO {
                pivot = Some(row);
                break;
            }
        }
        let Some(pivot_row) = pivot else { continue };
        mat.swap(rank, pivot_row);
        let inv = mat[rank][col].inverse();
        for j in 0..n_cols {
            mat[rank][j] *= inv;
        }
        for row in 0..n_rows {
            if row == rank { continue; }
            let factor = mat[row][col];
            if factor == EF::ZERO { continue; }
            for j in 0..n_cols {
                let val = mat[rank][j] * factor;
                mat[row][j] -= val;
            }
        }
        rank += 1;
    }
    rank
}

fn check_table(table: &Table, rng: &mut u64) -> bool {
    let n_committed = table.n_columns();
    let n_total = table.n_columns_total();
    let n_virtual = n_total - n_committed;
    let n_constraints = table.n_constraints();
    let n_shift = table.n_shift_columns();

    if n_virtual == 0 {
        eprintln!(
            "[soundness] {}: no virtual columns — PASS",
            table.name()
        );
        return true;
    }

    let bus_interactions = table.bus_interactions();
    let mut bus_virtual_cols = std::collections::BTreeSet::new();
    for bus in &bus_interactions {
        if let BusMultiplicity::Column(c) = bus.multiplicity {
            if c >= n_committed { bus_virtual_cols.insert(c); }
        }
        if let Some(c) = bus.domainsep.column() {
            if c >= n_committed { bus_virtual_cols.insert(c); }
        }
        for d in &bus.data {
            if let Some(c) = d.column() {
                if c >= n_committed { bus_virtual_cols.insert(c); }
            }
        }
    }
    let n_bus_accounted = bus_virtual_cols.len();
    let n_free = n_virtual.saturating_sub(n_bus_accounted);

    // Static check: any virtual column not even referenced by bus?
    if n_free > 0 {
        let all_virtual: std::collections::BTreeSet<usize> = (n_committed..n_total).collect();
        let unaccounted: Vec<_> = all_virtual.difference(&bus_virtual_cols).collect();
        eprintln!(
            "[soundness] {}: {} virtual columns not referenced by ANY bus interaction!",
            table.name(), n_free,
        );
        eprintln!("[soundness]   unaccounted column indices: {:?}", unaccounted);
        eprintln!("[soundness]   STATIC CHECK FAIL");
        return false;
    }

    // Numerical check: evaluate constraints with varying virtual columns.
    // If varying virtual columns changes constraint values in more independent
    // directions than there are constraints binding them, the system is
    // underdetermined and a malicious prover can forge proofs.

    let n_alpha = n_constraints + 10;
    let alpha_powers: Vec<EF> = (0..n_alpha).map(|_| random_ef(rng)).collect();
    let logup_alphas: Vec<EF> = (0..64).map(|_| random_ef(rng)).collect();
    let extra_data = ExtraDataForBuses::new(logup_alphas, alpha_powers);

    let committed: Vec<EF> = (0..n_committed).map(|_| random_ef(rng)).collect();
    let shift: Vec<EF> = (0..n_shift).map(|_| random_ef(rng)).collect();

    let mut baseline_virtual: Vec<EF> = (0..n_virtual).map(|_| random_ef(rng)).collect();
    let mut flat0 = committed.clone();
    flat0.extend_from_slice(&baseline_virtual);
    let c0 = eval_constraints_for_table(table, &flat0, &shift, &extra_data);
    let n_actual_constraints = c0.len();

    // For each trial, vary virtual columns and record the constraint DIFFERENCE
    // from baseline. The matrix rows are (C(c, v_k) - C(c, v_0)) for k=1..N_TRIALS.
    // The rank of this matrix = number of independent constraint directions
    // controlled by virtual columns.
    let mut diff_matrix: Vec<Vec<EF>> = Vec::new();

    for _ in 0..N_TRIALS {
        baseline_virtual = (0..n_virtual).map(|_| random_ef(rng)).collect();
        let mut flat_k = committed.clone();
        flat_k.extend_from_slice(&baseline_virtual);
        let ck = eval_constraints_for_table(table, &flat_k, &shift, &extra_data);

        let diff: Vec<EF> = ck.iter().zip(c0.iter()).map(|(a, b)| *a - *b).collect();
        diff_matrix.push(diff);
    }

    let affected_rank = gaussian_rank(&diff_matrix);

    eprintln!(
        "[soundness] {}: committed={} virtual={} constraints={} bus_accounted={} constraint_rank_from_virtual={}",
        table.name(), n_committed, n_virtual, n_actual_constraints, n_bus_accounted, affected_rank,
    );

    if n_virtual > affected_rank {
        let free_dims = n_virtual - affected_rank;
        eprintln!(
            "[soundness]   NUMERICAL CHECK FAIL: {} virtual columns but only {} independent \
             constraints bind them → {} free dimensions. A malicious prover can choose \
             {} column evaluations arbitrarily at the AIR sumcheck endpoint.",
            n_virtual, affected_rank, free_dims, free_dims,
        );
        return false;
    }

    eprintln!(
        "[soundness]   PASS: {} virtual columns fully constrained by {} independent constraint directions",
        n_virtual, affected_rank,
    );
    true
}

fn main() {
    let mut rng_state: u64 = 0xdeadbeef_cafebabe;
    let mut all_ok = true;

    for table in &ALL_TABLES {
        if !check_table(table, &mut rng_state) {
            all_ok = false;
        }
    }

    if all_ok {
        eprintln!("[soundness] PASS — all virtual columns fully constrained.");
    } else {
        eprintln!("[soundness] FAIL — underdetermined virtual columns detected!");
        std::process::exit(1);
    }
}
