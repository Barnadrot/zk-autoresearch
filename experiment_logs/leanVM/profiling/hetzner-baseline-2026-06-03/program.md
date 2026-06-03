## Role

You are a profiling agent. You measure, you do NOT optimize. Your output is data files and a written analysis. You do not modify the leanVM source code. You do not commit anything.

**Hardware:** Hetzner AX42-U, Ryzen 7 PRO 8700GE, 8c/16t, 64 GiB RAM, AVX-512, Linux.

## Target

Profile the leanVM prover on `main` branch. Three workloads:
- Leaf proving: `./target/release/lean-multisig xmss --n-signatures 1550 --repeat 5`
- Recursion (2→1): `./target/release/lean-multisig recursion --n 2 --log-inv-rate 2 --repeat 3`
- Deep recursion: `./target/release/lean-multisig fancy-aggregation --repeat 2`

## Tools

- `perf stat -d` — hardware counters (IPC, cache misses, branch misses)
- `perf record -g -F 999 --call-graph fp -o <output>` — call-graph sampling with EXCLUSIVE self-time
- `perf report -i <file> --stdio --no-children -g none --percent-limit 0.5` — EXCLUSIVE self-time report (--no-children is critical)
- `/usr/bin/time -v` — wall-clock, peak RSS
- `./target/release/lean-multisig <cmd> --json` — structured timing output

**CRITICAL: Use `--no-children` in perf report. Without it, perf reports INCLUSIVE time (parent includes callee time). We need EXCLUSIVE self-time — the time spent in each function itself, not its callees.**

## Profiling Protocol

Build once: `cd ~/zk-autoresearch/leanVM && RUSTFLAGS="-C target-cpu=native" cargo build --release --bin lean-multisig`

For EACH workload:

1. Warmup: run the workload once, discard
2. JSON timing: `./target/release/lean-multisig <cmd> --json 2>/dev/null > <output>`
3. Resource stats: `/usr/bin/time -v ./target/release/lean-multisig <cmd> 2>&1 | tee <output>`
4. Hardware counters: `perf stat -d ./target/release/lean-multisig <cmd> 2>&1 | tee <output>`
5. Call-graph sampling (EXCLUSIVE self-time):
   ```bash
   perf record -g -F 999 --call-graph fp -o /tmp/perf_<workload>.data \
     ./target/release/lean-multisig <cmd> >/dev/null 2>&1
   perf report -i /tmp/perf_<workload>.data --stdio --no-children -g none --percent-limit 0.5 \
     > <output>
   ```

## Output

Write ALL output to `~/zk-autoresearch/experiment_logs/leanVM/profiling/hetzner-baseline-2026-06-03/report/`

### Required files:

1. `leaf.json` — JSON output from xmss
2. `recursion.json` — JSON output from recursion
3. `fancy.json` — JSON output from fancy-aggregation
4. `leaf_perf_stat.txt` — perf stat hardware counters for xmss
5. `recursion_perf_stat.txt` — perf stat hardware counters for recursion
6. `leaf_perf_report.txt` — perf report EXCLUSIVE self-time for xmss
7. `recursion_perf_report.txt` — perf report EXCLUSIVE self-time for recursion
8. `leaf_time.txt` — /usr/bin/time -v for xmss
9. `recursion_time.txt` — /usr/bin/time -v for recursion

### Required analysis:

10. `analysis.md` — written analysis (≤200 lines) with:

**Section 1: Timing**
- Per-workload: wall-clock, peak RSS, XMSS/s (leaf only)
- Recursion share of fancy-aggregation total

**Section 2: Hardware counters**
- IPC (instructions per cycle)
- L1-dcache miss rate
- Branch miss rate
- Regime classification: compute-bound or memory-bound, with evidence

**Section 3: EXCLUSIVE self-time breakdown (from perf report --no-children)**
- Top 10 functions by EXCLUSIVE self-time for leaf
- Top 10 functions by EXCLUSIVE self-time for recursion
- For each function: demangled name, percentage, which component it belongs to (Poseidon native hash / AIR constraint eval / sumcheck / GKR / Merkle / eq polynomial / rayon overhead / other)

**Section 4: Component summary**
Group the top-10 functions into components and sum their exclusive self-time:
- Poseidon native hash (permute_mut, compress_mut): X%
- AIR constraint evaluation (eval_poseidon, eval_2_full_rounds, eval_execution): X%
- Sumcheck inner loop (product_computation, fold_and_compute): X%
- GKR quotient (quotient_gkr, run_phase1): X%
- Eq polynomial (eval_eq, eval_eq_packed): X%
- Merkle tree (build_merkle, first_digest): X%
- Rayon overhead (consume_iter, bridge_producer, wait_until_cold): X%

**Section 5: Bottleneck identification**
- What is the #1 exclusive self-time bottleneck?
- What is the largest COMPONENT bottleneck (sum of related functions)?
- How much headroom does each component have for optimization?

## Constraints

- Do NOT modify any source code
- Do NOT commit anything
- Do NOT push anything
- Write output files to the experiment report/ directory only
- Build with `RUSTFLAGS="-C target-cpu=native"` always
- Run ONE workload at a time
- perf report MUST use --no-children for exclusive self-time
