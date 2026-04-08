#!/usr/bin/env python3
"""
ZK Autoresearch Loop — Plonky3 DFT optimizer.
Inspired by Karpathy's autoresearch pattern.

Each iteration:
  1. Build a prompt with current score + last N experiment results
  2. Call Claude (fresh context every time — no history bleed)
  3. Agent reads source files and writes ONE targeted change
  4. Run tests (fast correctness check)
  5. Run benchmark
  6. Keep if improvement, revert if regression
  7. Log everything to experiments.jsonl

Usage:
  export ANTHROPIC_API_KEY=sk-...
  python3 loop.py
  python3 loop.py --max-iter 50
  python3 loop.py --start-fresh        # wipe log + reset git
  touch STOP                           # graceful shutdown after current iter
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import anthropic

# ── Config ────────────────────────────────────────────────────────────────────

ROOT_DIR    = Path(__file__).parent
REPO_DIR    = ROOT_DIR / "Plonky3"
LOG_FILE    = ROOT_DIR / "experiments.jsonl"
STOP_FILE   = ROOT_DIR / "STOP"
CLAUDE_MD        = ROOT_DIR / "experiment_logs" / "Plonky3" / "NTT" / "active" / "CLAUDE.md"
ELIMINATED_FILE  = ROOT_DIR / "experiment_logs" / "Plonky3" / "NTT" / "active" / "eliminated_ideas.md"
CHECKER_DIR = ROOT_DIR / "correctness-checker"
EXP_LOGS    = ROOT_DIR / "experiment_logs" / "Plonky3" / "NTT"

MODEL              = "claude-sonnet-4-6"
MAX_TOKENS         = 20000   # max output tokens per API call — caps individual response length
ITER_TIMEOUT_SECS  = 420     # 7 min wall-clock limit per iteration — kill and revert if exceeded
MAX_ITERATIONS     = 100
MIN_IMPROVEMENT_PCT = 0.20  # improvements below this are treated as noise
P_VALUE_THRESHOLD   = 0.05  # improvements with p > this are treated as noise (95% confidence required)

# Correctness checker configuration
# "partial" = fast spot-check (2^14 × 16, ~1s) — every iteration
# "full"    = exact benchmark workload (2^20 × 256, ~30-60s) — every N iterations
CORRECTNESS_PARTIAL_EVERY = 1   # run partial check every iteration
CORRECTNESS_FULL_EVERY    = 5   # run full check every N iterations
# INVARIANT: full correctness check is ALWAYS required before accepting any
# "kept" change. This is non-negotiable and not configurable.
# See: Issue #4 — "Performance improvement without validated correctness is invalid."

# Number of times to run the checker per invocation to detect nondeterminism.
# If any run disagrees with any other, the check fails.
CORRECTNESS_REPEAT_RUNS = 2

# Pricing per million tokens — update if Anthropic changes rates
COST_PER_M_INPUT  = 3.00   # USD, claude-sonnet-4-6
COST_PER_M_OUTPUT = 15.00  # USD, claude-sonnet-4-6

# Cargo bench filter — targets exactly one benchmark (subprocess passes <> literally, no shell)
# BabyBear's pretty_name is MontyField31<BabyBearParameters> — confirmed from bench output
BENCH_FILTER = "coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256/1048576"
# Parser safety check — must appear in the matched benchmark name line
# Note: criterion truncates long names so "1048576" is not visible; coset_lde+Radix2DitParallel is unique enough
BENCH_MUST_CONTAIN = ["coset_lde", "Radix2DitParallel"]
# Criterion baseline name used for within-session p-value comparisons.
# --save-baseline saves the current run as this named baseline.
# --baseline compares the next run against it (gives a real p-value instead of None).
CRITERION_BASELINE = "loop-baseline"

# Files agent may WRITE (prefix match, relative to REPO_DIR)
# NOTE: correctness-checker/ is deliberately EXCLUDED — the agent must not
# be able to modify the correctness validation to make wrong code pass.
WRITABLE = ["dft/src/", "baby-bear/src/", "monty-31/src/x86_64_avx512/"]

# Maps writable path prefixes to the crate whose tests cover them.
# Update this when WRITABLE or run_tests() changes.
TARGET_CRATE_MAP = {
    "dft/src/":                          "p3-dft",
    "baby-bear/src/":                    "p3-baby-bear",
    "monty-31/src/x86_64_avx512/":      "p3-baby-bear",
}

# Crates actively tested in run_tests(). Must be kept in sync manually.
TESTED_CRATES = {"p3-dft", "p3-baby-bear", "p3-examples"}

# Diff patterns that are never legitimate in a DFT arithmetic optimization.
# A diff containing these is hard-rejected before testing.
FORBIDDEN_DIFF_PATTERNS = [
    r"^\+[^+].*#\[cfg\(test\)\]",              # cfg(test) guard on new lines
    r"^\+[^+].*#\[cfg\(not\(test\)\)\]",       # cfg(not(test)) fast-path bypass
    r"^\+[^+].*\bdebug_assert\b",              # debug_assert hiding release-only bugs
    r"^\+[^+].*#\[cfg\(not\(debug_assertions\)\)\]",  # F13: release-only code paths
    r"^\+[^+].*#\[cfg\(debug_assertions\)\]",         # debug-only code paths
    r'^\+[^+].*#\[cfg\(feature\s*=',                  # F4: feature-gated code paths
    r'^\+[^+].*#\[cfg\(not\(feature\s*=',             # F4: negated feature gates
    r'^\+[^+].*cfg!\(feature\s*=',                    # F4: cfg! macro feature gates
]

# Dry-spell limit
DRY_SPELL_MIN_ITERS = 30  # don't auto-stop before this many iterations

# Shared environment for benchmark AND correctness checker — ensures identical
# build profile, CPU features, and thread configuration.
# F6: Explicitly pin RUSTFLAGS so ambient changes cannot cause divergence.
BENCH_ENV = {
    "RAYON_NUM_THREADS": "8",
    "NO_COLOR": "1",
    "RUSTFLAGS": os.environ.get("RUSTFLAGS", ""),  # pin at import time
    "CARGO_INCREMENTAL": "0",  # deterministic builds
}

def _snapshot_build_env() -> dict:
    """
    F11: Capture all environment variables that affect Rust compilation.
    Logged per-iteration for full traceability.
    """
    keys = [
        "RUSTFLAGS", "CARGO_INCREMENTAL", "CARGO_TARGET_DIR",
        "CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS",
        "RAYON_NUM_THREADS", "TARGET", "RUSTUP_TOOLCHAIN",
    ]
    env = {**os.environ, **BENCH_ENV}
    return {k: env.get(k, "") for k in keys}

# Files agent may READ (prefix match, relative to REPO_DIR)
READABLE = WRITABLE + ["CLAUDE.md", "dft/Cargo.toml", "dft/benches/",
                        "baby-bear/Cargo.toml", "field/src/",
                        "monty-31/src/x86_64_avx512/"]


# ── Tool definitions ──────────────────────────────────────────────────────────

TOOLS = [
    {
        "name": "read_file",
        "description": (
            "Read a source file from the Plonky3 repository. "
            "Optionally specify start_line and end_line (1-indexed, inclusive) to read only a section."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path relative to Plonky3 repo root, e.g. 'dft/src/butterflies.rs'"
                },
                "start_line": {
                    "type": "integer",
                    "description": "First line to return (1-indexed, inclusive). Omit to start from line 1."
                },
                "end_line": {
                    "type": "integer",
                    "description": "Last line to return (1-indexed, inclusive). Omit to read to end of file."
                }
            },
            "required": ["path"]
        }
    },
    {
        "name": "edit_file",
        "description": (
            "Make a targeted edit to a source file by replacing an exact string. "
            "Preferred over write_file for small changes — much cheaper in tokens. "
            "The old_string must match exactly (including whitespace and indentation). "
            "Only allowed under dft/src/, baby-bear/src/, or monty-31/src/x86_64_avx512/."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path relative to Plonky3 repo root"
                },
                "old_string": {
                    "type": "string",
                    "description": "Exact string to replace (must be unique in the file)"
                },
                "new_string": {
                    "type": "string",
                    "description": "Replacement string"
                }
            },
            "required": ["path", "old_string", "new_string"]
        }
    },
    {
        "name": "write_file",
        "description": (
            "Overwrite a source file in the Plonky3 repository. "
            "Only allowed under dft/src/, baby-bear/src/, or monty-31/src/x86_64_avx512/. "
            "Also allowed: 'eliminated_ideas.md' — write the FULL updated file each time (read first, append your entry, rewrite). "
            "Write the COMPLETE new file content — not a diff. "
            "For small changes to source files, prefer edit_file instead."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path relative to Plonky3 repo root"
                },
                "content": {
                    "type": "string",
                    "description": "Complete new content of the file"
                }
            },
            "required": ["path", "content"]
        }
    },
    {
        "name": "list_dir",
        "description": "List files in a directory within the Plonky3 repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Directory path relative to repo root, e.g. 'dft/src'"
                }
            },
            "required": ["path"]
        }
    },
    {
        "name": "get_assembly",
        "description": (
            "Get the x86-64 assembly output for a specific function in the Plonky3 DFT crate. "
            "Use this to verify what LLVM actually emits for a hot-path function — before and after "
            "a change — to confirm whether your optimization is redundant or genuinely improves codegen. "
            "Requires cargo-show-asm to be installed (`cargo install cargo-show-asm`). "
            "Output is capped at 300 lines to avoid token waste."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "function": {
                    "type": "string",
                    "description": (
                        "Function name filter — a substring of the fully-qualified function name. "
                        "E.g. 'dit_layer_rev_last2_flat' or 'DitButterfly::apply_to_rows'. "
                        "Use a specific name to avoid too many matches."
                    )
                }
            },
            "required": ["function"]
        }
    },
    {
        "name": "read_experiment_diff",
        "description": (
            "Read the full code diff from a previous experiment iteration. "
            "Use this to inspect exactly what a kept or near-miss change did before extending or building on it."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "iteration": {
                    "type": "integer",
                    "description": "Iteration number to retrieve the diff for (e.g. 1, 8)"
                }
            },
            "required": ["iteration"]
        }
    },
]


# ── Tool handlers ─────────────────────────────────────────────────────────────

def tool_read_file(path: str, start_line: int | None = None, end_line: int | None = None) -> str:
    if path == "eliminated_ideas.md":
        if not ELIMINATED_FILE.exists():
            return "// eliminated_ideas.md (empty — no ideas logged yet)\n"
        return f"// eliminated_ideas.md\n{ELIMINATED_FILE.read_text(encoding='utf-8')}"
    if any(path.startswith(p) for p in READABLE) or path == "CLAUDE.md":
        full = (REPO_DIR / path).resolve()
        if not str(full).startswith(str(REPO_DIR.resolve())):
            return f"ERROR: Path traversal detected: {path}"
        if not full.exists() or not full.is_file():
            return f"ERROR: File not found: {path}"
        lines = full.read_text(encoding="utf-8").splitlines(keepends=True)
        total = len(lines)
        if start_line is not None or end_line is not None:
            s = max(1, int(start_line) if start_line is not None else 1)
            e = min(total, int(end_line) if end_line is not None else total)
            lines = lines[s - 1:e]
            header = f"// {path} lines {s}-{e} of {total}\n"
        else:
            header = f"// {path} ({total} lines)\n"
        return header + "".join(lines)
    return f"ERROR: '{path}' is not in the readable paths list."


def tool_read_experiment_diff(iteration: int) -> str:
    if not LOG_FILE.exists():
        return "ERROR: No experiments log found."
    with open(LOG_FILE, encoding="utf-8") as f:
        for line in f:
            try:
                e = json.loads(line)
                if e.get("iteration") == iteration:
                    diff = e.get("diff", "")
                    idea = e.get("agent_idea", "?")
                    kept = "KEPT" if e.get("kept") else "REVERTED"
                    pct = e.get("improvement_pct", 0)
                    if not diff:
                        return f"Iteration {iteration} [{kept} {pct:+.2f}%]: {idea}\n\n(no diff recorded)"
                    return f"Iteration {iteration} [{kept} {pct:+.2f}%]: {idea}\n\n{diff}"
            except json.JSONDecodeError:
                continue
    return f"ERROR: Iteration {iteration} not found in experiment log."


def tool_get_assembly(function: str) -> str:
    """
    Run cargo-show-asm for a function name filter and return the assembly output.
    Caps output at 300 lines to avoid token waste.
    """
    ASM_LINE_LIMIT = 300
    rc, out = run_cmd(
        ["cargo", "asm", "-p", "p3-dft", "--bench", "fft", "--features", "p3-dft/parallel",
         "--release", function],
        timeout=120,
    )
    if rc != 0:
        # cargo-show-asm exits non-zero when multiple matches found — output is still useful
        lines = out.splitlines()
        if not lines:
            return (
                f"ERROR: cargo asm failed for '{function}'.\n"
                "Ensure cargo-show-asm is installed: cargo install cargo-show-asm\n"
                f"Output: {out[:500]}"
            )
    lines = out.splitlines()
    if len(lines) > ASM_LINE_LIMIT:
        truncated = len(lines) - ASM_LINE_LIMIT
        lines = lines[:ASM_LINE_LIMIT]
        lines.append(f"\n... ({truncated} lines truncated — use a more specific function name)")
    return "\n".join(lines)


def tool_write_file(path: str, content: str) -> str:
    if path == "eliminated_ideas.md":
        ELIMINATED_FILE.write_text(content, encoding="utf-8")
        return f"OK: wrote {len(content):,} bytes to eliminated_ideas.md"
    if any(path.startswith(p) for p in WRITABLE):
        full = (REPO_DIR / path).resolve()
        if not str(full).startswith(str(REPO_DIR.resolve())):
            return f"ERROR: Path traversal detected: {path}"
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content, encoding="utf-8")
        return f"OK: wrote {len(content):,} bytes to {path}"
    return f"ERROR: Writing not allowed to '{path}'. Allowed prefixes: {WRITABLE}"


def tool_edit_file(path: str, old_string: str, new_string: str) -> str:
    if any(path.startswith(p) for p in WRITABLE):
        full = (REPO_DIR / path).resolve()
        if not str(full).startswith(str(REPO_DIR.resolve())):
            return f"ERROR: Path traversal detected: {path}"
        if not full.exists():
            return f"ERROR: File not found: {path}"
        content = full.read_text(encoding="utf-8")
        if old_string not in content:
            return f"ERROR: old_string not found in {path}. Check exact whitespace and indentation."
        count = content.count(old_string)
        if count > 1:
            return f"ERROR: old_string appears {count} times in {path} — must be unique."
        new_content = content.replace(old_string, new_string, 1)
        full.write_text(new_content, encoding="utf-8")
        return f"OK: edited {path} ({len(old_string)} chars → {len(new_string)} chars)"
    return f"ERROR: Editing not allowed to '{path}'. Allowed prefixes: {WRITABLE}"


def tool_list_dir(path: str) -> str:
    full = REPO_DIR / path
    if not full.exists():
        return f"ERROR: Directory not found: {path}"
    entries = sorted(str(p.relative_to(REPO_DIR)) for p in full.iterdir())
    return "\n".join(entries)


def execute_tool(name: str, inputs: dict) -> str:
    if name == "read_file":
        path = inputs.get("path")
        if not path:
            return "ERROR: read_file requires a 'path' argument."
        return tool_read_file(path, inputs.get("start_line"), inputs.get("end_line"))
    elif name == "edit_file":
        path = inputs.get("path")
        old_string = inputs.get("old_string")
        new_string = inputs.get("new_string")
        if not path:
            return "ERROR: edit_file requires a 'path' argument."
        if old_string is None:
            return "ERROR: edit_file requires an 'old_string' argument."
        if new_string is None:
            return "ERROR: edit_file requires a 'new_string' argument."
        return tool_edit_file(path, old_string, new_string)
    elif name == "write_file":
        path = inputs.get("path")
        content = inputs.get("content")
        if not path:
            return "ERROR: write_file requires a 'path' argument."
        if content is None:
            return "ERROR: write_file requires a 'content' argument."
        return tool_write_file(path, content)
    elif name == "list_dir":
        path = inputs.get("path")
        if not path:
            return "ERROR: list_dir requires a 'path' argument."
        return tool_list_dir(path)
    elif name == "get_assembly":
        function = inputs.get("function")
        if not function:
            return "ERROR: get_assembly requires a 'function' argument."
        return tool_get_assembly(function)
    elif name == "read_experiment_diff":
        iteration = inputs.get("iteration")
        if iteration is None:
            return "ERROR: read_experiment_diff requires an 'iteration' argument."
        return tool_read_experiment_diff(int(iteration))
    return f"ERROR: Unknown tool '{name}'"


# ── Subprocess helpers ────────────────────────────────────────────────────────

def run_cmd(cmd, cwd=None, timeout=600, extra_env=None):
    """Run a subprocess. Returns (returncode, stdout+stderr). Never raises."""
    env = {**os.environ, **(extra_env or {})}
    try:
        result = subprocess.run(
            cmd, cwd=cwd or REPO_DIR,
            capture_output=True, text=True,
            timeout=timeout, env=env
        )
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 1, f"ERROR: Command timed out after {timeout}s: {' '.join(str(c) for c in cmd)}"


def run_bench(save_baseline: bool = False):
    """
    Run cargo bench for BENCH_TARGET with parallel feature enabled.
    Returns (median_ns: float | None, p_value: float | None, raw_output: str).

    save_baseline=True  → passes --save-baseline <CRITERION_BASELINE> (saves this run as the
                          named baseline; p_value will be None since there is nothing to compare).
    save_baseline=False → passes --baseline <CRITERION_BASELINE> (compares against the saved
                          baseline and returns a real p_value from Criterion's t-test).
    """
    mode_flags = (
        ["--save-baseline", CRITERION_BASELINE]
        if save_baseline
        else ["--baseline", CRITERION_BASELINE]
    )
    print("  [bench] Running...", flush=True)
    t0 = time.time()

    rc, out = run_cmd(
        ["cargo", "bench", "-p", "p3-dft", "--bench", "fft",
         "--features", "p3-dft/parallel",
         "--", BENCH_FILTER, "--noplot", "--measurement-time", "35"] + mode_flags,
        timeout=600,
        extra_env=BENCH_ENV,
    )

    elapsed = time.time() - t0
    print(f"  [bench] Finished in {elapsed:.0f}s", flush=True)

    if rc != 0:
        snippet = out[-1500:] if len(out) > 1500 else out
        print(f"  [bench] FAILED:\n{snippet}", flush=True)
        return None, None, out

    # Parse criterion output: "time:   [lower  MEDIAN  upper]" + p-value from change: line
    lower_ns, median_ns, upper_ns, p_value, matched_name = _parse_criterion_output(out)
    if median_ns is None:
        debug_file = ROOT_DIR / "bench_debug.txt"
        debug_file.write_text(out, encoding="utf-8")
        print(f"  [bench] WARNING: could not parse time. Full output saved to {debug_file}", flush=True)
        print("  [bench] Lines containing 'Radix2DitParallel' or 'time:':", flush=True)
        for line in _strip_ansi(out).splitlines():
            if "Radix2DitParallel" in line or ("time:" in line and "[" in line):
                print(f"    {repr(line)}", flush=True)
    else:
        ci_str = f"  CI=[{lower_ns/1e6:.2f}ms, {upper_ns/1e6:.2f}ms]" if lower_ns else ""
        p_str  = f"  p={p_value:.2f}" if p_value is not None else ""
        print(f"  [bench] {matched_name}: {median_ns/1e6:.2f}ms{ci_str}{p_str}", flush=True)

    return median_ns, p_value, out


def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[mK]", "", text)


def _parse_criterion_output(output: str) -> tuple[float | None, float | None, float | None, float | None, str]:
    """
    Find the benchmark line matching BENCH_MUST_CONTAIN.
    Returns (lower_ns, median_ns, upper_ns, p_value, name).
    All values may be None if not found. p_value is None if no baseline comparison exists.
    """
    unit_map = {"ns": 1.0, "µs": 1e3, "us": 1e3, "ms": 1e6, "s": 1e9}
    output = _strip_ansi(output)

    current_name = ""
    lower_ns = median_ns = upper_ns = p_value = None

    for line in output.splitlines():
        stripped = line.strip()
        if all(kw in stripped for kw in BENCH_MUST_CONTAIN) and "time:" not in stripped:
            current_name = stripped
        if current_name:
            # Parse: time:   [lower  MEDIAN  upper]
            m = re.search(
                r"time:\s+\[([\d.]+)\s+(\S+)\s+([\d.]+)\s+(\S+)\s+([\d.]+)\s+(\S+)\]",
                line
            )
            if m and median_ns is None:
                lo, lo_u = float(m.group(1)), m.group(2)
                med, med_u = float(m.group(3)), m.group(4)
                hi, hi_u  = float(m.group(5)), m.group(6)
                lower_ns  = lo  * unit_map.get(lo_u,  1.0)
                median_ns = med * unit_map.get(med_u, 1.0)
                upper_ns  = hi  * unit_map.get(hi_u,  1.0)
            # Parse: change: [...] (p = 0.03 < 0.05)
            mp = re.search(r"p\s*=\s*([\d.]+)", line)
            if mp and p_value is None:
                p_value = float(mp.group(1))

    return lower_ns, median_ns, upper_ns, p_value, current_name


def run_tests():
    """
    Three-stage correctness check:
      1. cargo test -p p3-dft (debug)   — fast property-based tests (~30s)
      2. cargo test -p p3-dft --release — same tests under release profile,
         catches debug_assertion divergence and release-mode UB (~60s)
      3. cargo test -p p3-examples      — end-to-end ZK prove+verify (~2-4 min)
    Returns (passed: bool, combined_output: str).
    """
    # Stage 1: fast DFT property tests (debug profile)
    print("  [test] Stage 1/3: p3-dft property tests (debug)...", flush=True)
    rc1, out1 = run_cmd(
        ["cargo", "test", "-p", "p3-dft", "--features", "p3-dft/parallel",
         "--", "--quiet"],
        timeout=120,
    )
    if rc1 != 0:
        print(f"  [test] FAILED (p3-dft debug):\n{out1[-800:]}", flush=True)
        return False, out1

    # Stage 1.5: BabyBear field arithmetic tests
    print("  [test] Stage 1.5/3: p3-baby-bear field tests (debug)...", flush=True)
    rc_bb, out_bb = run_cmd(
        ["cargo", "test", "-p", "p3-baby-bear", "--", "--quiet"],
        timeout=120,
    )
    if rc_bb != 0:
        print(f"  [test] FAILED (p3-baby-bear):\n{out_bb[-800:]}", flush=True)
        return False, out1 + out_bb

    # Stage 2: same DFT tests under release profile
    # Catches debug_assertions divergence and optimisation-induced UB.
    # Note: cfg(test) is still set here; cfg(not(test)) split-brain is
    # caught by the static diff inspection in inspect_diff(), not here.
    print("  [test] Stage 2/3: p3-dft property tests (release)...", flush=True)
    rc2, out2 = run_cmd(
        ["cargo", "test", "-p", "p3-dft", "--features", "p3-dft/parallel",
         "--release", "--", "--quiet"],
        timeout=300,
    )
    if rc2 != 0:
        print(f"  [test] FAILED (p3-dft release):\n{out2[-800:]}", flush=True)
        return False, out1 + out2

    # Stage 3: end-to-end prove+verify
    print("  [test] Stage 3/3: p3-examples end-to-end tests...", flush=True)
    rc3, out3 = run_cmd(
        ["cargo", "test", "-p", "p3-examples", "--", "--quiet"],
        timeout=600,
    )
    passed = (rc3 == 0)
    if passed:
        print("  [test] All tests passed.", flush=True)
    else:
        print(f"  [test] FAILED (p3-examples):\n{out3[-800:]}", flush=True)
    return passed, out1 + out_bb + out2 + out3


def build_correctness_checker():
    """
    Build the correctness checker binary under the bench profile.
    F5: Uses --profile bench (not --release) to match the exact profile
    used by `cargo bench`. In Rust, bench and release are distinct profiles
    that can diverge via [profile.bench] in Cargo.toml.
    Returns (success: bool, output: str).
    """
    print("  [checker] Building correctness-checker (bench profile)...", flush=True)
    rc, out = run_cmd(
        ["cargo", "build", "--profile", "bench"],
        cwd=CHECKER_DIR,
        timeout=300,
        extra_env=BENCH_ENV,
    )
    if rc != 0:
        print(f"  [checker] Build FAILED:\n{out[-1000:]}", flush=True)
    return rc == 0, out


def run_correctness_check(modes: list[str], bench_params: dict | None = None) -> dict:
    """
    Run the correctness checker binary with the specified modes.

    Args:
        modes: list of "full" and/or "partial"
        bench_params: dict from extract_bench_params() with added_bits, shift, etc.
                      If None, uses defaults (for backward compat in tests).

    Returns dict with:
        passed: bool — all checks passed
        checks: list of check result dicts
        raw_output: str — combined stdout+stderr
        build_ok: bool — whether the checker built successfully
    """
    if not modes:
        return {"passed": True, "checks": [], "raw_output": "", "build_ok": True}

    mode_str = " + ".join(modes)
    print(f"  [checker] Running correctness check ({mode_str})...", flush=True)
    t0 = time.time()

    # Build the checker (shares cargo cache with benchmark builds)
    build_ok, build_out = build_correctness_checker()
    if not build_ok:
        return {
            "passed": False,
            "checks": [],
            "raw_output": build_out,
            "build_ok": False,
        }

    # Run the checker binary
    # F5: bench profile outputs to target/release/ (bench inherits release in Cargo)
    checker_bin = CHECKER_DIR / "target" / "release" / "correctness-checker"
    if not checker_bin.exists():
        # Some cargo versions use target/bench/ for --profile bench
        checker_bin = CHECKER_DIR / "target" / "bench" / "correctness-checker"

    # F1+F2: Pass benchmark parameters extracted from the source
    cmd = [str(checker_bin)]
    if bench_params:
        cmd += ["--added-bits", str(bench_params.get("added_bits", 1))]
        cmd += ["--shift", str(bench_params.get("shift", "generator"))]
    # F12: Repeat runs to detect nondeterminism
    cmd += ["--repeat", str(CORRECTNESS_REPEAT_RUNS)]
    cmd += modes

    rc, out = run_cmd(
        cmd,
        cwd=CHECKER_DIR,
        timeout=600,
        extra_env=BENCH_ENV,
    )

    elapsed = time.time() - t0
    print(f"  [checker] Finished in {elapsed:.0f}s", flush=True)

    # Parse JSON from stdout (checker writes JSON to stdout, logs to stderr)
    result = {
        "passed": False,
        "checks": [],
        "raw_output": out,
        "build_ok": True,
    }

    # stdout is the first part before stderr in combined output,
    # but we need to find the JSON line specifically
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{") and '"all_passed"' in line:
            try:
                parsed = json.loads(line)
                result["passed"] = parsed.get("all_passed", False)
                result["checks"] = parsed.get("checks", [])
                break
            except json.JSONDecodeError:
                pass

    # F9: Exit code is AUTHORITATIVE. If the binary exited non-zero, the check
    # failed regardless of what the JSON says. A crash after printing JSON
    # (double-free, stack overflow in drop, etc.) must not be treated as success.
    if rc != 0:
        result["passed"] = False
        if not result["checks"]:
            print(f"  [checker] FAILED (exit code {rc}, no parseable output):\n{out[-800:]}", flush=True)
        else:
            print(f"  [checker] FAILED (exit code {rc}, overriding JSON 'all_passed').", flush=True)
    elif result["passed"]:
        print(f"  [checker] All checks PASSED.", flush=True)
    else:
        for check in result["checks"]:
            if not check.get("passed"):
                print(f"  [checker] FAILED: {check.get('mode')} — {check.get('mismatch_details', 'unknown')}", flush=True)

    return result


def audit_test_coverage():
    """
    Reads CLAUDE.md to find the Primary optimization targets, maps each to its
    owning crate via TARGET_CRATE_MAP, and cross-references against TESTED_CRATES.

    Returns a list of (path_prefix, missing_crate) tuples for any gaps found.
    Returns an empty list if coverage is complete.
    """
    claude_md = CLAUDE_MD.read_text(encoding="utf-8")
    # Extract the Primary: line, e.g. "Primary: dft/src/radix_2_dit_parallel.rs, ..."
    primary_line = ""
    for line in claude_md.splitlines():
        if line.strip().startswith("Primary:"):
            primary_line = line
            break

    gaps = []
    for prefix, crate in TARGET_CRATE_MAP.items():
        if prefix in primary_line and crate not in TESTED_CRATES:
            gaps.append((prefix, crate))
    return gaps


def extract_bench_params() -> dict:
    """
    F1+F2: Extract benchmark workload parameters from the benchmark source file
    (dft/benches/fft.rs) instead of hardcoding them. Returns a dict with:
      log_n, cols, added_bits, shift_description
    Falls back to documented defaults if parsing fails, but logs a warning.
    """
    bench_file = REPO_DIR / "dft" / "benches" / "fft.rs"
    defaults = {
        "log_n": 20,
        "cols": 256,
        "added_bits": 1,
        "shift": "generator",
        "source": "default (bench file not parsed)",
    }

    if not bench_file.exists():
        print(f"  [params] WARNING: {bench_file} not found — using defaults.", flush=True)
        return defaults

    content = bench_file.read_text(encoding="utf-8")

    # Parse added_bits: look for coset_lde_batch(..., <number>, ...) or
    # the constant definition. Criterion benchmarks typically define this inline.
    # Common patterns:
    #   dft.coset_lde_batch(mat, 1, shift)
    #   let added_bits = 1;
    added_bits = None
    for m in re.finditer(r'coset_lde_batch\s*\([^,]+,\s*(\d+)\s*,', content):
        added_bits = int(m.group(1))
        break
    if added_bits is None:
        for m in re.finditer(r'(?:let\s+)?added_bits\s*[:=]\s*(\d+)', content):
            added_bits = int(m.group(1))
            break

    # Parse shift: look for the shift argument in coset_lde_batch
    # Common: F::generator(), F::GENERATOR, BabyBear::generator()
    shift = None
    for m in re.finditer(r'coset_lde_batch\s*\([^,]+,\s*\d+\s*,\s*([^)]+)\)', content):
        shift_expr = m.group(1).strip().rstrip(')')
        if "generator" in shift_expr.lower() or "GENERATOR" in shift_expr:
            shift = "generator"
        else:
            shift = shift_expr
        break

    result = {
        "log_n": 20,   # from BENCH_FILTER: 1048576 = 2^20
        "cols": 256,    # from BENCH_FILTER: ncols=256
        "added_bits": added_bits if added_bits is not None else defaults["added_bits"],
        "shift": shift if shift is not None else defaults["shift"],
        "source": str(bench_file),
    }

    if added_bits is None:
        print(f"  [params] WARNING: could not parse added_bits from {bench_file} — using default {result['added_bits']}.", flush=True)
    if shift is None:
        print(f"  [params] WARNING: could not parse shift from {bench_file} — using default '{result['shift']}'.", flush=True)

    return result


# ── Git helpers ───────────────────────────────────────────────────────────────

def git_diff():
    _, diff = run_cmd(["git", "diff", "HEAD"])
    return diff


def git_head_sha() -> str:
    """Return the short SHA of the current HEAD in the Plonky3 repo."""
    _, sha = run_cmd(["git", "rev-parse", "--short", "HEAD"])
    return sha.strip()


def inspect_diff(diff: str) -> dict:
    """
    Static analysis of a candidate diff before testing.

    Returns:
      forbidden  — list of added lines matching FORBIDDEN_DIFF_PATTERNS.
                   Non-empty → hard reject (no tests run).
      unsafe_count — number of added lines introducing 'unsafe'.
                   Logged as a soft audit trail; does not block acceptance.
    """
    forbidden = []
    unsafe_count = 0
    for line in diff.splitlines():
        # Only inspect added lines; skip diff headers (+++).
        if not line.startswith("+") or line.startswith("+++"):
            continue
        for pattern in FORBIDDEN_DIFF_PATTERNS:
            if re.search(pattern, line):
                forbidden.append(line.strip())
        if re.search(r"\bunsafe\b", line):
            unsafe_count += 1
    return {"forbidden": forbidden, "unsafe_count": unsafe_count}


def git_commit(message: str) -> bool:
    """Stage and commit all changes. Returns False if nothing to commit."""
    run_cmd(["git", "add", "-A"])
    _, status = run_cmd(["git", "status", "--porcelain"])
    if not status.strip():
        return False
    run_cmd(["git", "commit", "-m", message])
    return True


def git_revert():
    run_cmd(["git", "checkout", "--", "."])
    for prefix in WRITABLE:
        run_cmd(["git", "clean", "-fd", prefix])


# ── Experiment log ────────────────────────────────────────────────────────────

def load_experiments() -> list:
    if not LOG_FILE.exists():
        return []
    experiments = []
    for line in LOG_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                experiments.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return experiments


def log_experiment(exp: dict):
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(exp, ensure_ascii=False) + "\n")


def _next_experiment_name(target_dir: Path) -> str:
    """Return the next auto-incremented experiment folder name under target_dir."""
    existing_nums = []
    for p in target_dir.glob("experiment_*"):
        try:
            existing_nums.append(int(p.name.split("_")[1]))
        except (IndexError, ValueError):
            pass
    return f"experiment_{max(existing_nums, default=0) + 1}"


def prompt_experiment_metadata() -> tuple[Path, str]:
    """
    Interactively ask for experiment target and name.
    Returns (target_dir, experiment_name).
    """
    base = ROOT_DIR / "experiment_logs"
    default_target = "Plonky3/NTT"
    print(f"\n[archive] Setting up new experiment.")
    target_input = input(f"  Target path under experiment_logs/ [{default_target}]: ").strip()
    target = base / (target_input or default_target)

    default_name = _next_experiment_name(target)
    name_input = input(f"  Experiment folder name [{default_name}]: ").strip()
    name = name_input or default_name

    return target, name


def archive_experiment_log(target_dir: Path | None = None, experiment_name: str | None = None):
    """
    Archive the current experiments.jsonl into the structured experiment_logs folder.
    Writes:
      - experiments_full.jsonl  (all iterations)
      - experiments_kept.jsonl  (kept improvements only)

    If target_dir/experiment_name are None, uses EXP_LOGS and auto-increments.
    """
    if not LOG_FILE.exists():
        return
    experiments = load_experiments()
    if not experiments:
        return

    if target_dir is None:
        target_dir = EXP_LOGS
    if experiment_name is None:
        experiment_name = _next_experiment_name(target_dir)

    dest = target_dir / experiment_name / "logs"
    dest.mkdir(parents=True, exist_ok=True)

    full_path = dest / "experiments_full.jsonl"
    full_path.write_text(
        "\n".join(json.dumps(e, ensure_ascii=False) for e in experiments) + "\n",
        encoding="utf-8"
    )

    kept = [e for e in experiments if e.get("kept")]
    kept_path = dest / "experiments_kept.jsonl"
    kept_path.write_text(
        "\n".join(json.dumps(e, ensure_ascii=False) for e in kept) + "\n",
        encoding="utf-8"
    )

    print(f"[archive] {len(experiments)} experiments ({len(kept)} kept) → {dest}")
    return dest


def format_history(experiments: list) -> str:
    if not experiments:
        return "No experiments yet — you are starting fresh on a clean codebase."

    lines = []

    # 1. Always show ALL kept improvements — never truncated
    kept = [e for e in experiments if e.get("kept")]
    if kept:
        lines.append("=== ALL KEPT IMPROVEMENTS (cumulative) ===")
        lines.append("  (use read_experiment_diff(N) to see the exact code change for any iteration)")
        for e in kept:
            delta = f"{e.get('improvement_pct', 0):+.2f}%"
            p = e.get('bench_p_value')
            p_str = f" p={p:.2f}" if p is not None else ""
            lines.append(f"  #{e['iteration']:03d} {delta:>8}{p_str} — {e.get('agent_idea','?')}")

    # 2. All non-kept attempts
    recent_non_kept = [e for e in experiments if not e.get("kept")]
    if recent_non_kept:
        lines.append(f"\n=== ALL ATTEMPTS ({len(recent_non_kept)}) ===")
        for e in recent_non_kept:
            delta  = f"{e.get('improvement_pct', 0):+.2f}%" if e.get("score_ns") else "N/A"
            reason = e.get("reason", "?")
            lines.append(f"  #{e['iteration']:03d} [{reason:12}] {delta:>8} — {e.get('agent_idea','?')}")

    # 3. Deduplicated list of all failed approaches — prevents repeating
    failed = [e for e in experiments if not e.get("kept") and e.get("reason") in ("regression", "tests_failed")]
    if failed:
        seen = set()
        unique_failed = []
        for e in failed:
            key = (e.get("agent_idea") or "")[:80].lower()
            if key and key not in seen:
                seen.add(key)
                unique_failed.append(e)
        lines.append(f"\n=== PREVIOUSLY TRIED — DO NOT REPEAT ({len(unique_failed)} unique) ===")
        for e in unique_failed:
            tag = "COMPILE" if e.get("reason") == "tests_failed" else f"{e.get('improvement_pct',0):+.2f}%"
            lines.append(f"  #{e['iteration']:03d} [{tag:>8}] {e.get('agent_idea','?')}")

    # 4. Near-misses as combination candidates
    near_misses = [
        e for e in experiments
        if not e.get("kept") and e.get("score_ns") and e.get("reason") == "regression"
        and abs(e.get("improvement_pct", 0)) < 0.5
    ][-3:]
    if near_misses:
        lines.append("\n=== NEAR-MISSES (close — consider combining or revisiting) ===")
        for e in near_misses:
            lines.append(f"  #{e['iteration']:03d} {e.get('improvement_pct',0):+.2f}% — {e.get('agent_idea','?')}")

    return "\n".join(lines)


# ── Prompt builder ────────────────────────────────────────────────────────────

def build_prompt(current_best_ns: float, experiments: list) -> tuple[list, str]:
    """Returns (system_blocks, user_prompt). system_blocks is cached; user_prompt changes each iter."""
    constraints = CLAUDE_MD.read_text(encoding="utf-8") if CLAUDE_MD.exists() else ""
    history = format_history(experiments)

    kept = [e for e in experiments if e.get("kept")]
    total_gain = 0.0
    if kept:
        first_base = kept[0].get("baseline_ns", current_best_ns)
        if first_base:
            total_gain = (first_base - current_best_ns) / first_base * 100

    # Static system content — CLAUDE.md + role. Cached across round-trips.
    system_blocks = [
        {
            "type": "text",
            "text": f"You are a Rust performance engineer optimizing Plonky3's DFT/NTT implementation.\n\n{constraints}",
            "cache_control": {"type": "ephemeral"},
        }
    ]

    eliminated = ""
    if ELIMINATED_FILE.exists():
        eliminated = f"\n## Eliminated Ideas (agent-maintained — read before exploring)\n{ELIMINATED_FILE.read_text(encoding='utf-8')}\n"

    # Dynamic user prompt — changes every iter, not cached.
    user_prompt = f"""## Current State
Benchmark: coset_lde / Radix2DitParallel / BabyBear / 2^20 rows / 256 cols
Current best time: **{current_best_ns / 1e6:.2f}ms** (lower is better)
Total improvement so far: {total_gain:+.2f}%
Benchmark command: `cargo bench -p p3-dft --features p3-dft/parallel --bench fft -- "coset_lde"`

## Experiment History
{history}
{eliminated}
## Your Task
Make ONE focused, targeted optimization to the DFT implementation.

Process:
1. Identify a specific hot-path target
2. Use `get_assembly` to verify what LLVM actually emits before assuming compiler behavior
3. Make exactly one logical change using `write_file`
4. End your response with: `IDEA: <one sentence describing the change and hypothesis>`

**Value criterion**: The only measure of a good change is benchmark improvement in milliseconds. A 3-line change that saves 1% is better than a 1000-line rewrite that saves 0.5%.

**Slice large ideas**: If your idea requires changing more than ~50 lines, find the minimal targeted version first. A small near-miss on the right function is more valuable than a large rewrite.

**You must always make a change.**
"""
    return system_blocks, user_prompt


# ── Agent runner ──────────────────────────────────────────────────────────────

def run_agent_iteration(client: anthropic.Anthropic, system_blocks: list, prompt: str) -> tuple[bool, str, str]:
    """
    Run one multi-turn agent conversation until end_turn.
    Returns (made_file_changes: bool, extracted_idea: str, thinking_summary: str,
             input_tokens: int, output_tokens: int, cost_usd: float).
    system_blocks is passed as the system parameter (cached); prompt is the first user message.
    """
    messages = [{"role": "user", "content": prompt}]
    # Cache tool definitions — static across all round-trips in this iter.
    tools_cached = TOOLS[:-1] + [{**TOOLS[-1], "cache_control": {"type": "ephemeral"}}]
    files_written: list[str] = []
    idea = "(no IDEA: line found)"
    all_text_blocks: list[str] = []  # accumulate all agent text for thinking_summary
    read_call_count = 0  # counts read_file + list_dir calls only
    total_input_tokens = 0
    total_output_tokens = 0
    iter_start = time.time()

    while True:
        elapsed = time.time() - iter_start
        if elapsed > ITER_TIMEOUT_SECS:
            print(f"  [TIMEOUT] Iteration exceeded {ITER_TIMEOUT_SECS}s ({elapsed:.0f}s elapsed) — aborting.", flush=True)
            break
        for _attempt in range(5):
            try:
                with client.messages.stream(
                    model=MODEL,
                    max_tokens=MAX_TOKENS,
                    system=system_blocks,
                    tools=tools_cached,
                    messages=messages,
                ) as stream:
                    had_text = False
                    for event in stream:
                        if event.type == "content_block_delta":
                            delta = event.delta
                            if hasattr(delta, "type") and delta.type == "text_delta" and delta.text:
                                if not had_text:
                                    print("  [agent thinking]", flush=True)
                                    had_text = True
                                print(delta.text, end="", flush=True)
                    if had_text:
                        print(flush=True)  # newline after streamed text
                    response = stream.get_final_message()
                    total_input_tokens  += response.usage.input_tokens
                    total_output_tokens += response.usage.output_tokens
                break  # stream completed successfully
            except anthropic.APIStatusError as _e:
                is_overloaded = (
                    _e.status_code == 529
                    or "overloaded" in str(_e).lower()
                )
                if is_overloaded and _attempt < 4:
                    wait = 30 * (2 ** _attempt)
                    print(f"[loop] Overloaded (status={_e.status_code}) — retrying in {wait}s (attempt {_attempt+1}/5)...", flush=True)
                    time.sleep(wait)
                else:
                    raise

        # Scan text blocks for the IDEA: line and accumulate reasoning
        for block in response.content:
            if hasattr(block, "text") and block.text.strip():
                all_text_blocks.append(block.text.strip())
                if "IDEA:" in block.text:
                    for line in block.text.splitlines():
                        if line.strip().startswith("IDEA:"):
                            idea = line.strip()[len("IDEA:"):].strip()
                            break

        if response.stop_reason == "end_turn":
            break

        if response.stop_reason == "tool_use":
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    try:
                        result = execute_tool(block.name, block.input)
                    except Exception as exc:
                        result = f"ERROR: Tool call raised an exception: {exc}. Fix your arguments and retry."
                    if block.name == "read_file":
                        path = block.input.get("path", "?")
                        sl = block.input.get("start_line")
                        el = block.input.get("end_line")
                        line_count = result.count("\n")
                        range_str = f" lines {sl}-{el}" if sl or el else ""
                        print(f"  [tool] read_file → {path}{range_str} ({line_count} lines)", flush=True)
                    elif block.name == "list_dir":
                        print(f"  [tool] list_dir  → {block.input.get('path', '?')}", flush=True)
                    elif block.name == "read_experiment_diff":
                        print(f"  [tool] read_experiment_diff → iter {block.input.get('iteration', '?')}", flush=True)
                    elif block.name == "write_file":
                        path = block.input.get("path", "?")
                        if result.startswith("OK:"):
                            if path != "eliminated_ideas.md":
                                files_written.append(path)
                            print(f"  [tool] write_file → {path} ({len(block.input.get('content',''))} chars)", flush=True)
                        else:
                            print(f"  [tool] write_file → {path} FAILED: {result}", flush=True)
                    elif block.name == "edit_file":
                        path = block.input.get("path", "?")
                        if result.startswith("OK:"):
                            files_written.append(path)
                            print(f"  [tool] edit_file → {path} ({result})", flush=True)
                        else:
                            print(f"  [tool] edit_file → {path} FAILED: {result}", flush=True)
                    else:
                        print(f"  [tool] {block.name}({list(block.input.keys())})", flush=True)
                    if block.name in ("read_file", "list_dir"):
                        read_call_count += 1
                    # After 4 read/list calls without a write, nudge the agent to stop exploring
                    if read_call_count >= 4 and block.name in ("read_file", "list_dir") and not files_written:
                        result += "\n\n[SYSTEM] You have read enough files. Stop exploring and write your change NOW using write_file or edit_file."
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result,
                    })
            messages.append({"role": "assistant", "content": response.content})
            messages.append({"role": "user", "content": tool_results})

        elif response.stop_reason == "max_tokens":
            # Hit per-call output limit — continue the conversation naturally.
            # The iteration-level timeout (ITER_TIMEOUT_SECS) is the kill switch.
            print(f"  [agent] Hit max_tokens — continuing ({time.time() - iter_start:.0f}s elapsed).", flush=True)
            messages.append({"role": "assistant", "content": response.content})
            tool_use_blocks = [b for b in response.content if hasattr(b, "type") and b.type == "tool_use"]
            if tool_use_blocks:
                # Satisfy API requirement: every tool_use needs a tool_result
                messages.append({"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": b.id, "content": "Response cut off — continue."}
                    for b in tool_use_blocks
                ]})
            else:
                messages.append({"role": "user", "content": "Continue."})
        else:
            print(f"  [agent] Stopped: {response.stop_reason}", flush=True)
            break

    thinking_summary = "\n\n".join(all_text_blocks) if all_text_blocks else ""
    cost_usd = (total_input_tokens * COST_PER_M_INPUT
                + total_output_tokens * COST_PER_M_OUTPUT) / 1_000_000
    return bool(files_written), idea, thinking_summary, total_input_tokens, total_output_tokens, cost_usd


# ── Provenance ────────────────────────────────────────────────────────────────

def collect_provenance() -> dict:
    """Collect environment versions for auditability. Logged once at startup."""
    _, rustc_ver  = run_cmd(["rustc", "--version"])
    _, p3_commit  = run_cmd(["git", "rev-parse", "HEAD"], cwd=REPO_DIR)
    _, p3_branch  = run_cmd(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO_DIR)
    _, uname      = run_cmd(["uname", "-r"])
    _, cpu_model  = run_cmd(["bash", "-c",
        "grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || sysctl -n machdep.cpu.brand_string 2>/dev/null"])
    return {
        "anthropic_version": anthropic.__version__,
        "rustc_version":     rustc_ver.strip(),
        "plonky3_commit":    p3_commit.strip(),
        "plonky3_branch":    p3_branch.strip(),
        "kernel":            uname.strip(),
        "cpu_model":         cpu_model.strip(),
        "timestamp":         datetime.now(timezone.utc).isoformat(),
        "correctness_checker": str(CHECKER_DIR),
        "bench_env_snapshot": _snapshot_build_env(),
    }


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="ZK Autoresearch Loop — Plonky3 DFT")
    parser.add_argument("--max-iter", type=int, default=MAX_ITERATIONS,
                        help=f"Max iterations (default {MAX_ITERATIONS})")
    parser.add_argument("--start-fresh", action="store_true",
                        help="Reset git state + rename old log before starting")
    parser.add_argument("--dry-spell", type=int, default=30,
                        help="Auto-stop after N consecutive non-improvements (default 15)")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY environment variable not set.", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)

    # Log provenance once at startup
    prov = collect_provenance()
    prov_file = ROOT_DIR / "run_provenance.json"
    prov_file.write_text(json.dumps(prov, indent=2))
    print(f"[init] Provenance: rustc={prov['rustc_version']} | "
          f"p3={prov['plonky3_commit'][:12]} ({prov['plonky3_branch']}) | "
          f"anthropic={prov['anthropic_version']}")

    if args.start_fresh:
        # Safety check: warn if there are uncommitted changes about to be destroyed
        _, dirty = run_cmd(["git", "status", "--porcelain"], cwd=REPO_DIR)
        if dirty.strip():
            print("[init] WARNING: --start-fresh will permanently discard these uncommitted changes in Plonky3:")
            print(dirty.strip())
            answer = input("Discard these changes? [y/N] ").strip().lower()
            if answer != "y":
                print("[init] Aborted. Commit or stash your changes first.")
                sys.exit(1)
        print("[init] --start-fresh: reverting git state...")
        git_revert()
        if STOP_FILE.exists():
            STOP_FILE.unlink()
            print("[init] Removed stale STOP file.")
        if LOG_FILE.exists():
            target_dir, experiment_name = prompt_experiment_metadata()
            archive_experiment_log(target_dir, experiment_name)
            LOG_FILE.unlink()
            print(f"[init] Old log archived and removed.")

    # ── Coverage audit ────────────────────────────────────────────────────────
    gaps = audit_test_coverage()
    prov["coverage_gaps"] = [f"{p} -> {c}" for p, c in gaps]
    prov["coverage_gap_acknowledged"] = False
    if gaps:
        print("[WARNING] Test coverage gaps detected:")
        for path, crate in gaps:
            print(f"  {path} is a Primary target but {crate} is not in run_tests()")
        answer = input("Proceed anyway? [y/N] ").strip().lower()
        if answer != "y":
            sys.exit(1)
        prov["coverage_gap_acknowledged"] = True
    prov_file.write_text(json.dumps(prov, indent=2))

    # ── Dirty state check ─────────────────────────────────────────────────────
    if not args.start_fresh:
        _, dirty = run_cmd(["git", "status", "--porcelain"], cwd=REPO_DIR)
        if dirty.strip():
            print("[WARNING] Plonky3 repo has uncommitted changes at startup:")
            print(dirty.strip())
            print("[WARNING] These may be leftover from a previous run. Use --start-fresh to discard, or commit them first.")
            answer = input("Continue anyway? [y/N] ").strip().lower()
            if answer != "y":
                sys.exit(1)

    # ── Establish baseline ────────────────────────────────────────────────────
    baseline_ns = None
    if not args.start_fresh and LOG_FILE.exists():
        existing = load_experiments()
        if existing:
            stored = existing[0].get("baseline_ns")
            stored_commit = existing[0].get("plonky3_commit", "")
            current_commit = prov.get("plonky3_commit", "")
            if stored and stored_commit and stored_commit == current_commit:
                baseline_ns = stored
                print(f"\n[init] Resuming — reusing baseline: {baseline_ns / 1e6:.2f}ms "
                      f"(p3={stored_commit[:12]})\n")
            elif stored and stored_commit != current_commit:
                print(f"\n[init] Plonky3 commit changed ({stored_commit[:12]} → "
                      f"{current_commit[:12]}), re-benchmarking baseline...")

    if baseline_ns is None:
        print("\n[init] Building baseline benchmark (this compiles from scratch)...")
        baseline_ns, _, _ = run_bench(save_baseline=True)
        if baseline_ns is None:
            print("ERROR: Baseline benchmark failed. Fix the project before running the loop.",
                  file=sys.stderr)
            sys.exit(1)
        print(f"[init] Baseline: {baseline_ns / 1e6:.2f}ms\n")

    # Pre-flight correctness check — catch infra issues before spending any tokens
    print("[init] Running pre-flight tests...")
    tests_ok, test_out = run_tests()
    if not tests_ok:
        print("ERROR: Tests failed at startup. Fix the repo before running the loop.", file=sys.stderr)
        print(test_out[-1500:], file=sys.stderr)
        sys.exit(1)
    print("[init] Pre-flight tests passed.\n")

    # Pre-flight correctness checker — build and run full validation at startup
    print("[init] Building and running correctness checker (full validation)...")
    # F1+F2: Extract benchmark parameters from source — not hardcoded
    bench_params = extract_bench_params()
    print(f"[init] Benchmark params: log_n={bench_params['log_n']}, cols={bench_params['cols']}, "
          f"added_bits={bench_params['added_bits']}, shift={bench_params['shift']} "
          f"(source: {bench_params['source']})")
    prov["bench_params"] = bench_params
    prov_file.write_text(json.dumps(prov, indent=2))

    checker_result = run_correctness_check(["full", "partial"], bench_params=bench_params)
    if not checker_result["build_ok"]:
        print("ERROR: Correctness checker failed to build. Check correctness-checker/ crate.", file=sys.stderr)
        sys.exit(1)
    if not checker_result["passed"]:
        print("ERROR: Correctness checker failed at startup. The baseline is already incorrect.", file=sys.stderr)
        sys.exit(1)
    print("[init] Correctness checker passed (full + partial).\n")

    best_ns = baseline_ns
    experiments = load_experiments()
    # On resume, use the best historical score if it's better than the fresh measurement
    kept = [e for e in experiments if e.get("kept") and e.get("score_ns")]
    if kept:
        historical_best = min(e["score_ns"] for e in kept)
        if historical_best < best_ns:
            best_ns = historical_best
            print(f"[init] Resuming with historical best: {best_ns/1e6:.2f}ms")
    start_iteration = len(experiments)

    dry_spell = args.dry_spell

    print(f"[init] Starting at iteration {start_iteration + 1}, max {args.max_iter}")
    print(f"[init] Log file: {LOG_FILE}")
    print(f"[init] Auto-stop after {dry_spell} consecutive non-improvements (after iter {DRY_SPELL_MIN_ITERS}).")
    print(f"[init] Touch '{STOP_FILE.name}' in this directory to stop gracefully.\n")

    # ── Main loop ─────────────────────────────────────────────────────────────
    for i in range(args.max_iter - start_iteration):
        iteration = start_iteration + i + 1

        if STOP_FILE.exists():
            print(f"\n[loop] STOP file detected. Exiting after {iteration - 1} iterations.")
            STOP_FILE.unlink()
            break

        # Auto-stop on dry spell
        if iteration > DRY_SPELL_MIN_ITERS and len(experiments) >= dry_spell:
            recent = experiments[-dry_spell:]
            if all(not e.get("kept") for e in recent):
                print(f"\n[loop] No improvement in last {dry_spell} iterations. Auto-stopping.")
                break

        ts = datetime.now(timezone.utc).isoformat()
        print(f"\n{'=' * 65}", flush=True)
        print(f"[loop] Iteration {iteration}/{args.max_iter} — {ts}", flush=True)
        print(f"[loop] Best: {best_ns / 1e6:.2f}ms | "
              f"Baseline: {baseline_ns / 1e6:.2f}ms | "
              f"Speedup: -{(baseline_ns - best_ns) / baseline_ns * 100:.2f}%", flush=True)

        # 1. Build prompt
        system_blocks, prompt = build_prompt(best_ns, experiments)

        # 2. Call agent
        print("[agent] Calling Claude...", flush=True)
        t_agent = time.time()
        made_changes, idea, thinking_summary, input_tokens, output_tokens, cost_usd = run_agent_iteration(client, system_blocks, prompt)
        agent_secs = round(time.time() - t_agent, 1)
        print(f"[agent] Done in {agent_secs}s | tokens={input_tokens}in/{output_tokens}out | cost=${cost_usd:.4f} | idea: {idea}", flush=True)

        # Base experiment record
        exp = {
            "iteration": iteration,
            "timestamp": ts,
            "kept": False,
            "reason": "no_changes",
            "score_ns": None,
            "baseline_ns": round(best_ns),
            "plonky3_commit": prov.get("plonky3_commit", ""),
            "improvement_pct": 0.0,
            "bench_p_value": None,
            "agent_idea": idea,
            "agent_thinking": "",  # omitted — full reasoning in terminal log
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost_usd": round(cost_usd, 6),
            "diff": "",
            "diff_summary": "",
            "diff_unsafe_count": 0,
            "agent_time_s": agent_secs,
            "correctness_build_ok": None,
            "correctness_checks": [],
            # F10: commit_hash is set to pre-change HEAD here, then updated
            # to post-commit HEAD after git_commit() for kept iterations.
            "commit_hash_before": git_head_sha(),
            "commit_hash": None,  # filled after commit or revert
            "build_profile": "bench",
            # F11: full compilation environment snapshot
            "build_env": _snapshot_build_env(),
        }

        if not made_changes:
            print("[loop] No files changed — skipping benchmark.", flush=True)
            exp["commit_hash"] = exp["commit_hash_before"]  # F10
            log_experiment(exp)
            experiments.append(exp)
            continue

        # Capture diff before testing
        diff = git_diff()
        exp["diff"] = diff
        exp["diff_summary"] = diff[:600] if diff else "(empty diff)"

        # Static diff inspection — hard reject on forbidden patterns, log unsafe
        diff_flags = inspect_diff(diff)
        exp["diff_unsafe_count"] = diff_flags["unsafe_count"]
        if diff_flags["unsafe_count"] > 0:
            print(f"  [diff] WARNING: {diff_flags['unsafe_count']} new unsafe line(s) in diff — logged.", flush=True)
        if diff_flags["forbidden"]:
            exp["reason"] = "forbidden_pattern"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10
            print(f"[loop] REJECTED — diff contains forbidden pattern(s): {diff_flags['forbidden']}", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        # 3. Correctness check (unit tests — fast property-based)
        tests_passed, test_out = run_tests()
        if not tests_passed:
            exp["reason"] = "tests_failed"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10
            print("[loop] Tests failed — reverting.", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        # 3b. Benchmark-coupled correctness check (partial — every iteration)
        # This validates output on a workload structurally equivalent to the benchmark,
        # under the SAME build profile (bench) and features.
        partial_modes = ["partial"]
        if iteration % CORRECTNESS_FULL_EVERY == 0:
            partial_modes.append("full")
        correctness = run_correctness_check(partial_modes, bench_params=bench_params)
        exp["correctness_build_ok"] = correctness["build_ok"]
        exp["correctness_checks"] = correctness["checks"]
        # F8: Track whether this iteration has been fully validated.
        # Changes accepted with only partial validation are "provisional"
        # until a subsequent full validation confirms them.
        exp["correctness_full_validated"] = "full" in partial_modes and correctness["passed"]
        if not correctness["passed"]:
            exp["reason"] = "correctness_failed"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10
            print("[loop] Correctness check failed — reverting.", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        # 4. Benchmark
        score_ns, bench_p_value, bench_out = run_bench()
        if score_ns is None:
            exp["reason"] = "bench_failed"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10
            print("[loop] Benchmark failed — reverting.", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        improvement_pct = (best_ns - score_ns) / best_ns * 100
        exp["score_ns"] = round(score_ns)
        exp["improvement_pct"] = round(improvement_pct, 4)
        exp["bench_p_value"] = bench_p_value

        # 5. Keep or revert
        if improvement_pct > 0 and improvement_pct < MIN_IMPROVEMENT_PCT:
            exp["kept"] = False
            exp["reason"] = "below_threshold"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10: no commit made
            git_revert()
            print(f"[loop] REVERTED — improvement {improvement_pct:+.2f}% below noise threshold ({MIN_IMPROVEMENT_PCT}%).", flush=True)
        elif improvement_pct > 0 and bench_p_value is not None and bench_p_value > P_VALUE_THRESHOLD:
            exp["kept"] = False
            exp["reason"] = "weak_signal"
            git_revert()
            print(f"[loop] REVERTED — improvement {improvement_pct:+.2f}% but p={bench_p_value:.2f} > {P_VALUE_THRESHOLD} (statistically weak).", flush=True)
        elif improvement_pct > 0:
            # F7: INVARIANT — full correctness validation is ALWAYS required
            # before accepting. This is not configurable. No exceptions.
            if "full" not in partial_modes:
                print("[loop] Improvement detected — running MANDATORY full correctness validation before accepting...", flush=True)
                full_correctness = run_correctness_check(["full"], bench_params=bench_params)
                exp["correctness_checks"] = exp.get("correctness_checks", []) + full_correctness.get("checks", [])
                if not full_correctness["passed"]:
                    exp["kept"] = False
                    exp["reason"] = "correctness_failed_full"
                    exp["commit_hash"] = exp["commit_hash_before"]  # F10
                    print("[loop] Full correctness check FAILED — reverting despite benchmark improvement.", flush=True)
                    git_revert()
                    log_experiment(exp)
                    experiments.append(exp)
                    continue

            committed = git_commit(
                f"exp-{iteration:03d}: {improvement_pct:+.2f}% "
                f"({score_ns / 1e6:.2f}ms <- {best_ns / 1e6:.2f}ms)\n\n"
                f"{idea}"
            )
            if not committed:
                exp["kept"] = False
                exp["reason"] = "no_changes"
                exp["commit_hash"] = exp["commit_hash_before"]  # F10
                print("[loop] Agent reported changes but diff is empty — skipping.", flush=True)
            else:
                exp["kept"] = True
                exp["reason"] = "improvement"
                # F10: capture the ACTUAL commit hash of the accepted change
                exp["commit_hash"] = git_head_sha()
                prev_best = best_ns
                best_ns = score_ns
                print(f"[loop] KEPT -{improvement_pct:.2f}% faster — committed.", flush=True)
                # Update Criterion baseline so future p-values compare against the new best.
                run_bench(save_baseline=True)
        else:
            exp["reason"] = "regression"
            exp["commit_hash"] = exp["commit_hash_before"]  # F10: no commit made
            git_revert()
            print(f"[loop] REVERTED +{abs(improvement_pct):.2f}% slower.", flush=True)

        log_experiment(exp)
        experiments.append(exp)

        print(
            f"[loop] score={score_ns / 1e6:.2f}ms  "
            f"delta={-improvement_pct:+.2f}%  "
            f"best={best_ns / 1e6:.2f}ms",
            flush=True
        )

    # ── Summary ───────────────────────────────────────────────────────────────
    kept = [e for e in experiments if e.get("kept")]
    total_gain_pct = (baseline_ns - best_ns) / baseline_ns * 100
    print(f"\n{'=' * 65}")
    print(f"[done] Iterations run  : {len(experiments) - start_iteration}")
    print(f"[done] Improvements    : {len(kept)}")
    print(f"[done] Baseline        : {baseline_ns / 1e6:.2f}ms")
    print(f"[done] Best score      : {best_ns / 1e6:.2f}ms")
    print(f"[done] Total gain      : {total_gain_pct:+.2f}%")
    print(f"[done] Log             : {LOG_FILE}")
    archive_experiment_log()


if __name__ == "__main__":
    main()
