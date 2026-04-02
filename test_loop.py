#!/usr/bin/env python3
"""Unit tests for loop.py logic — no server or Cargo required."""

import sys
import json
import os
import tempfile
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# Mock anthropic so loop.py imports without the SDK installed
anthropic_mock = types.ModuleType("anthropic")
anthropic_mock.Anthropic = object
sys.modules["anthropic"] = anthropic_mock


class TestReadFile(unittest.TestCase):

    def setUp(self):
        # Create a temp repo dir with a readable test file
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)

        # Patch loop module constants
        import loop
        self._orig_repo = loop.REPO_DIR
        self._orig_readable = loop.READABLE
        loop.REPO_DIR = self.repo
        loop.READABLE = ["dft/src/"]

        # Create test file
        src = self.repo / "dft" / "src"
        src.mkdir(parents=True)
        (src / "test.rs").write_text("\n".join(f"line {i}" for i in range(1, 21)))

    def tearDown(self):
        import loop
        loop.REPO_DIR = self._orig_repo
        loop.READABLE = self._orig_readable
        self.tmp.cleanup()

    def test_full_read(self):
        import loop
        result = loop.tool_read_file("dft/src/test.rs")
        self.assertIn("(20 lines)", result)
        self.assertIn("line 1", result)
        self.assertIn("line 20", result)

    def test_line_range(self):
        import loop
        result = loop.tool_read_file("dft/src/test.rs", start_line=3, end_line=5)
        self.assertIn("lines 3-5 of 20", result)
        self.assertIn("line 3", result)
        self.assertIn("line 5", result)
        self.assertNotIn("line 1", result)
        self.assertNotIn("line 6", result)

    def test_start_only(self):
        import loop
        result = loop.tool_read_file("dft/src/test.rs", start_line=18)
        self.assertIn("lines 18-20 of 20", result)
        self.assertIn("line 20", result)
        self.assertNotIn("line 17", result)

    def test_not_found(self):
        import loop
        result = loop.tool_read_file("dft/src/missing.rs")
        self.assertTrue(result.startswith("ERROR:"))

    def test_not_readable(self):
        import loop
        result = loop.tool_read_file("fri/src/secret.rs")
        self.assertTrue(result.startswith("ERROR:"))

    def test_path_traversal_blocked(self):
        import loop
        result = loop.tool_read_file("dft/src/../../outside.rs")
        self.assertTrue(result.startswith("ERROR:"))


