#!/usr/bin/env python3
"""Stream-parse xctrace time-profile XML.

xctrace deduplicates frames: backtraces can contain <frame id="N" name="..."/>
(definitions) and <frame ref="N"/> (references to earlier definitions). Same for
backtraces (rows can have <backtrace ref="N"/>). We resolve both layers.

Outputs:
  • total samples, P/E core split, per-thread row counts
  • inclusive bucket share: poseidon, sumcheck/eq_mle, rayon, kernel_wait
"""
import sys, re
import xml.etree.ElementTree as ET
from collections import Counter

path = sys.argv[1]

frame_name = {}      # frame id -> name
backtrace_frames = {} # backtrace id -> tuple of frame_ids (in order)
core_type = {}       # core id -> "P" or "E"
thread_id_of = {}    # thread id -> thread fmt

BUCKETS = {
    "poseidon":    re.compile(r"poseidon|KoalaBear16|full_rounds_16|full_round\b", re.I),
    "sumcheck":    re.compile(r"eq_mle|sumcheck|quotient_gkr|RoundCoeffs|product_computation", re.I),
    "rayon":       re.compile(r"rayon|join_context|bridge_producer_consumer", re.I),
    "kernel_wait": re.compile(r"__psynch_cvwait|swtch_pri|nanosleep|kevent", re.I),
    "compress_mut": re.compile(r"compress_mut", re.I),
    "permute_mut":  re.compile(r"permute_mut", re.I),
    "memmove":     re.compile(r"_platform_memmove|memcpy", re.I),
    "alloc":       re.compile(r"madvise|malloc|free_|RawVecInner|raw_vec|rust_realloc", re.I),
}

# First pass: build frame name table + backtrace frame lists via iterparse
context = ET.iterparse(path, events=('start','end'))
cur_bt = None
cur_frames = []
for ev, el in context:
    if ev == 'start':
        if el.tag == 'frame':
            fid = el.get('id')
            ref = el.get('ref')
            n = el.get('name')
            if fid is not None and n is not None:
                frame_name[fid] = n
            if cur_bt is not None:
                if fid is not None:
                    cur_frames.append(fid)
                elif ref is not None:
                    cur_frames.append(ref)
        elif el.tag == 'backtrace' and el.get('id') is not None:
            cur_bt = el.get('id')
            cur_frames = []
        elif el.tag == 'core' and el.get('id') is not None:
            fmt = el.get('fmt','')
            if '(P Core)' in fmt: core_type[el.get('id')] = 'P'
            elif '(E Core)' in fmt: core_type[el.get('id')] = 'E'
        elif el.tag == 'thread' and el.get('id') is not None:
            thread_id_of[el.get('id')] = el.get('fmt','')
    elif ev == 'end':
        if el.tag == 'backtrace' and cur_bt is not None:
            backtrace_frames[cur_bt] = tuple(cur_frames)
            cur_bt = None
            cur_frames = []
        elif el.tag == 'row':
            el.clear()

# Pre-compute bucket flags per backtrace id
bt_flags = {}
for bid, fids in backtrace_frames.items():
    text = ' '.join(frame_name.get(fid, '') for fid in fids)
    flags = set()
    for bname, rx in BUCKETS.items():
        if rx.search(text):
            flags.add(bname)
    bt_flags[bid] = flags

# Second pass: count rows
total_rows = 0
p_rows = 0
e_rows = 0
unknown_rows = 0
core_per_id = Counter()  # core id -> count
thread_per_id = Counter()
thread_pos = Counter()
bucket_counter = Counter()

context2 = ET.iterparse(path, events=('end',))
for ev, el in context2:
    if el.tag == 'row':
        total_rows += 1
        core_el = el.find('core')
        if core_el is not None:
            cid = core_el.get('ref') or core_el.get('id')
            core_per_id[cid] += 1
            ct = core_type.get(cid, '?')
            if ct == 'P': p_rows += 1
            elif ct == 'E': e_rows += 1
            else: unknown_rows += 1
        thr_el = el.find('thread')
        tid = None
        if thr_el is not None:
            tid = thr_el.get('ref') or thr_el.get('id')
            thread_per_id[tid] += 1
        bt_el = el.find('backtrace')
        if bt_el is not None:
            bid = bt_el.get('ref') or bt_el.get('id')
            flags = bt_flags.get(bid, set())
            for bname in flags:
                bucket_counter[bname] += 1
            if 'poseidon' in flags and tid is not None:
                thread_pos[tid] += 1
        el.clear()

print(f"total rows (each = 1 ms thread-time): {total_rows}")
print(f"\nP-core rows: {p_rows} ({p_rows*100/total_rows:.1f}%)")
print(f"E-core rows: {e_rows} ({e_rows*100/total_rows:.1f}%)")
print(f"unknown:     {unknown_rows}")

n_p_cores = sum(1 for c in core_type.values() if c == 'P')
n_e_cores = sum(1 for c in core_type.values() if c == 'E')
print(f"\nDistinct P core IDs in trace: {n_p_cores}")
print(f"Distinct E core IDs in trace: {n_e_cores}")
if n_p_cores:
    print(f"Per-P-core thread-time: {p_rows/n_p_cores:.0f} ms  (over 16.4 s wall)")
if n_e_cores:
    print(f"Per-E-core thread-time: {e_rows/n_e_cores:.0f} ms  (over 16.4 s wall)")
if n_e_cores and n_p_cores and e_rows:
    p_per = p_rows/n_p_cores
    e_per = e_rows/n_e_cores
    print(f"P-to-E thread-time ratio per core: {p_per/e_per:.2f}× (heterogeneity tax = {(p_per-e_per)/p_per*100:.1f}%)")

print(f"\nInclusive bucket share (any frame in stack matches):")
for bname in BUCKETS:
    v = bucket_counter[bname]
    print(f"  {bname:14s} {v:7d} ({v*100/total_rows:5.1f}% of all rows)")

print(f"\nPer-thread Poseidon-inclusive share:")
for tid, n in thread_per_id.most_common():
    pos = thread_pos.get(tid, 0)
    label = thread_id_of.get(tid, '?')[:60]
    print(f"  tid={tid:>6s} total={n:6d} pos={pos:5d} ({pos*100/n:5.1f}%)  {label}")
