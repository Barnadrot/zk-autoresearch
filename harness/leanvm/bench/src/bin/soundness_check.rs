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

/// Columns the stacked PCS commits for this table.
/// Mirrors stack_polynomials_and_commit: `for col_index in 0..table.n_columns()`.
fn pcs_committed(table: &Table) -> usize {
    table.n_columns()
}

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
// 6a. Structural Baseline Check
// =========================================================================

struct TableBaseline {
    name: &'static str,
    n_columns: usize,
    n_constraints: usize,
    n_columns_total: usize,
    degree_air: usize,
    n_shift: usize,
    low_degree_air: Option<(usize, usize)>,
}

const BASELINE: &[TableBaseline] = &[
    TableBaseline { name: "execution",    n_columns: 20,  n_constraints: 14, n_columns_total: 24,  degree_air: 5,  n_shift: 2,  low_degree_air: None },
    TableBaseline { name: "extension_op", n_columns: 29,  n_constraints: 35, n_columns_total: 31,  degree_air: 6,  n_shift: 13, low_degree_air: None },
    TableBaseline { name: "poseidon16",   n_columns: 110, n_constraints: 96, n_columns_total: 112, degree_air: 10, n_shift: 0,  low_degree_air: Some((3, 20)) },
];

fn verify_structural_baseline() -> bool {
    let mut ok = true;
    for (table, baseline) in ALL_TABLES.iter().zip(BASELINE.iter()) {
        let checks = [
            ("n_columns",       table.n_columns(),       baseline.n_columns),
            ("n_constraints",   table.n_constraints(),   baseline.n_constraints),
            ("n_columns_total", table.n_columns_total(),  baseline.n_columns_total),
            ("degree_air",      table.degree_air(),      baseline.degree_air),
            ("n_shift",         table.n_shift_columns(), baseline.n_shift),
        ];
        for (field, actual, min) in &checks {
            if *actual < *min {
                eprintln!(
                    "[soundness] BASELINE FAIL: {}.{}() = {} < {} (baseline minimum). \
                     Column/constraint/degree removal is a soundness-critical change \
                     that requires human approval.",
                    baseline.name, field, actual, min,
                );
                ok = false;
            }
        }
        let actual_lda = match table {
            Table::Poseidon16(inner) => inner.low_degree_air(),
            _ => table.low_degree_air(),
        };
        if actual_lda != baseline.low_degree_air {
            eprintln!(
                "[soundness] BASELINE FAIL: {}.low_degree_air() = {:?} but expected {:?}. \
                 low_degree_air controls how partial round constraints are split between \
                 high-degree and low-degree sumcheck passes. Changing it alters constraint \
                 evaluation semantics in the actual prover.",
                baseline.name, actual_lda, baseline.low_degree_air,
            );
            ok = false;
        }
        eprintln!(
            "[soundness] {}: baseline check — cols={}/{} constraints={}/{} degree={}/{} shift={}/{} lda={:?}/{:?}",
            baseline.name,
            table.n_columns(), baseline.n_columns,
            table.n_constraints(), baseline.n_constraints,
            table.degree_air(), baseline.degree_air,
            table.n_shift_columns(), baseline.n_shift,
            actual_lda, baseline.low_degree_air,
        );
    }
    ok
}

// =========================================================================
// 6b. Per-Committed-Column Sensitivity Test
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

        // Also check shift columns
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
                "[soundness] {}: SENSITIVITY FAIL — dead columns (no constraint references them): {:?}. \
                 A dead committed column means a malicious prover can set it to any value. \
                 Either the column was accidentally disconnected from constraints, or it is \
                 a dummy column that inflates the count without adding security.",
                table.name(), dead_cols,
            );
            ok = false;
        }
    }
    ok
}

// =========================================================================
// 6c. Poseidon Test Vector Consistency Check
// =========================================================================

fn eval_constraints_no_bus(
    flat: &[EF],
    shift: &[EF],
    extra_data: &ExtraDataForBuses<EF>,
) -> Vec<EF> {
    let nobus = Poseidon16Precompile::<false>;
    let mut collector = ConstraintCollector::new(flat.to_vec(), shift.to_vec());
    nobus.eval(&mut collector, extra_data);
    collector.constraints
}

