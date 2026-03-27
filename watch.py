#!/usr/bin/env python3
"""
Live experiment monitor — pipe experiments.jsonl into this.

Usage:
    tail -f experiments.jsonl | python3 watch.py
    python3 watch.py experiments.jsonl        # read existing log
    python3 watch.py                          # read from stdin
"""

import json
import sys
from pathlib import Path


def fmt_ms(ns):
    if ns is None:
        return "   N/A  "
    return f"{ns / 1e6:7.2f}ms"


def fmt_pct(pct):
    if pct is None or pct == 0:
        return "       "
    sign = "+" if pct > 0 else ""
    return f"{sign}{pct:.2f}%"


def print_header():
    print(f"{'#':>4}  {'Time':>9}  {'Delta':>8}  {'Best':>9}  {'Status':<8}  Idea")
    print("-" * 80)


def print_row(e, best_ns):
    n    = e.get("iteration", "?")
    ns   = e.get("score_ns")
    pct  = e.get("improvement_pct", 0)
    kept = e.get("kept", False)
    idea = e.get("agent_idea", "")[:55]
    reason = e.get("reason", "")

    status = "KEPT   " if kept else f"REVERT "
    if reason in ("no_changes", "tests_failed", "bench_failed"):
        status = reason[:7].upper()

    best_str = fmt_ms(best_ns)
    print(f"{n:>4}  {fmt_ms(ns)}  {fmt_pct(pct):>8}  {best_str}  {status:<8}  {idea}")


def process_stream(source):
    print_header()
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

        print_row(e, best_ns)
        sys.stdout.flush()

    if baseline_ns and best_ns:
        total = (baseline_ns - best_ns) / baseline_ns * 100
        print("-" * 80)
        print(f"Baseline: {fmt_ms(baseline_ns).strip()}  |  "
              f"Best: {fmt_ms(best_ns).strip()}  |  "
              f"Total gain: {total:+.2f}%")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
        with open(path, encoding="utf-8") as f:
            process_stream(f)
    else:
        process_stream(sys.stdin)
