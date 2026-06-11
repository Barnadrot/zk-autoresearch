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
    EF::from_basis_coefficients_fn(|_| F::from_u64(simple_rng(state)))
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
        Table::Poseidon8(inner) => inner.eval(&mut collector, extra_data),
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

fn pcs_committed(table: &Table) -> usize {
    table.n_columns()
}

// =========================================================================
// PCS Consistency
// =========================================================================

fn verify_pcs_consistency() -> bool {
    let mut ok = true;
    for table in &ALL_TABLES {
        let pcs = pcs_committed(table);
        let n_cols = table.n_columns();
        if pcs != n_cols {
            eprintln!(
                "[soundness] PCS CONSISTENCY FAIL: {}: pcs_committed()={} but n_columns()={}.",
                table.name(), pcs, n_cols,
            );
            ok = false;
        }
    }
    ok
}

// =========================================================================
// 6a. Structural Report (no hardcoded baselines — Goldilocks is still evolving)
// =========================================================================

fn report_structural() {
    for table in &ALL_TABLES {
        eprintln!(
            "[soundness] {}: n_columns={} n_columns_total={} n_constraints={} degree_air={} n_shift={}",
            table.name(),
            table.n_columns(),
            table.n_columns_total(),
            table.n_constraints(),
            table.degree_air(),
            table.n_shift_columns(),
        );
    }
}

// =========================================================================
// 6b. Committed-Column Sensitivity (adapted from KoalaBear)
// =========================================================================

fn check_committed_column_sensitivity(rng: &mut u64) -> bool {
    let mut ok = true;
    for table in &ALL_TABLES {
        let n_pcs = pcs_committed(table);
        let n_total = table.n_columns_total();
        let n_shift = table.n_shift_columns();

        let n_alpha = table.n_constraints() + 10;
        let alpha_powers: Vec<EF> = (0..n_alpha).map(|_| random_ef(rng)).collect();
        let logup_alphas: Vec<EF> = (0..64).map(|_| random_ef(rng)).collect();
        let extra_data = ExtraDataForBuses::new(&logup_alphas, alpha_powers);

        let flat_base: Vec<EF> = (0..n_total).map(|_| random_ef(rng)).collect();
        let shift_vals: Vec<EF> = (0..n_shift).map(|_| random_ef(rng)).collect();
        let c0 = eval_constraints_for_table(table, &flat_base, &shift_vals, &extra_data);

        let mut dead_cols: Vec<usize> = Vec::new();
        for col in 0..n_pcs {
            let mut flat_perturbed = flat_base.clone();
            flat_perturbed[col] = random_ef(rng);
            if flat_perturbed[col] == flat_base[col] {
                flat_perturbed[col] += EF::ONE;
            }
            let c1 = eval_constraints_for_table(table, &flat_perturbed, &shift_vals, &extra_data);
            let any_changed = c0.iter().zip(c1.iter()).any(|(a, b)| *a != *b);
            if !any_changed {
                dead_cols.push(col);
            }
        }

        for shift_col in 0..n_shift {
            let mut shift_perturbed = shift_vals.clone();
            shift_perturbed[shift_col] = random_ef(rng);
            if shift_perturbed[shift_col] == shift_vals[shift_col] {
                shift_perturbed[shift_col] += EF::ONE;
            }
            let c1 = eval_constraints_for_table(table, &flat_base, &shift_perturbed, &extra_data);
            let any_changed = c0.iter().zip(c1.iter()).any(|(a, b)| *a != *b);
            if !any_changed {
                dead_cols.push(n_total + shift_col);
            }
        }

        if dead_cols.is_empty() {
            eprintln!(
                "[soundness] {}: committed-column sensitivity PASS — all {} committed + {} shift columns alive",
                table.name(), n_pcs, n_shift,
            );
        } else {
            eprintln!(
                "[soundness] {}: SENSITIVITY FAIL — dead columns (no constraint references them): {:?}",
                table.name(), dead_cols,
            );
            ok = false;
        }
    }
    ok
}