fn check_poseidon_test_vector(rng: &mut u64) -> bool {
    let poseidon_table = Table::poseidon16();
    let poseidon_nobus = Poseidon16Precompile::<false>;

    // Part 1: Witness correctness — verify padding_row matches hardcoded trace.
    // These are LITERAL CONSTANTS from upstream main, NOT computed from agent code.
    // If the agent modifies poseidon16_compress, generate_trace_rows_for_perm, or
    // the AIR consistently, this check still catches it because the expected values
    // are baked into the harness binary.
    #[rustfmt::skip]
    const EXPECTED_PADDING_ROW: [u64; 110] = [
        0, 0, 0, 0, 1, 0, 0, 0, 4, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        329751796, 907732250, 800643066, 712297581, 514816409, 1912460203,
        390638380, 233432021, 1969337324, 1685253904, 1495452671, 965525753,
        2002640193, 1243238351, 1403363499, 33963953, 1524950522, 1034955343,
        1319685268, 296090070, 596378683, 596558044, 900458383, 1793457503,
        2030284584, 1259692786, 787666513, 2015257050, 1734980244, 1130152980,
        396097258, 816239437, 1900433786, 234371302, 1594510631, 1011268564,
        152777316, 2113984778, 1166543627, 1152487559, 270847413, 1650797118,
        914863759, 242187639, 1822841171, 1092738295, 2064458181, 378486933,
        1711301420, 698927466, 1836872083, 1783900066, 821122415, 1635077504,
        1018161813, 1262996547, 308094411, 327473947, 903660170, 404534063,
        1149239803, 812871850, 1179219859, 1509597549, 2084509736, 1254661989,
        1922188128, 1601202173,
        2096630793, 502841916, 2048234017, 615698125, 1716747525, 1717817948, 194562273, 959725011,
        0, 0, 0, 0, 0, 0, 0, 0,
    ];

    let row = poseidon_table.padding_row(0, 0, 0);
    let n_cols = poseidon_nobus.n_columns();

    if n_cols != EXPECTED_PADDING_ROW.len() {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL: n_columns()={} but expected {}. \
             The Poseidon16 column layout was modified.",
            n_cols, EXPECTED_PADDING_ROW.len(),
        );
        return false;
    }

    let mut witness_ok = true;
    let mut mismatches = 0;
    for (i, &expected) in EXPECTED_PADDING_ROW.iter().enumerate() {
        let actual = row[i].as_canonical_u64();
        if actual != expected {
            if mismatches < 5 {
                eprintln!(
                    "[soundness] POSEIDON TEST VECTOR FAIL (witness): col[{}] = {} but expected {}.",
                    i, actual, expected,
                );
            }
            mismatches += 1;
            witness_ok = false;
        }
    }
    if mismatches > 5 {
        eprintln!("[soundness]   ... and {} more mismatches", mismatches - 5);
    }
    if witness_ok {
        eprintln!("[soundness] poseidon16: test vector witness PASS — all {} columns match hardcoded trace", n_cols);
    }

    // Part 2: Constraint satisfaction — the correct witness must satisfy ALL AIR constraints.
    // Use BUS=false evaluator to skip bus constraints (which need cross-row balancing).
    let n_total = poseidon_table.n_columns_total();
    let n_shift = poseidon_nobus.n_shift_columns();
    let n_alpha = poseidon_nobus.n_constraints() + 10;
    let alpha_powers: Vec<EF> = (0..n_alpha).map(|_| random_ef(rng)).collect();
    let logup_alphas: Vec<EF> = (0..64).map(|_| random_ef(rng)).collect();
    let extra_data = ExtraDataForBuses::new(&logup_alphas, alpha_powers);

    let flat_ef: Vec<EF> = row[..n_total].iter().map(|&f| EF::from(f)).collect();
    let shift_ef: Vec<EF> = vec![EF::ZERO; n_shift];
    let constraints = eval_constraints_no_bus(&flat_ef, &shift_ef, &extra_data);

    let nonzero_count = constraints.iter().filter(|&&c| c != EF::ZERO).count();
    let satisfaction_ok = nonzero_count == 0;
    if satisfaction_ok {
        eprintln!("[soundness] poseidon16: constraint satisfaction PASS — all {} constraints zero on correct witness", constraints.len());
    } else {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL (satisfaction): {} of {} constraints are non-zero on the correct witness. \
             The AIR constraints reject a valid Poseidon16 trace.",
            nonzero_count, constraints.len(),
        );
    }

    // Part 1b: Second test vector — non-zero input makes round constant collision infeasible.
    // poseidon16_compress([1, 2, 3, ..., 16]) output, hardcoded from upstream main.
    const EXPECTED_POSEIDON16_IOTA_OUTPUT: [u64; 8] = [
        1640793455, 919785440, 36293255, 714860072, 862104607, 1947344831, 2105735140, 1507849101,
    ];
    let iota_input: [F; 16] = std::array::from_fn(|i| F::from_u64(i as u64 + 1));
    let iota_output = poseidon16_compress(iota_input);
    for (i, &expected) in EXPECTED_POSEIDON16_IOTA_OUTPUT.iter().enumerate() {
        let actual = iota_output[i].as_canonical_u64();
        if actual != expected {
            if mismatches == 0 {
                eprintln!(
                    "[soundness] POSEIDON TEST VECTOR FAIL (iota witness): compress([1..16])[{}] = {} but expected {}.",
                    i, actual, expected,
                );
            }
            mismatches += 1;
            witness_ok = false;
        }
    }
    if witness_ok {
        eprintln!("[soundness] poseidon16: second test vector (iota) PASS");
    }

    // Part 3: Constraint rejection — perturbing each round checkpoint must break at least one constraint.
    // We test every committed column in the round data region (after inputs, before outputs).
    // Poseidon1Cols16 layout: 10 control/flag cols + 16 inputs + round data + 8 out_lo + 8 out_hi
    let input_start = 10;
    let round_data_start = input_start + 16; // = 26
    let out_lo_start = n_cols - 16;
    let round_data_end = out_lo_start; // round data ends where out_lo begins

    let mut unrejected_cols: Vec<usize> = Vec::new();
    for col in round_data_start..round_data_end {
        let mut perturbed = flat_ef.clone();
        perturbed[col] += EF::ONE;
        let c_perturbed = eval_constraints_no_bus(&perturbed, &shift_ef, &extra_data);
        let any_nonzero = constraints.iter().zip(c_perturbed.iter()).any(|(a, b)| *a != *b);
        if !any_nonzero {
            unrejected_cols.push(col);
        }
    }

    let rejection_ok = unrejected_cols.is_empty();
    if rejection_ok {
        eprintln!(
            "[soundness] poseidon16: constraint rejection PASS — all {} round columns are constrained",
            round_data_end - round_data_start,
        );
    } else {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL (rejection): round columns {:?} can be perturbed without \
             breaking any constraint. These round steps are not verified by the AIR — a malicious prover \
             can set them to arbitrary values.",
            unrejected_cols,
        );
    }

    witness_ok && satisfaction_ok && rejection_ok
}


