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
CLAUDE_MD   = ROOT_DIR / "CLAUDE.md"

MODEL          = "claude-sonnet-4-6"
MAX_TOKENS     = 20000
MAX_ITERATIONS = 100
HISTORY_WINDOW = 5   # last N experiments shown in each prompt
MIN_IMPROVEMENT_PCT = 0.20  # improvements below this are treated as noise

# Pricing per million tokens — update if Anthropic changes rates
COST_PER_M_INPUT  = 3.00   # USD, claude-sonnet-4-6
COST_PER_M_OUTPUT = 15.00  # USD, claude-sonnet-4-6

# Cargo bench filter — targets exactly one benchmark (subprocess passes <> literally, no shell)
# BabyBear's pretty_name is MontyField31<BabyBearParameters> — confirmed from bench output
BENCH_FILTER = "coset_lde/MontyField31<BabyBearParameters>/Radix2DitParallel<MontyField31<BabyBearParameters>>/ncols=256/1048576"
# Parser safety check — must appear in the matched benchmark name line
# Note: criterion truncates long names so "1048576" is not visible; coset_lde+Radix2DitParallel is unique enough
BENCH_MUST_CONTAIN = ["coset_lde", "Radix2DitParallel"]

# Files agent may WRITE (prefix match, relative to REPO_DIR)
WRITABLE = ["dft/src/", "baby-bear/src/"]

# Maps writable path prefixes to the crate whose tests cover them.
# Update this when WRITABLE or run_tests() changes.
TARGET_CRATE_MAP = {
    "dft/src/":       "p3-dft",
    "baby-bear/src/": "p3-baby-bear",
}

# Crates actively tested in run_tests(). Must be kept in sync manually.
TESTED_CRATES = {"p3-dft", "p3-baby-bear", "p3-examples"}

# Diff patterns that are never legitimate in a DFT arithmetic optimization.
# A diff containing these is hard-rejected before testing.
FORBIDDEN_DIFF_PATTERNS = [
    r"^\+[^+].*#\[cfg\(test\)\]",        # cfg(test) guard on new lines
    r"^\+[^+].*#\[cfg\(not\(test\)\)\]", # cfg(not(test)) fast-path bypass
    r"^\+[^+].*\bdebug_assert\b",        # debug_assert hiding release-only bugs
]

