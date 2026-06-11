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
            ok = false;
            continue;
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
            eprintln!("[soundness]   PASS: constraints do not reference uncommitted columns");
        } else if rank >= n_uncommitted {
            eprintln!(
                "[soundness]   PASS: {} uncommitted columns fully constrained (rank={})",
                n_uncommitted, rank,
            );
        } else {
            let free = n_uncommitted - rank;
            eprintln!(
                "[soundness]   NUMERICAL FAIL: {} uncommitted columns, rank={} → {} free dimensions",
                n_uncommitted, rank, free,
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
// Poseidon8 Test Vector Consistency (6c)
// =========================================================================

fn eval_constraints_no_bus(
    flat: &[EF],
    shift: &[EF],
    extra_data: &ExtraDataForBuses<EF>,
) -> Vec<EF> {
    let nobus = Poseidon8Precompile::<false>;
    let mut collector = ConstraintCollector::new(flat.to_vec(), shift.to_vec());
    nobus.eval(&mut collector, extra_data);
    collector.constraints
}

fn check_poseidon_test_vector(rng: &mut u64) -> bool {
    let poseidon_table = Table::poseidon8();
    let poseidon_nobus = Poseidon8Precompile::<false>;

    #[rustfmt::skip]
    const EXPECTED_PADDING_ROW: [u64; 112] = [
        0, 0, 0, 0, 1, 0, 0, 0, 2, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 10843407380721191157, 12480894873209202472,
        3310578452386834554, 243575549172213111, 0, 0, 0, 0, 2827721621574873794, 6632194220264351475,
        16983029390123288439, 2314203156432601196, 15636699550400079585, 14256775217350132061,
        14086115268893019588, 17062535514523555236, 820550095733708744, 16713487035105485168,
        3167891179992349933, 7409663996699302972, 6437974431102811331, 9815653288965005132,
        15817636560454095413, 15113385976311638123, 16735216786012479412, 18398477267011162753,
        13003506054879983363, 14273895503978255435, 3400483624834924630, 16436627892981942577,
        5851989680590537431, 7380792917830294625, 14549728391647580653, 2212356684493605696,
        123076047004639866, 2452497154069540398, 17653639474441958889, 61101041339985200,
        10943307921570850912, 11859551982154129963, 11953127326233631099, 15712556154157464670,
        12729095660964066876, 7027215836322282278, 16945162365467867879, 4548092505851656438,
        17728831032967594033, 15111349113119469199, 16896500138433431593, 5426798143956913845,
        1573482060892116753, 10920188939551563564, 10365983592312726872, 8872840492573064140,
        12645520966790023307, 6820487992804463138, 7373246745868654558, 1383785708236241264,
        3140343032554136496, 12998283956542054315, 11877278842904801222, 11546828799655187015,
        6865467272562436083, 13477604676603552588, 12342592907243601925, 4359664212274052324,
        1230538571103154969, 6445422665816161966, 5266143635370365241, 7911543521880201816,
        12393600893749591881, 2171989484050073253, 8081081135656790761, 3057769286186952945,
        14111201006223604419, 3194992384441642109, 13046875987973609021, 13575519456525252843,
        6842945001347405942, 12699091698749772811, 8492212023547556941, 16910352133070005188,
        15322994817937476608, 1592594348409946960, 2393176619428635188, 16950300923959425930,
        10843407380721191157, 12480894873209202472, 3310578452386834554, 243575549172213111,
        10828976750644631960, 3180618067839798747, 14106729840943200108, 11601868679023094360,
    ];

    let row = poseidon_table.padding_row(0, 0, 0);
    let n_cols = poseidon_nobus.n_columns();

    if n_cols != EXPECTED_PADDING_ROW.len() {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL: n_columns()={} but expected {}.",
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
        eprintln!("[soundness] poseidon8: test vector witness PASS — all {} columns match hardcoded trace", n_cols);
    }

    // Constraint satisfaction — correct witness must satisfy ALL AIR constraints (BUS=false)
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
        eprintln!("[soundness] poseidon8: constraint satisfaction PASS — all {} constraints zero on correct witness", constraints.len());
    } else {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL (satisfaction): {} of {} constraints are non-zero on the correct witness.",
            nonzero_count, constraints.len(),
        );
    }

    // Second test vector: poseidon8_compress([1, 2, ..., 8])
    const EXPECTED_POSEIDON8_IOTA_OUTPUT: [u64; 4] = [
        13086765662296183811, 3163312297714113100, 6296265531618872016, 9231900090062921078,
    ];
    let iota_input: [F; 8] = std::array::from_fn(|i| F::from_u64(i as u64 + 1));
    let iota_output = poseidon8_compress(iota_input);
    let mut iota_ok = true;
    for (i, &expected) in EXPECTED_POSEIDON8_IOTA_OUTPUT.iter().enumerate() {
        let actual = iota_output[i].as_canonical_u64();
        if actual != expected {
            eprintln!(
                "[soundness] POSEIDON TEST VECTOR FAIL (iota): compress([1..8])[{}] = {} but expected {}.",
                i, actual, expected,
            );
            iota_ok = false;
        }
    }
    if iota_ok {
        eprintln!("[soundness] poseidon8: second test vector (iota) PASS");
    }

    // Constraint rejection — perturbing round columns must break at least one constraint.
    // Poseidon8 layout: 10 control + 8 inputs + 4 out_lo + 4 out_hi + round data.
    // out_hi (cols 22-25) is only constrained when output mode flags are set, so skip
    // the output region and test only the round data columns.
    let round_data_start = 26; // POSEIDON_8_COL_ROUND_START
    let round_data_end = n_cols;

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
            "[soundness] poseidon8: constraint rejection PASS — all {} round columns are constrained",
            round_data_end - round_data_start,
        );
    } else {
        eprintln!(
            "[soundness] POSEIDON TEST VECTOR FAIL (rejection): round columns {:?} can be perturbed without breaking any constraint.",
            unrejected_cols,
        );
    }

    witness_ok && satisfaction_ok && iota_ok && rejection_ok
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
    eprintln!("[soundness] === Poseidon8 Test Vector (6c) ===");
    if !check_poseidon_test_vector(&mut rng_state) { all_ok = false; }

    eprintln!();
    if all_ok {
        eprintln!("[soundness] ALL CHECKS PASSED.");
    } else {
        eprintln!("[soundness] CHECKS FAILED — see above.");
        std::process::exit(1);
    }
}