// =========================================================================
// 6d. ExtraDataForBuses Construction Integrity
// =========================================================================

fn verify_extra_data_integrity() -> bool {
    let alphas: Vec<EF> = (0..64).map(|i| EF::from(F::from_u64(0xbead_cafe + i as u64))).collect();
    let alpha_powers: Vec<EF> = (0..20).map(|i| EF::from(F::from_u64(0xdead_0000 + i as u64))).collect();
    let extra = ExtraDataForBuses::new(&alphas, alpha_powers);

    let all_nonzero = extra.logup_alphas_eq_poly.iter().all(|a| *a != EF::ZERO);
    if !all_nonzero {
        eprintln!(
            "[soundness] EXTRA DATA FAIL: ExtraDataForBuses::new() zeroed out logup_alphas_eq_poly. \
             This would make all bus constraints trivially zero, defeating the virtual-column soundness check. \
             The agent may have modified ExtraDataForBuses::new() in table_trait.rs.",
        );
        return false;
    }

    let alpha_ok = extra.alpha_powers.iter().all(|a| *a != EF::ZERO);
    if !alpha_ok {
        eprintln!(
            "[soundness] EXTRA DATA FAIL: ExtraDataForBuses::new() zeroed out alpha_powers.",
        );
        return false;
    }

    eprintln!("[soundness] ExtraDataForBuses integrity PASS");
    true
}