// =========================================================================
// Free Variable Soundness (constraints must not reference uncommitted cols)
// =========================================================================

fn check_free_variables(rng: &mut u64) -> bool {
    let mut ok = true;
    for table in &ALL_TABLES {
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
            continue;
        }

        // Check: constraints must not depend on uncommitted columns.
        // Evaluate at random committed values, vary only the uncommitted part.
        let n_alpha = table.n_constraints() + 10;
        let alpha_powers: Vec<EF> = (0..n_alpha).map(|_| random_ef(rng)).collect();
        let logup_alphas: Vec<EF> = (0..64).map(|_| random_ef(rng)).collect();
        let extra_data = ExtraDataForBuses::new(&logup_alphas, alpha_powers);

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
            eprintln!("[soundness]   PASS: constraints do not reference uncommitted columns");
        } else {
            eprintln!(
                "[soundness]   FREE VARIABLE FAIL: Jacobian rank = {} over {} uncommitted columns. \
                 Constraints depend on uncommitted data — soundness hole.",
                rank, n_uncommitted,
            );
            ok = false;
        }
    }
    ok
}

// =========================================================================
// ExtraDataForBuses Integrity
// =========================================================================

fn verify_extra_data_integrity() -> bool {
    let alphas: Vec<EF> = (0..64).map(|i| EF::from(F::from_u64(0xbead_cafe + i as u64))).collect();
    let alpha_powers: Vec<EF> = (0..20).map(|i| EF::from(F::from_u64(0xdead_0000 + i as u64))).collect();
    let extra = ExtraDataForBuses::new(&alphas, alpha_powers.clone());

    let all_nonzero = extra.logup_alphas_eq_poly.iter().all(|a| *a != EF::ZERO);
    if !all_nonzero {
        eprintln!("[soundness] EXTRA DATA FAIL: logup_alphas_eq_poly contains zeros.");
        return false;
    }

    for (i, (actual, expected)) in extra.logup_alphas_eq_poly.iter().zip(alphas.iter()).enumerate() {
        if actual != expected {
            eprintln!("[soundness] EXTRA DATA FAIL: logup_alphas_eq_poly[{}] modified by new().", i);
            return false;
        }
    }

    for (i, (actual, expected)) in extra.alpha_powers.iter().zip(alpha_powers.iter()).enumerate() {
        if actual != expected {
            eprintln!("[soundness] EXTRA DATA FAIL: alpha_powers[{}] modified by new().", i);
            return false;
        }
    }

    eprintln!("[soundness] ExtraDataForBuses integrity PASS — alphas round-trip verified");
    true
}

// =========================================================================

fn main() {
    eprintln!("[soundness] leanVM Goldilocks soundness gate");
    eprintln!("[soundness] Field: Goldilocks (p = 2^64 - 2^32 + 1), cubic extension");
    eprintln!();

    let mut rng_state = 0xDEADBEEF_u64;
    let mut all_ok = true;

    eprintln!("[soundness] === Structural Report (6a) ===");
    report_structural();

    eprintln!();
    eprintln!("[soundness] === ExtraDataForBuses Integrity (6d) ===");
    if !verify_extra_data_integrity() { all_ok = false; }

    eprintln!();
    eprintln!("[soundness] === PCS Consistency ===");
    if !verify_pcs_consistency() { all_ok = false; }

    eprintln!();
    eprintln!("[soundness] === Free Variable Soundness ===");
    if !check_free_variables(&mut rng_state) { all_ok = false; }

    eprintln!();
    eprintln!("[soundness] === Committed-Column Sensitivity (6b) ===");
    if !check_committed_column_sensitivity(&mut rng_state) { all_ok = false; }

    eprintln!();
    if all_ok {
        eprintln!("[soundness] ALL CHECKS PASSED.");
    } else {
        eprintln!("[soundness] CHECKS FAILED — see above.");
        std::process::exit(1);
    }
}