class TestExecuteToolCrashFix(unittest.TestCase):
    """Verify missing args return errors instead of raising KeyError."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        import loop
        self._orig_repo = loop.REPO_DIR
        self._orig_readable = loop.READABLE
        self._orig_writable = loop.WRITABLE
        loop.REPO_DIR = Path(self.tmp.name)
        loop.READABLE = ["dft/src/"]
        loop.WRITABLE = ["dft/src/"]

    def tearDown(self):
        import loop
        loop.REPO_DIR = self._orig_repo
        loop.READABLE = self._orig_readable
        loop.WRITABLE = self._orig_writable
        self.tmp.cleanup()

    def test_read_file_missing_path(self):
        import loop
        result = loop.execute_tool("read_file", {})
        self.assertTrue(result.startswith("ERROR:"))

    def test_write_file_missing_path(self):
        import loop
        result = loop.execute_tool("write_file", {"content": "hello"})
        self.assertTrue(result.startswith("ERROR:"))

    def test_write_file_missing_content(self):
        import loop
        result = loop.execute_tool("write_file", {"path": "dft/src/foo.rs"})
        self.assertTrue(result.startswith("ERROR:"))

    def test_list_dir_missing_path(self):
        import loop
        result = loop.execute_tool("list_dir", {})
        self.assertTrue(result.startswith("ERROR:"))

    def test_unknown_tool(self):
        import loop
        result = loop.execute_tool("explode", {})
        self.assertTrue(result.startswith("ERROR:"))


class TestFormatHistory(unittest.TestCase):

    def _make_exp(self, iteration, kept, reason, pct, idea):
        return {
            "iteration": iteration,
            "kept": kept,
            "reason": reason,
            "score_ns": 2_700_000_000 if reason != "tests_failed" else None,
            "improvement_pct": pct,
            "agent_idea": idea,
        }

    def test_empty(self):
        import loop
        result = loop.format_history([])
        self.assertIn("starting fresh", result)

    def test_kept_always_shown(self):
        import loop
        exps = [self._make_exp(i, False, "regression", -1.0, f"idea {i}") for i in range(1, 20)]
        exps.insert(0, self._make_exp(1, True, "improvement", 1.5, "the winning idea"))
        result = loop.format_history(exps)
        self.assertIn("ALL KEPT IMPROVEMENTS", result)
        self.assertIn("the winning idea", result)

    def test_deduplication(self):
        import loop
        # Same idea attempted 10 times (more than HISTORY_WINDOW)
        exps = [self._make_exp(i, False, "regression", -1.0, "remove backwards flag") for i in range(1, 11)]
        result = loop.format_history(exps)
        # PREVIOUSLY TRIED section should list the idea exactly once (deduplicated)
        import re
        m = re.search(r'PREVIOUSLY TRIED.*?\n(.*?)(?:===|$)', result, re.DOTALL)
        tried_content = m.group(1) if m else ""
        count_in_tried = tried_content.count("remove backwards flag")
        self.assertEqual(count_in_tried, 1)

    def test_tests_failed_shown(self):
        import loop
        exps = [self._make_exp(23, False, "tests_failed", 0.0, "half_block_size special case")]
        result = loop.format_history(exps)
        self.assertIn("COMPILE", result)
        self.assertIn("half_block_size", result)

    def test_near_misses_shown(self):
        import loop
        exps = [self._make_exp(10, False, "regression", -0.3, "almost worked")]
        result = loop.format_history(exps)
        self.assertIn("NEAR-MISSES", result)
        self.assertIn("almost worked", result)

    def test_recent_window_non_kept_only(self):
        import loop
        exps = [self._make_exp(i, False, "regression", -1.0, f"idea {i}") for i in range(1, 10)]
        exps.append(self._make_exp(10, True, "improvement", 1.0, "kept idea"))
        result = loop.format_history(exps)
        # Kept idea should be in ALL KEPT, not duplicated in RECENT
        self.assertEqual(result.count("kept idea"), 1)



class TestReadExperimentDiff(unittest.TestCase):
    """Verify read_experiment_diff tool reads from experiments log correctly."""

    def setUp(self):
        import loop
        self.tmp = tempfile.TemporaryDirectory()
        self._orig_log = loop.LOG_FILE
        loop.LOG_FILE = Path(self.tmp.name) / "experiments.jsonl"

    def tearDown(self):
        import loop
        loop.LOG_FILE = self._orig_log
        self.tmp.cleanup()

    def test_found(self):
        import json, loop
        loop.LOG_FILE.write_text(
            json.dumps({"iteration": 5, "kept": False, "improvement_pct": -0.97,
                        "agent_idea": "forward twiddle slice", "diff": "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new"})
            + "\n"
        )
        result = loop.tool_read_experiment_diff(5)
        self.assertIn("REVERTED", result)
        self.assertIn("forward twiddle slice", result)
        self.assertIn("--- a", result)

    def test_not_found(self):
        import loop
        loop.LOG_FILE.write_text("")
        result = loop.tool_read_experiment_diff(99)
        self.assertTrue(result.startswith("ERROR:"))

    def test_no_log_file(self):
        import loop
        # LOG_FILE does not exist
        result = loop.tool_read_experiment_diff(1)
        self.assertTrue(result.startswith("ERROR:"))

    def test_no_diff_recorded(self):
        import json, loop
        loop.LOG_FILE.write_text(
            json.dumps({"iteration": 3, "kept": True, "improvement_pct": 0.45,
                        "agent_idea": "pre-broadcast", "diff": ""})
            + "\n"
        )
        result = loop.tool_read_experiment_diff(3)
        self.assertIn("KEPT", result)
        self.assertIn("no diff recorded", result)

    def test_execute_tool_dispatch(self):
        import json, loop
        loop.LOG_FILE.write_text(
            json.dumps({"iteration": 2, "kept": True, "improvement_pct": 0.38,
                        "agent_idea": "some idea", "diff": "+foo"})
            + "\n"
        )
        result = loop.execute_tool("read_experiment_diff", {"iteration": 2})
        self.assertIn("KEPT", result)


class TestInspectDiff(unittest.TestCase):
    """Verify static diff inspection for forbidden patterns and unsafe counting."""

    def test_clean_diff_passes(self):
        import loop
        diff = (
            "--- a/dft/src/butterflies.rs\n"
            "+++ b/dft/src/butterflies.rs\n"
            "@@ -1,3 +1,3 @@\n"
            "+    let packed = F::Packing::from(twiddle);\n"
        )
        result = loop.inspect_diff(diff)
        self.assertEqual(result["forbidden"], [])
        self.assertEqual(result["unsafe_count"], 0)

    def test_cfg_test_is_forbidden(self):
        import loop
        diff = "+    #[cfg(test)]\n+    fn slow_path() {}\n"
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0)

    def test_cfg_not_test_is_forbidden(self):
        import loop
        diff = "+    #[cfg(not(test))]\n+    fn fast_but_wrong() {}\n"
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0)

    def test_debug_assert_is_forbidden(self):
        import loop
        diff = "+    debug_assert!(x < P);\n"
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0)

    def test_unsafe_is_counted_not_forbidden(self):
        import loop
        diff = "+    unsafe { ptr::write(dst, val) }\n"
        result = loop.inspect_diff(diff)
        self.assertEqual(result["forbidden"], [])
        self.assertEqual(result["unsafe_count"], 1)

    def test_multiple_unsafe_lines_counted(self):
        import loop
        diff = (
            "+    unsafe { *a = x }\n"
            "+    unsafe { *b = y }\n"
        )
        result = loop.inspect_diff(diff)
        self.assertEqual(result["unsafe_count"], 2)

    def test_removed_lines_not_inspected(self):
        import loop
        # A removed cfg(test) line should not trigger forbidden
        diff = "-    #[cfg(test)]\n-    fn old_path() {}\n"
        result = loop.inspect_diff(diff)
        self.assertEqual(result["forbidden"], [])
        self.assertEqual(result["unsafe_count"], 0)

    def test_diff_header_lines_not_inspected(self):
        import loop
        # +++ header lines should not be mistaken for added code
        diff = "+++ b/dft/src/butterflies.rs\n"
        result = loop.inspect_diff(diff)
        self.assertEqual(result["forbidden"], [])
        self.assertEqual(result["unsafe_count"], 0)



class TestAuditTestCoverage(unittest.TestCase):
    """Verify audit_test_coverage() detects missing crates from CLAUDE.md targets."""

    def _run_audit(self, primary_line, tested_crates):
        import loop
        import unittest.mock as mock
        claude_md = f"## Optimization Target\n\n{primary_line}\n"
        fake_path = mock.MagicMock()
        fake_path.read_text.return_value = claude_md
        with mock.patch.object(loop, "CLAUDE_MD", fake_path), \
             mock.patch.object(loop, "TESTED_CRATES", tested_crates):
            return loop.audit_test_coverage()

    def test_no_gaps_when_all_crates_tested(self):
        gaps = self._run_audit(
            "Primary: dft/src/radix_2_dit_parallel.rs, baby-bear/src/x86_64_avx512/",
            {"p3-dft", "p3-baby-bear", "p3-examples"},
        )
        self.assertEqual(gaps, [])

    def test_detects_missing_baby_bear(self):
        gaps = self._run_audit(
            "Primary: dft/src/radix_2_dit_parallel.rs, baby-bear/src/x86_64_avx512/",
            {"p3-dft", "p3-examples"},
        )
        self.assertEqual(len(gaps), 1)
        self.assertIn("baby-bear/src/", gaps[0][0])
        self.assertIn("p3-baby-bear", gaps[0][1])

    def test_detects_missing_dft(self):
        gaps = self._run_audit(
            "Primary: dft/src/radix_2_dit_parallel.rs",
            {"p3-baby-bear", "p3-examples"},
        )
        self.assertEqual(len(gaps), 1)
        self.assertIn("p3-dft", gaps[0][1])

    def test_target_not_in_primary_line_ignored(self):
        # baby-bear not in Primary line — no gap even if untested
        gaps = self._run_audit(
            "Primary: dft/src/radix_2_dit_parallel.rs",
            {"p3-dft", "p3-examples"},
        )
        self.assertEqual(gaps, [])

    def test_empty_primary_line_no_gaps(self):
        gaps = self._run_audit("", {"p3-dft", "p3-examples"})
        self.assertEqual(gaps, [])


class TestCorrectnessCheckIntegration(unittest.TestCase):
    """Verify run_correctness_check() handles various checker outputs correctly."""

    def setUp(self):
        import loop
        self.tmp = tempfile.TemporaryDirectory()
        self._orig_checker_dir = loop.CHECKER_DIR
        loop.CHECKER_DIR = Path(self.tmp.name)

    def tearDown(self):
        import loop
        loop.CHECKER_DIR = self._orig_checker_dir
        self.tmp.cleanup()

    def test_empty_modes_returns_passed(self):
        import loop
        result = loop.run_correctness_check([])
        self.assertTrue(result["passed"])
        self.assertEqual(result["checks"], [])

    def test_build_failure_returns_not_passed(self):
        import loop
        import unittest.mock as mock
        with mock.patch.object(loop, "build_correctness_checker", return_value=(False, "compile error")):
            result = loop.run_correctness_check(["partial"])
            self.assertFalse(result["passed"])
            self.assertFalse(result["build_ok"])

    def test_checker_json_parsing(self):
        import loop
        import unittest.mock as mock
        checker_json = json.dumps({
            "all_passed": True,
            "checks": [
                {"mode": "partial", "log_h": 14, "cols": 16, "added_bits": 1,
                 "passed": True, "mismatch_details": None,
                 "reference_time_ms": 100.0, "candidate_time_ms": 50.0}
            ]
        })
        with mock.patch.object(loop, "build_correctness_checker", return_value=(True, "")), \
             mock.patch.object(loop, "run_cmd", return_value=(0, checker_json)):
            result = loop.run_correctness_check(["partial"])
            self.assertTrue(result["passed"])
            self.assertEqual(len(result["checks"]), 1)
            self.assertTrue(result["checks"][0]["passed"])

    def test_checker_failure_detected(self):
        import loop
        import unittest.mock as mock
        checker_json = json.dumps({
            "all_passed": False,
            "checks": [
                {"mode": "full", "log_h": 20, "cols": 256, "added_bits": 1,
                 "passed": False,
                 "mismatch_details": "First mismatch at element 42",
                 "reference_time_ms": 5000.0, "candidate_time_ms": 3000.0}
            ]
        })
        with mock.patch.object(loop, "build_correctness_checker", return_value=(True, "")), \
             mock.patch.object(loop, "run_cmd", return_value=(1, checker_json)):
            result = loop.run_correctness_check(["full"])
            self.assertFalse(result["passed"])
            self.assertIn("mismatch", result["checks"][0]["mismatch_details"])

    def test_F9_exit_code_overrides_json(self):
        """F9: Non-zero exit code must override JSON all_passed=true."""
        import loop
        import unittest.mock as mock
        # Checker prints all_passed=true but crashes (exit code 139 = SIGSEGV)
        checker_json = json.dumps({
            "all_passed": True,
            "checks": [
                {"mode": "partial", "log_h": 14, "cols": 16, "added_bits": 1,
                 "passed": True, "mismatch_details": None,
                 "reference_time_ms": 100.0, "candidate_time_ms": 50.0}
            ]
        })
        with mock.patch.object(loop, "build_correctness_checker", return_value=(True, "")), \
             mock.patch.object(loop, "run_cmd", return_value=(139, checker_json)):
            result = loop.run_correctness_check(["partial"])
            # MUST be False despite JSON saying True
            self.assertFalse(result["passed"],
                "F9 violation: exit code 139 should override JSON all_passed=true")

    def test_bench_params_passed_to_checker(self):
        """F1+F2: Verify bench_params are forwarded to the checker CLI."""
        import loop
        import unittest.mock as mock
        checker_json = json.dumps({"all_passed": True, "checks": []})
        calls = []
        def mock_run_cmd(cmd, **kwargs):
            calls.append(cmd)
            return (0, checker_json)
        with mock.patch.object(loop, "build_correctness_checker", return_value=(True, "")), \
             mock.patch.object(loop, "run_cmd", side_effect=mock_run_cmd):
            params = {"added_bits": 2, "shift": "two_adic_generator"}
            loop.run_correctness_check(["full"], bench_params=params)
            # Find the checker invocation (not the build)
            self.assertTrue(len(calls) > 0)
            cmd = calls[0]
            self.assertIn("--added-bits", cmd)
            self.assertIn("2", cmd)
            self.assertIn("--shift", cmd)
            self.assertIn("two_adic_generator", cmd)
            self.assertIn("--repeat", cmd)


class TestCorrectnessConfig(unittest.TestCase):
    """Verify correctness configuration constants are sane."""

    def test_partial_runs_every_iteration(self):
        import loop
        self.assertEqual(loop.CORRECTNESS_PARTIAL_EVERY, 1)

    def test_full_runs_periodically(self):
        import loop
        self.assertGreaterEqual(loop.CORRECTNESS_FULL_EVERY, 1)

    def test_F7_no_configurable_full_on_keep(self):
        """F7: Full validation before keep must be an invariant, not a flag."""
        import loop
        # CORRECTNESS_FULL_ON_KEEP should no longer exist as a configurable flag
        self.assertFalse(hasattr(loop, "CORRECTNESS_FULL_ON_KEEP"),
            "F7 violation: CORRECTNESS_FULL_ON_KEEP should not exist as a configurable flag")

    def test_repeat_runs_for_nondeterminism(self):
        """F12: Checker must run multiple times to detect nondeterminism."""
        import loop
        self.assertGreaterEqual(loop.CORRECTNESS_REPEAT_RUNS, 2)

    def test_checker_dir_outside_writable(self):
        """The checker must not be in the agent's writable scope."""
        import loop
        checker_rel = str(loop.CHECKER_DIR.relative_to(loop.ROOT_DIR))
        for prefix in loop.WRITABLE:
            self.assertFalse(
                checker_rel.startswith(prefix),
                f"Checker dir {checker_rel} is inside writable prefix {prefix}"
            )