// =========================================================================
// Original check_table (free variable soundness) — unchanged
// =========================================================================

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

    // Phase 1: Static — every uncommitted column must be bus-referenced
    let bus_interactions = table.bus_interactions();
    let mut bus_uncommitted = std::collections::BTreeSet::new();
    for bus in &bus_interactions {
        if let BusMultiplicity::Column(c) = bus.multiplicity {
            if c >= n_pcs { bus_uncommitted.insert(c); }
        }
        if let Some(c) = bus.domainsep.column() {
            if c >= n_pcs { bus_uncommitted.insert(c); }
        }
        for d in &bus.data {
            if let Some(c) = d.column() {
                if c >= n_pcs { bus_uncommitted.insert(c); }
            }
        }
    }
    let n_bus = bus_uncommitted.len();
    let n_unbound = n_uncommitted.saturating_sub(n_bus);

    if n_unbound > 0 {
        let all: std::collections::BTreeSet<usize> = (n_pcs..n_total).collect();
        let missing: Vec<_> = all.difference(&bus_uncommitted).collect();
        eprintln!(
            "[soundness]   STATIC FAIL: {} uncommitted columns not bus-referenced: {:?}",
            n_unbound, missing,
        );
        return false;
    }

    // Phase 2: Numerical — Jacobian rank over uncommitted columns
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
        eprintln!(
            "[soundness]   PASS: constraints do not reference uncommitted columns",
        );
        return true;
    }
    if rank >= n_uncommitted {
        eprintln!(
            "[soundness]   PASS: {} uncommitted columns fully constrained (rank={})",
            n_uncommitted, rank,
        );
        return true;
    }

    let free = n_uncommitted - rank;
    eprintln!(
        "[soundness]   NUMERICAL FAIL: {} uncommitted columns, rank={} → {} free dimensions",
        n_uncommitted, rank, free,
    );
    false
}

// =========================================================================
// Main — run all checks
// =========================================================================

fn main() {
    eprintln!("[soundness] === Structural Baseline (6a) ===");
    let baseline_ok = verify_structural_baseline();

    eprintln!();
    eprintln!("[soundness] === ExtraDataForBuses Integrity (6d) ===");
    let extra_ok = verify_extra_data_integrity();

    eprintln!();
    eprintln!("[soundness] === PCS Consistency ===");
    let pcs_ok = verify_pcs_consistency();

    eprintln!();
    eprintln!("[soundness] === Free Variable Soundness (existing Layer 6) ===");
    let mut rng: u64 = 0xdeadbeef_cafebabe;
    let mut free_var_ok = true;
    for table in &ALL_TABLES {
        if !check_table(table, &mut rng) {
            free_var_ok = false;
        }
    }

    eprintln!();
    eprintln!("[soundness] === Committed-Column Sensitivity (6b) ===");
    let sensitivity_ok = check_committed_column_sensitivity(&mut rng);

    eprintln!();
    eprintln!("[soundness] === Poseidon Test Vector (6c) ===");
    let poseidon_ok = check_poseidon_test_vector(&mut rng);

    eprintln!();
    let all_ok = baseline_ok && extra_ok && pcs_ok && free_var_ok && sensitivity_ok && poseidon_ok;
    if all_ok {
        eprintln!("[soundness] ALL CHECKS PASSED.");
    } else {
        eprintln!("[soundness] FAILED — see above for details.");
        if !baseline_ok { eprintln!("[soundness]   - Structural baseline violated"); }
        if !extra_ok { eprintln!("[soundness]   - ExtraDataForBuses integrity failed"); }
        if !pcs_ok { eprintln!("[soundness]   - PCS consistency failed"); }
        if !free_var_ok { eprintln!("[soundness]   - Free variable soundness failed"); }
        if !sensitivity_ok { eprintln!("[soundness]   - Committed-column sensitivity failed"); }
        if !poseidon_ok { eprintln!("[soundness]   - Poseidon test vector failed"); }
        std::process::exit(1);
    }
}
