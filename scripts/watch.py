#!/usr/bin/env python3
"""
Live experiment monitor for zk-autoresearch.

Usage:
    python3 watch.py experiment_logs/leanVM/optimization/pw4_2_poseidon_2026-05-13/iters.tsv
    python3 watch.py experiments.jsonl
    tail -f iters.tsv | python3 watch.py --tsv
    python3 watch.py                              # read jsonl from stdin
"""

import json
import sys
from pathlib import Path


# --- TSV mode (iters.tsv) ---

def print_tsv_header():
    print(f"{'#':>4}  {'Delta':>8}  {'Status':<20}  {'Files':<30}  Rationale")
    print("-" * 110)


def process_tsv(source):
    print_tsv_header()
    header = None
    keeps = 0
    total = 0

    for line in source:
        line = line.rstrip("\n\r")
        if not line:
            continue

        cols = line.split("\t")

        if header is None:
            header = cols
            continue

        total += 1
        row = dict(zip(header, cols))

        n = row.get("iter", "?")
        delta = row.get("delta_pct", row.get("criterion_pct", row.get("stage2_median_pct", "")))
        status = row.get("status", row.get("gate_decision", ""))
        files = row.get("files_changed", "")[:30]
        rationale = row.get("rationale", "")[:55]

        is_keep = status == "keep" or status == "KEEP"
        if is_keep:
            keeps += 1

        marker = "*" if is_keep else " "
        print(f"{n:>4}{marker} {delta:>8}  {status:<20}  {files:<30}  {rationale}")
        sys.stdout.flush()

    print("-" * 110)
    print(f"Total: {total} iterations, {keeps} keeps")


# --- JSONL mode (experiments.jsonl, legacy) ---

def fmt_ms(ns):
    if ns is None:
        return "   N/A  "
    return f"{ns / 1e6:7.2f}ms"


def fmt_pct(pct):
    if pct is None or pct == 0:
        return "       "
    sign = "+" if pct > 0 else ""
    return f"{sign}{pct:.2f}%"


def print_jsonl_header():
    print(f"{'#':>4}  {'Time':>9}  {'Delta':>8}  {'Best':>9}  {'Status':<8}  Idea")
    print("-" * 80)


def print_jsonl_row(e, best_ns):
    n    = e.get("iteration", "?")
    ns   = e.get("score_ns")
    pct  = e.get("improvement_pct", 0)
    kept = e.get("kept", False)
    idea = e.get("agent_idea", "")[:55]
    reason = e.get("reason", "")

    status = "KEPT   " if kept else f"REVERT "
    if reason in ("no_changes", "tests_failed", "bench_failed"):
        status = reason[:7].upper()
    if reason in ("correctness_failed", "correctness_failed_full"):
        status = "CORR_FL"
    if reason == "forbidden_pattern":
        status = "FORBID "

    best_str = fmt_ms(best_ns)
    print(f"{n:>4}  {fmt_ms(ns)}  {fmt_pct(pct):>8}  {best_str}  {status:<8}  {idea}")


def process_jsonl(source):
    print_jsonl_header()
    best_ns = None
    baseline_ns = None

    for line in source:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue

        ns   = e.get("score_ns")
        kept = e.get("kept", False)

        if baseline_ns is None and e.get("baseline_ns"):
            baseline_ns = e["baseline_ns"]

        if best_ns is None:
            best_ns = e.get("baseline_ns") or ns

        if kept and ns is not None:
            best_ns = ns

        print_jsonl_row(e, best_ns)
        sys.stdout.flush()

    if baseline_ns and best_ns:
        total = (baseline_ns - best_ns) / baseline_ns * 100
        print("-" * 80)
        print(f"Baseline: {fmt_ms(baseline_ns).strip()}  |  "
              f"Best: {fmt_ms(best_ns).strip()}  |  "
              f"Total gain: {total:+.2f}%")


# --- Main ---

if __name__ == "__main__":
    force_tsv = "--tsv" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--tsv"]

    if args:
        path = Path(args[0])
        is_tsv = force_tsv or path.suffix == ".tsv"
        with open(path, encoding="utf-8") as f:
            if is_tsv:
                process_tsv(f)
            else:
                process_jsonl(f)
    else:
        if force_tsv:
            process_tsv(sys.stdin)
        else:
            process_jsonl(sys.stdin)
