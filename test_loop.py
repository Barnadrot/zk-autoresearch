#!/usr/bin/env python3
"""Unit tests for loop.py logic — no server or Cargo required."""

import sys
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
        exps = [self._make_exp(10, False, "regression", -0.8, "almost worked")]
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



if __name__ == "__main__":
    unittest.main(verbosity=2)