# Recovery and dry-spell limits
MAX_RECOVERY      = 2   # max recovery prompts per iteration before abandoning
DRY_SPELL_MIN_ITERS = 20  # don't auto-stop before this many iterations

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
        "name": "write_file",
        "description": (
            "Overwrite a source file in the Plonky3 repository. "
            "Only allowed under dft/src/ or baby-bear/src/. "
            "Write the COMPLETE new file content — not a diff."
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
        ["cargo", "asm", "-p", "p3-dft", "--features", "p3-dft/parallel",
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
    if any(path.startswith(p) for p in WRITABLE):
        full = (REPO_DIR / path).resolve()
        if not str(full).startswith(str(REPO_DIR.resolve())):
            return f"ERROR: Path traversal detected: {path}"
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content, encoding="utf-8")
        return f"OK: wrote {len(content):,} bytes to {path}"
    return f"ERROR: Writing not allowed to '{path}'. Allowed prefixes: {WRITABLE}"


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


def run_bench():
    """
    Run cargo bench for BENCH_TARGET with parallel feature enabled.
    Returns (median_ns: float | None, raw_output: str).
    """
    print("  [bench] Running...", flush=True)
    t0 = time.time()

    rc, out = run_cmd(
        ["cargo", "bench", "-p", "p3-dft", "--bench", "fft",
         "--features", "p3-dft/parallel",
         "--", BENCH_FILTER, "--noplot", "--measurement-time", "35"],
        timeout=600,
        extra_env={"RAYON_NUM_THREADS": "8", "NO_COLOR": "1"},
    )

    elapsed = time.time() - t0
    print(f"  [bench] Finished in {elapsed:.0f}s", flush=True)

    if rc != 0:
        snippet = out[-1500:] if len(out) > 1500 else out
        print(f"  [bench] FAILED:\n{snippet}", flush=True)
        return None, out

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

    return median_ns, out


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


# ── Git helpers ───────────────────────────────────────────────────────────────

def git_diff():
    _, diff = run_cmd(["git", "diff", "HEAD"])
    return diff


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
            lines.append(f"  #{e['iteration']:03d} {delta:>8} — {e.get('agent_idea','?')}")

    # 2. Recent attempts for immediate context (non-kept only, last N)
    recent_non_kept = [e for e in experiments[-HISTORY_WINDOW:] if not e.get("kept")]
    if recent_non_kept:
        lines.append(f"\n=== RECENT ATTEMPTS (last {HISTORY_WINDOW}) ===")
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

def build_prompt(current_best_ns: float, experiments: list) -> str:
    constraints = CLAUDE_MD.read_text(encoding="utf-8") if CLAUDE_MD.exists() else ""
    history = format_history(experiments)

    kept = [e for e in experiments if e.get("kept")]
    total_gain = 0.0
    if kept:
        first_base = kept[0].get("baseline_ns", current_best_ns)
        if first_base:
            total_gain = (first_base - current_best_ns) / first_base * 100

    return f"""You are a Rust performance engineer optimizing Plonky3's DFT/NTT implementation.

{constraints}

## Current State
Benchmark: coset_lde / Radix2DitParallel / BabyBear / 2^20 rows / 256 cols
Current best time: **{current_best_ns / 1e6:.2f}ms** (lower is better)
Total improvement so far: {total_gain:+.2f}%
Benchmark command: `cargo bench -p p3-dft --features p3-dft/parallel --bench fft -- "coset_lde"`

## Experiment History
{history}

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


# ── Agent runner ──────────────────────────────────────────────────────────────

def run_agent_iteration(client: anthropic.Anthropic, prompt: str) -> tuple[bool, str, str]:
    """
    Run one multi-turn agent conversation until end_turn.
    Returns (made_file_changes: bool, extracted_idea: str, thinking_summary: str,
             input_tokens: int, output_tokens: int, cost_usd: float).
    """
    messages = [{"role": "user", "content": prompt}]
    files_written: list[str] = []
    idea = "(no IDEA: line found)"
    all_text_blocks: list[str] = []  # accumulate all agent text for thinking_summary
    read_call_count = 0  # counts read_file + list_dir calls only
    recovery_count = 0
    total_input_tokens = 0
    total_output_tokens = 0

    while True:
        for _attempt in range(5):
            try:
                with client.messages.stream(
                    model=MODEL,
                    max_tokens=MAX_TOKENS,
                    tools=TOOLS,
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
                            files_written.append(path)
                            print(f"  [tool] write_file → {path} ({len(block.input.get('content',''))} chars)", flush=True)
                        else:
                            print(f"  [tool] write_file → {path} FAILED: {result}", flush=True)
                    else:
                        print(f"  [tool] {block.name}({list(block.input.keys())})", flush=True)
                    if block.name in ("read_file", "list_dir"):
                        read_call_count += 1
                    # After 4 read/list calls without a write, nudge the agent to stop exploring
                    if read_call_count >= 4 and block.name in ("read_file", "list_dir") and not files_written:
                        result += "\n\n[SYSTEM] You have read enough files. Stop exploring and write your change NOW using write_file."
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result,
                    })
            messages.append({"role": "assistant", "content": response.content})
            messages.append({"role": "user", "content": tool_results})
        elif response.stop_reason == "max_tokens" and not files_written:
            # Ran out of tokens before writing — give up to MAX_RECOVERY chances.
            # Must provide tool_result for any tool_use blocks in the truncated response.
            recovery_count += 1
            if recovery_count > MAX_RECOVERY:
                print(f"  [agent] Exhausted {MAX_RECOVERY} recovery attempts without writing. Stopping.", flush=True)
                break
            print(f"  [agent] Hit max_tokens without writing. Sending recovery prompt ({recovery_count}/{MAX_RECOVERY}).", flush=True)
            messages.append({"role": "assistant", "content": response.content})
            tool_use_blocks = [b for b in response.content if hasattr(b, "type") and b.type == "tool_use"]
            budget_note = f"This is recovery attempt {recovery_count} of {MAX_RECOVERY}. You must write now or the iteration will be abandoned."

            # Inject last reasoning block so agent continues its in-progress idea
            # rather than pivoting to a safe fallback. Cap at 2000 chars — enough
            # to capture the active idea without inflating the recovery message.
            last_thinking = (all_text_blocks[-1] if all_text_blocks else "")[-2000:]
            thinking_context = (
                f"\n\nYour last reasoning before the cut-off:\n\"\"\"\n{last_thinking}\n\"\"\"\n\n"
                "Continue from exactly where you left off. Do not explore new directions."
            ) if last_thinking else ""

            if tool_use_blocks:
                # Satisfy the API requirement: every tool_use needs a tool_result
                recovery_content = [
                    {
                        "type": "tool_result",
                        "tool_use_id": b.id,
                        "content": (
                            f"Response was cut off.{thinking_context}\n\n"
                            f"{budget_note} Write your change now using write_file. "
                            "End with: IDEA: <one sentence>"
                        ),
                    }
                    for b in tool_use_blocks
                ]
            else:
                recovery_content = [{
                    "type": "text",
                    "text": (
                        f"Your response was cut off before you wrote any file.{thinking_context}\n\n"
                        f"{budget_note} "
                        "Now write your change immediately using write_file — "
                        "be concise, no lengthy preamble. "
                        "End with: IDEA: <one sentence>"
                    )
                }]
            messages.append({"role": "user", "content": recovery_content})
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
    }


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="ZK Autoresearch Loop — Plonky3 DFT")
    parser.add_argument("--max-iter", type=int, default=MAX_ITERATIONS,
                        help=f"Max iterations (default {MAX_ITERATIONS})")
    parser.add_argument("--start-fresh", action="store_true",
                        help="Reset git state + rename old log before starting")
    parser.add_argument("--dry-spell", type=int, default=15,
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
        print("[init] --start-fresh: reverting git state...")
        git_revert()
        if STOP_FILE.exists():
            STOP_FILE.unlink()
            print("[init] Removed stale STOP file.")
        if LOG_FILE.exists():
            backup = LOG_FILE.with_suffix(f".{int(time.time())}.bak.jsonl")
            LOG_FILE.rename(backup)
            print(f"[init] Old log saved to {backup.name}")

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

    # ── Establish baseline ────────────────────────────────────────────────────
    print("\n[init] Building baseline benchmark (this compiles from scratch)...")
    baseline_ns, _ = run_bench()
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
        prompt = build_prompt(best_ns, experiments)

        # 2. Call agent
        print("[agent] Calling Claude...", flush=True)
        t_agent = time.time()
        made_changes, idea, thinking_summary, input_tokens, output_tokens, cost_usd = run_agent_iteration(client, prompt)
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
            "improvement_pct": 0.0,
            "agent_idea": idea,
            "agent_thinking": "",  # omitted — full reasoning in terminal log
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost_usd": round(cost_usd, 6),
            "diff": "",
            "diff_summary": "",
            "diff_unsafe_count": 0,
            "agent_time_s": agent_secs,
        }

        if not made_changes:
            print("[loop] No files changed — skipping benchmark.", flush=True)
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
            print(f"[loop] REJECTED — diff contains forbidden pattern(s): {diff_flags['forbidden']}", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        # 3. Correctness check
        tests_passed, test_out = run_tests()
        if not tests_passed:
            exp["reason"] = "tests_failed"
            print("[loop] Tests failed — reverting.", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        # 4. Benchmark
        score_ns, bench_out = run_bench()
        if score_ns is None:
            exp["reason"] = "bench_failed"
            print("[loop] Benchmark failed — reverting.", flush=True)
            git_revert()
            log_experiment(exp)
            experiments.append(exp)
            continue

        improvement_pct = (best_ns - score_ns) / best_ns * 100
        exp["score_ns"] = round(score_ns)
        exp["improvement_pct"] = round(improvement_pct, 4)

        # 5. Keep or revert
        if improvement_pct > 0 and improvement_pct < MIN_IMPROVEMENT_PCT:
            exp["kept"] = False
            exp["reason"] = "below_threshold"
            git_revert()
            print(f"[loop] REVERTED — improvement {improvement_pct:+.2f}% below noise threshold ({MIN_IMPROVEMENT_PCT}%).", flush=True)
        elif improvement_pct > 0:
            committed = git_commit(
                f"exp-{iteration:03d}: {improvement_pct:+.2f}% "
                f"({score_ns / 1e6:.2f}ms <- {best_ns / 1e6:.2f}ms)\n\n"
                f"{idea}"
            )
            if not committed:
                exp["kept"] = False
                exp["reason"] = "no_changes"
                print("[loop] Agent reported changes but diff is empty — skipping.", flush=True)
            else:
                exp["kept"] = True
                exp["reason"] = "improvement"
                prev_best = best_ns
                best_ns = score_ns
                print(f"[loop] KEPT -{improvement_pct:.2f}% faster — committed.", flush=True)
        else:
            exp["reason"] = "regression"
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


if __name__ == "__main__":
    main()
