//! Benchmark-coupled correctness checker for Plonky3 DFT.
//!
//! Validates that Radix2DitParallel produces bitwise-identical output to the
//! trusted reference (Radix2Dit) for the EXACT benchmark workload.
//!
//! This binary lives OUTSIDE the agent's writable scope (dft/src/, baby-bear/src/)
//! and must NOT be modified by the optimization agent.
//!
//! Usage:
//!   correctness-checker full                    # Full 2^20 × 256 validation
//!   correctness-checker partial                 # Fast spot-check (2^14 × 16)
//!   correctness-checker full partial            # Both
//!   correctness-checker --repeat 3 full         # Run 3x to detect nondeterminism
//!   correctness-checker --added-bits 2 full     # Override added_bits
//!   correctness-checker --shift multiplicative_generator full  # Override shift
//!
//! Exit codes:
//!   0 = all checks passed
//!   1 = correctness mismatch detected
//!   2 = usage error

use p3_baby_bear::BabyBear;
use p3_dft::{Radix2Dit, Radix2DitParallel, TwoAdicSubgroupDft};
use p3_field::{Field, TwoAdicField};
use p3_matrix::dense::RowMajorMatrix;
use p3_matrix::Matrix;
use rand::rngs::StdRng;
use rand::SeedableRng;
use std::env;
use std::time::Instant;

/// Deterministic matrix generation from a fixed seed.
fn generate_deterministic_matrix(seed: u64, rows: usize, cols: usize) -> RowMajorMatrix<BabyBear> {
    let mut rng = StdRng::seed_from_u64(seed);
    let values: Vec<BabyBear> = (0..rows * cols)
        .map(|_| {
            use rand::RngCore;
            let v = rng.next_u32() % (1u32 << 31);
            BabyBear::new(v)
        })
        .collect();
    RowMajorMatrix::new(values, cols)
}

/// Resolve the shift value from a string descriptor.
/// F2: Supports "generator" (BabyBear::GENERATOR) and "two_adic_generator"
/// (BabyBear::two_adic_generator). Fails hard on unknown values.
fn resolve_shift(desc: &str) -> BabyBear {
    match desc {
        "generator" => BabyBear::GENERATOR,
        "multiplicative_generator" => BabyBear::GENERATOR,
        "two_adic_generator" => BabyBear::two_adic_generator(BabyBear::TWO_ADICITY),
        other => {
            // Try parsing as a raw field element
            if let Ok(v) = other.parse::<u32>() {
                BabyBear::new(v)
            } else {
                eprintln!("[checker] ERROR: unknown shift '{other}'. Use 'generator' or a numeric value.");
                std::process::exit(2);
            }
        }
    }
}

#[derive(Debug)]
struct CheckResult {
    mode: String,
    log_h: usize,
    cols: usize,
    added_bits: usize,
    passed: bool,
    mismatch_details: Option<String>,
    reference_time_ms: f64,
    candidate_time_ms: f64,
}

