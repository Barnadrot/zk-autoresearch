# pw4_2-m4m: Poseidon performance research on Apple M4 macOS — null result

## Summary

- 12 hypotheses tested across the brain-curated candidate pool (Targets A, C, D, E
  sub-angles) plus four off-pool surfaces.
- **Zero keeps.** Cumulative Δ vs `origin/main @ c868330c` unchanged.
- All four implemented attempts (h1-h4) committed and reverted in-branch per the
  commit-eval-decide protocol; remaining eight (h5-h12) declared at Phase-1 with
  rigorous architectural/workload kill conditions.

## What this PR delivers

This is **a research log**, not a code change. The branch ends with HEAD =
`origin/main @ c868330c` (modulo the commit/revert pairs that document the four
implemented attempts).

The deliverables:
- `experiment_logs/leanMultisig/optimization/pw4_2_poseidon_m4m_2026-05-13/iters.tsv`
  — full per-hypothesis ledger.
- `experiment_logs/leanMultisig/optimization/pw4_2_poseidon_m4m_2026-05-13/verdict.md`
  — structured verdict with the four key learnings.

## Headline finding

The candidate pool's EV estimates were anchored to Hetzner Zen 4 + AVX-512 (the sibling
experiment's hardware) and **do not transfer to Apple M4 NEON**. The two architectural
gaps that defeat the pool:

1. **NEON has 32 Q-registers (128-bit) vs AVX-512's 32 ZMM (512-bit).** One Poseidon-16
   state fits in 4 Q-regs (87% headroom). The `vmovdqa64 %zmm3, 0x780(%rsp,%rsi,1)`
   2.22% spill that anchored Targets A.1/A.2's EV simply does not exist on NEON. The
   x2 batched permute (h1) verified this: M4's OoO scheduler already saturates one
   permutation; cross-permutation ILP yielded no measurable signal.

2. **M4 base has 4P+6E heterogeneous cores with 8 MB SLC.** The M4 P/E
   heterogeneity tax (cvwait 18.54% self-time) **cannot be cheaply reclaimed**: dropping
   to 8 threads regressed wall by 10.94% (h4) — losing the two E-cores' compute capacity
   dominates over the cvwait reduction. And the smaller SLC vs M4 Max defeats the
   developer's own TODO suggestion to precompute eq_middle (h3 +0.52%).

## Workload preconditions

In addition to the architectural gaps, two pool entries (C.1, D.2) **never fire** in
the prove_loop workload:

- **C.1** requires `full_base_width == WIDTH == 16` in `first_digest_layer`. With
  `WHIR_INITIAL_FOLDING_FACTOR=7` and `WHIR_SUBSEQUENT_FOLDING_FACTOR=5`,
  full_base_width is always one of {32, 128, 160, 640}. Fast-path fires zero times.
- **D.2** requires degree-3+ sumcheck. prove_loop's product sumcheck is degree-2
  (`sumcheck_quadratic` returns `(P(0), leading_coeff)`). Toom-Cook savings don't apply.

## Open surfaces deferred

- AIR-side Poseidon evaluation (`lean_vm::tables::poseidon_16` family, 5%+ combined
  self-time) using `Algebra<KB>` generic arithmetic; NEON-packing feasibility is open.
- Per-call-site rayon chunk-size tuning that's heterogeneous-worker-aware (more
  invasive than the global pool tuning of h4).
- macOS QoS-class hints on rayon worker threads, with care around zkalloc thread
  registration (h4 attempt 1 showed the failure mode).

## Cross-platform context

The sibling experiment `pw4_2-2026-05-13` ran in parallel on Hetzner Zen 4 AVX-512;
the two are independent. The cross-platform delta is itself the signal for the curated
pool: if Hetzner found keeps on the same hypotheses that died here, that confirms
those wins are silicon-specific (and the pool was correctly tuned for that target).

## Test plan

- [x] All implemented attempts (h1-h4) compiled clean and passed correctness gates
      (`cargo test -p mt-koala-bear -p mt-symetric -p mt-whir -p mt-poly`)
- [x] `proof_size_check` confirmed bytes within natural ~0.3% noise floor (no
      proof-size regression introduced by any iter)
- [x] All implemented attempts reverted; HEAD ≡ baseline c868330c modulo the
      audit-trail commit/revert pairs
- [x] Eval gate (`eval_paired.sh`) ran for h1, h2, h3, h4 — all DISCARD; rationales in
      iters.tsv

🤖 Generated with [Claude Code](https://claude.com/claude-code)