class TestForbiddenDiffPatterns(unittest.TestCase):
    """F4+F13: Verify expanded forbidden diff patterns."""

    def test_cfg_not_debug_assertions_forbidden(self):
        """F13: cfg(not(debug_assertions)) must be blocked."""
        import loop
        diff = "+    #[cfg(not(debug_assertions))]\n+    fn release_only() {}\n"
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0,
            "F13: cfg(not(debug_assertions)) should be forbidden")

    def test_cfg_debug_assertions_forbidden(self):
        """F13: cfg(debug_assertions) must be blocked."""
        import loop
        diff = "+    #[cfg(debug_assertions)]\n+    fn debug_only() {}\n"
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0)

    def test_cfg_feature_forbidden(self):
        """F4: cfg(feature = ...) must be blocked."""
        import loop
        diff = '+    #[cfg(feature = "fast_path")]\n+    fn fast() {}\n'
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0,
            "F4: cfg(feature) should be forbidden")

    def test_cfg_not_feature_forbidden(self):
        """F4: cfg(not(feature = ...)) must be blocked."""
        import loop
        diff = '+    #[cfg(not(feature = "checker"))]\n+    fn skip_checker() {}\n'
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0,
            "F4: cfg(not(feature)) should be forbidden")

    def test_cfg_macro_feature_forbidden(self):
        """F4: cfg!(feature = ...) macro must be blocked."""
        import loop
        diff = '+    if cfg!(feature = "fast") { return; }\n'
        result = loop.inspect_diff(diff)
        self.assertTrue(len(result["forbidden"]) > 0,
            "F4: cfg! macro with feature should be forbidden")