/// Run a correctness check: compare Radix2DitParallel against Radix2Dit.
fn run_check(log_h: usize, cols: usize, added_bits: usize, seed: u64, shift: BabyBear) -> CheckResult {
    let rows = 1usize << log_h;
    let mode = if log_h >= 20 { "full" } else { "partial" };

    eprintln!(
        "[checker] {mode} check: 2^{log_h} × {cols} cols, added_bits={added_bits}, seed={seed:#x}"
    );

    let input_ref = generate_deterministic_matrix(seed, rows, cols);
    let input_candidate = input_ref.clone();

    // Run trusted reference (Radix2Dit — serial, simple, known-correct)
    let t0 = Instant::now();
    let reference_output = Radix2Dit::default().coset_lde_batch(input_ref, added_bits, shift);
    let reference_time = t0.elapsed();

    // Run candidate (Radix2DitParallel — the implementation being optimized)
    let t1 = Instant::now();
    let candidate_output =
        Radix2DitParallel::default().coset_lde_batch(input_candidate, added_bits, shift);
    let candidate_time = t1.elapsed();

    // Bitwise comparison — materialize both outputs into flat RowMajorMatrix
    // coset_lde_batch may return a RowIndexMappedView (bit-reversal permuted),
    // so we call to_row_major_matrix() to get a concrete flat layout for comparison.
    let ref_mat = reference_output.to_row_major_matrix();
    let cand_mat = candidate_output.to_row_major_matrix();
    let ref_values = &ref_mat.values;
    let cand_values = &cand_mat.values;

    let mut passed = true;
    let mut mismatch_details = None;

    if ref_values.len() != cand_values.len() {
        passed = false;
        mismatch_details = Some(format!(
            "Output length mismatch: reference={}, candidate={}",
            ref_values.len(), cand_values.len()
        ));
    } else {
        // F12: Compare ALL elements, report first mismatch AND total count
        let mut first_mismatch_idx = None;
        let mut mismatch_count = 0usize;
        let output_cols = ref_values.len() / (rows * (1 << added_bits));
        let effective_cols = if output_cols > 0 { output_cols } else { cols };

        for (i, (r, c)) in ref_values.iter().zip(cand_values.iter()).enumerate() {
            if r != c {
                mismatch_count += 1;
                if first_mismatch_idx.is_none() {
                    first_mismatch_idx = Some(i);
                }
            }
        }

        if mismatch_count > 0 {
            passed = false;
            let i = first_mismatch_idx.unwrap();
            let row = i / effective_cols;
            let col = i % effective_cols;
            mismatch_details = Some(format!(
                "First mismatch at element {i} (row={row}, col={col}): \
                 reference={:?}, candidate={:?}. Total mismatches: {mismatch_count}/{}",
                ref_values[i], cand_values[i], ref_values.len()
            ));
        }
    }

    let result = CheckResult {
        mode: mode.to_string(),
        log_h, cols, added_bits, passed, mismatch_details,
        reference_time_ms: reference_time.as_secs_f64() * 1000.0,
        candidate_time_ms: candidate_time.as_secs_f64() * 1000.0,
    };

    if result.passed {
        eprintln!("[checker] {mode} PASSED — ref={:.1}ms, candidate={:.1}ms",
            result.reference_time_ms, result.candidate_time_ms);
    } else {
        eprintln!("[checker] {mode} FAILED — {}",
            result.mismatch_details.as_deref().unwrap_or("unknown"));
    }

    result
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        eprintln!("Usage: correctness-checker [OPTIONS] <full|partial> [full|partial]...");
        eprintln!("  full    — 2^20 × 256 cols (exact benchmark workload)");
        eprintln!("  partial — 2^14 × 16 cols (fast spot-check)");
        eprintln!("Options:");
        eprintln!("  --added-bits N    Override added_bits (default: 1)");
        eprintln!("  --shift DESC      Override shift: 'generator' or numeric (default: generator)");
        eprintln!("  --repeat N        Run each check N times to detect nondeterminism (default: 1)");
        std::process::exit(2);
    }

    // F1+F2: Parse CLI arguments — parameters come from loop.py which extracts
    // them from the benchmark source, not hardcoded.
    let mut added_bits: usize = 1;
    let mut shift_desc = "generator".to_string();
    let mut repeat: usize = 1;
    let mut modes: Vec<String> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--added-bits" => {
                i += 1;
                added_bits = args.get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| { eprintln!("--added-bits requires a number"); std::process::exit(2); });
            }
            "--shift" => {
                i += 1;
                shift_desc = args.get(i)
                    .cloned()
                    .unwrap_or_else(|| { eprintln!("--shift requires a value"); std::process::exit(2); });
            }
            "--repeat" => {
                i += 1;
                repeat = args.get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| { eprintln!("--repeat requires a number"); std::process::exit(2); });
            }
            "full" | "partial" => {
                modes.push(args[i].clone());
            }
            other => {
                eprintln!("Unknown argument: '{other}'");
                std::process::exit(2);
            }
        }
        i += 1;
    }

    if modes.is_empty() {
        eprintln!("No check modes specified. Use 'full' and/or 'partial'.");
        std::process::exit(2);
    }

    let shift = resolve_shift(&shift_desc);
    let seed = 0xDEAD_BEEF_CAFE_BABEu64;

    eprintln!("[checker] Config: added_bits={added_bits}, shift={shift_desc}, repeat={repeat}");

    let mut all_passed = true;
    let mut all_results: Vec<CheckResult> = Vec::new();

    for run_idx in 0..repeat {
        if repeat > 1 {
            eprintln!("[checker] === Run {}/{repeat} ===", run_idx + 1);
        }

        for mode in &modes {
            let result = match mode.as_str() {
                "full" => run_check(20, 256, added_bits, seed, shift),
                "partial" => run_check(14, 16, added_bits, seed, shift),
                _ => unreachable!(),
            };

            if !result.passed {
                all_passed = false;
            }
            all_results.push(result);
        }
    }

    // F12: If repeat > 1, verify that all runs of the same mode agree.
    // This detects nondeterminism (data races, uninitialized memory, etc.)
    if repeat > 1 {
        for mode in &modes {
            let runs_for_mode: Vec<&CheckResult> = all_results.iter()
                .filter(|r| r.mode == mode.as_str() || (mode == "full" && r.log_h >= 20) || (mode == "partial" && r.log_h < 20))
                .collect();

            // All runs must agree on pass/fail
            let all_same = runs_for_mode.windows(2).all(|w| w[0].passed == w[1].passed);
            if !all_same {
                all_passed = false;
                eprintln!(
                    "[checker] NONDETERMINISM DETECTED in {mode} mode: \
                     runs disagree on pass/fail across {repeat} repetitions. \
                     This indicates a data race or uninitialized memory."
                );
            }
        }
    }

    // Output structured JSON
    let json_results: Vec<serde_json::Value> = all_results.iter()
        .map(|r| serde_json::json!({
            "mode": r.mode,
            "log_h": r.log_h,
            "cols": r.cols,
            "added_bits": r.added_bits,
            "passed": r.passed,
            "mismatch_details": r.mismatch_details,
            "reference_time_ms": r.reference_time_ms,
            "candidate_time_ms": r.candidate_time_ms,
        }))
        .collect();

    let output = serde_json::json!({
        "all_passed": all_passed,
        "checks": json_results,
        "config": {
            "added_bits": added_bits,
            "shift": shift_desc,
            "repeat": repeat,
            "seed": format!("{seed:#x}"),
        }
    });

    println!("{}", serde_json::to_string(&output).unwrap());

    if all_passed {
        std::process::exit(0);
    } else {
        std::process::exit(1);
    }
}
