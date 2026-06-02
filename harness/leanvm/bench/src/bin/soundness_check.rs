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

/// Returns the number of columns the stacked PCS actually commits for this
/// table. This mirrors the loop in `stack_polynomials_and_commit` which
/// iterates `0..table.n_columns()`. If the codebase adds
/// `n_committed_columns()` to the Air trait (as pw8/h44 did), the stacked
/// PCS uses THAT instead, and this function must be updated to match.
///
/// The invariant: pcs_committed(table) == the column count the stacked PCS
/// copies into the global polynomial for this table.
fn pcs_committed(table: &Table) -> usize {
    // On main: stacked_pcs.rs line 134 uses `table.n_columns()`
    // If a branch overrides n_committed_columns(), it would be used there.
    // We compile against whatever the target repo has.
    table.n_columns()
}

fn check_table(table: &Table, rng: &mut u64) -> bool {
    let n_pcs = pcs_committed(table);
    let n_total = table.n_columns_total();
    let n_uncommitted = n_total - n_pcs;
    let n_shift = table.n_shift_columns();

    eprintln!(
        "[soundness] {}: pcs_committed={} total={} uncommitted={} constraints={} shift={}",
        table.name(), n_pcs, n_total, n_uncommitted,
        table.n_constraints(), n_shift,
    );

    if n_uncommitted == 0 {
        eprintln!("[soundness]   PASS: all columns committed to PCS");
        return true;
    }

    // Phase 1: Static check — any uncommitted column not referenced by bus?
    let bus_interactions = table.bus_interactions();
    let mut bus_uncommitted_cols = std::collections::BTreeSet::new();
    for bus in &bus_interactions {
        if let BusMultiplicity::Column(c) = bus.multiplicity {
            if c >= n_pcs { bus_uncommitted_cols.insert(c); }
        }
        if let Some(c) = bus.domainsep.column() {
            if c >= n_pcs { bus_uncommitted_cols.insert(c); }
        }
        for d in &bus.data {
            if let Some(c) = d.column() {
                if c >= n_pcs { bus_uncommitted_cols.insert(c); }
            }
        }
    }
    let n_bus_accounted = bus_uncommitted_cols.len();
    let n_unbound = n_uncommitted.saturating_sub(n_bus_accounted);

    if n_unbound > 0 {
        let all_uncommitted: std::collections::BTreeSet<usize> = (n_pcs..n_total).collect();
        let unaccounted: Vec<_> = all_uncommitted.difference(&bus_uncommitted_cols).collect();
        eprintln!(
            "[soundness]   STATIC FAIL: {} uncommitted columns not referenced by any bus interaction",
            n_unbound,
        );
        eprintln!("[soundness]   unaccounted column indices: {:?}", unaccounted);
        return false;
    }

    // Phase 2: Numerical check — evaluate AIR constraints with random column
    // values. Fix PCS-committed columns, vary uncommitted columns.
    // Compute the rank of the resulting constraint difference matrix.
    //
    // - rank == 0: constraints don't reference uncommitted columns at all.
    //   The AIR eval recomputes derived values from committed columns.
    //   This is SOUND — the constraints are self-contained.
    //
    // - 0 < rank < n_uncommitted: constraints DO reference uncommitted
    //   columns but the system is underdetermined. A malicious prover
    //   can choose (n_uncommitted - rank) column evaluations arbitrarily.
    //   This is UNSOUND.
    //
    // - rank >= n_uncommitted: all uncommitted columns are fully constrained.
    //   This is SOUND.

    let n_alpha = table.n_constraints() + 10;
    let alpha_powers: Vec<EF> = (0..n_alpha).map(|_| random_ef(rng)).collect();
    let logup_alphas: Vec<EF> = (0..64).map(|_| random_ef(rng)).collect();
    let extra_data = ExtraDataForBuses::new(logup_alphas, alpha_powers);

    let committed_vals: Vec<EF> = (0..n_pcs).map(|_| random_ef(rng)).collect();
    let shift_vals: Vec<EF> = (0..n_shift).map(|_| random_ef(rng)).collect();

    let baseline: Vec<EF> = (0..n_uncommitted).map(|_| random_ef(rng)).collect();
    let mut flat0 = committed_vals.clone();
    flat0.extend_from_slice(&baseline);
    let c0 = eval_constraints_for_table(table, &flat0, &shift_vals, &extra_data);

    let mut diff_matrix: Vec<Vec<EF>> = Vec::new();
    for _ in 0..N_TRIALS {
        let trial: Vec<EF> = (0..n_uncommitted).map(|_| random_ef(rng)).collect();
        let mut flat_k = committed_vals.clone();
        flat_k.extend_from_slice(&trial);
        let ck = eval_constraints_for_table(table, &flat_k, &shift_vals, &extra_data);
        let diff: Vec<EF> = ck.iter().zip(c0.iter()).map(|(a, b)| *a - *b).collect();
        diff_matrix.push(diff);
    }

    let rank = gaussian_rank(&diff_matrix);

    if rank == 0 {
        eprintln!(
            "[soundness]   PASS: AIR constraints do not reference uncommitted columns \
             (eval recomputes from committed columns)",
        );
        return true;
    }

    if rank >= n_uncommitted {
        eprintln!(
            "[soundness]   PASS: {} uncommitted columns fully constrained ({} independent directions)",
            n_uncommitted, rank,
        );
        return true;
    }

    let free = n_uncommitted - rank;
    eprintln!(
        "[soundness]   NUMERICAL FAIL: {} uncommitted columns in constraints but only {} \
         independent directions bind them → {} free dimensions",
        n_uncommitted, rank, free,
    );
    eprintln!(
        "[soundness]   A malicious prover can choose {} column evaluations \
         arbitrarily at the AIR sumcheck endpoint r_air.",
        free,
    );
    false
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
        eprintln!("[soundness] PASS — all tables sound.");
    } else {
        eprintln!("[soundness] FAIL — underdetermined columns detected!");
        std::process::exit(1);
    }
}