class TestBenchParamsExtraction(unittest.TestCase):
    """F1+F2: Verify benchmark parameter extraction from source."""

    def setUp(self):
        import loop
        self.tmp = tempfile.TemporaryDirectory()
        self._orig_repo = loop.REPO_DIR
        loop.REPO_DIR = Path(self.tmp.name)

    def tearDown(self):
        import loop
        loop.REPO_DIR = self._orig_repo
        self.tmp.cleanup()

    def test_parses_added_bits_from_coset_lde_batch(self):
        import loop
        bench_dir = Path(self.tmp.name) / "dft" / "benches"
        bench_dir.mkdir(parents=True)
        (bench_dir / "fft.rs").write_text(
            'dft.coset_lde_batch(mat.clone(), 1, F::generator());\n'
        )
        result = loop.extract_bench_params()
        self.assertEqual(result["added_bits"], 1)
        self.assertEqual(result["shift"], "generator")

    def test_parses_added_bits_2(self):
        import loop
        bench_dir = Path(self.tmp.name) / "dft" / "benches"
        bench_dir.mkdir(parents=True)
        (bench_dir / "fft.rs").write_text(
            'dft.coset_lde_batch(mat.clone(), 2, F::GENERATOR);\n'
        )
        result = loop.extract_bench_params()
        self.assertEqual(result["added_bits"], 2)

    def test_defaults_when_file_missing(self):
        import loop
        result = loop.extract_bench_params()
        self.assertEqual(result["added_bits"], 1)
        self.assertEqual(result["shift"], "generator")
        self.assertIn("default", result["source"])

    def test_defaults_when_unparseable(self):
        import loop
        bench_dir = Path(self.tmp.name) / "dft" / "benches"
        bench_dir.mkdir(parents=True)
        (bench_dir / "fft.rs").write_text('// no coset_lde_batch call here\n')
        result = loop.extract_bench_params()
        self.assertEqual(result["added_bits"], 1)  # falls back to default


class TestBuildEnvSnapshot(unittest.TestCase):
    """F11: Verify build environment snapshot captures relevant variables."""

    def test_snapshot_contains_key_vars(self):
        import loop
        snap = loop._snapshot_build_env()
        for key in ["RUSTFLAGS", "CARGO_INCREMENTAL", "RAYON_NUM_THREADS"]:
            self.assertIn(key, snap, f"Missing {key} in build env snapshot")


if __name__ == "__main__":
    unittest.main(verbosity=2)
