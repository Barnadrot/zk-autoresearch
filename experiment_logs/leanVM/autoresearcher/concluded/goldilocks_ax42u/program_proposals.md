# Proposals for goldilocks_ax42u program.md

## Context

Emile prioritized Goldilocks migration — currently 2x slower than KoalaBear.
Branch: origin/goldilocks on leanVM. Field: Goldilocks p=2^64-2^32+1.
Hardware: Hetzner AX42-U (Ryzen 7 PRO 8700GE, AVX-512).

The goldilocks branch has different performance characteristics:
- 64-bit field (vs 31-bit KoalaBear) — wider multiplications
- Cubic extension (degree 3, vs quintic degree 5) — cheaper extension ops
- Different Poseidon parameters (alpha, MDS, round counts)
- Karatsuba cubic-extension multiply already landed (285310b9)

## 1. Role

```
You are an autonomous researcher optimizing the leanVM prover on the 
Goldilocks field (p=2^64-2^32+1). The Goldilocks branch is currently 
~2x slower than KoalaBear. Your goal: close this gap through 
implementation-level and protocol-level optimizations specific to the 
64-bit field characteristics.
```

## 2. Phase 0 is MANDATORY — profile first

Unlike pw12-mac where we have profiling data, the goldilocks branch has 
NO profiling data. The bottleneck distribution is unknown and likely 
very different from KoalaBear:
- 64-bit field multiplications are ~4x more expensive than 31-bit
- The cubic extension (degree 3) changes the sumcheck cost model
- AVX-512 can pack 8 Goldilocks elements vs 16 KoalaBear elements

The agent MUST profile before hypothesizing. Phase 0 produces:
1. Flamegraph or perf report (exclusive self-time)
2. perf stat hardware counters (IPC, cache misses)
3. Written profile analysis with component breakdown

## 3. Hard file restrictions

```
Do NOT modify:
- Round counts or security parameters without computing the 
  Goldilocks-specific security bounds first
- WHIR soundness assumptions (JohnsonBound stays)
```

Less restrictive than pw12-mac because Goldilocks parameters may 
legitimately need tuning (they're less mature than KoalaBear's).

## 4. Writable surface

Broader than pw12-mac — the Goldilocks branch may need changes 
across more of the codebase since it's less optimized:

```
All crates under crates/ are writable EXCEPT:
- Do not change the field definition (Goldilocks prime, extension polynomial)
- Do not change the security target (124 bits)
- Round count changes require security analysis in the commit message
```

## 5. Profiling tools (Linux/Hetzner)

```
- perf stat -d (IPC, cache, branch)
- perf record -g -F 999 --call-graph fp + perf report --no-children
- /usr/bin/time -v
- cargo run --release -- xmss --n-signatures 1550 --json
```

## 6. Dispatch prompt

```
read experiment_logs/leanVM/autoresearcher/goldilocks_ax42u/program.md and start the experiment!
```

No papers pre-loaded — the agent needs to profile first and then search 
for papers relevant to the Goldilocks-specific bottleneck. The bottleneck 
might be completely different (e.g., 64-bit multiplication throughput 
rather than constraint evaluation).

## 7. Key differences from KoalaBear experiments

| Aspect | KoalaBear (pw12-mac) | Goldilocks (this) |
|---|---|---|
| Field | 31-bit, α=3 | 64-bit, α=7 |
| Extension | Quintic (degree 5) | Cubic (degree 3) |
| SIMD width | 16 elements/AVX-512 | 8 elements/AVX-512 |
| Bottleneck | Unknown (profile first) | Unknown (profile first) |
| Security params | Mature, locked | Less mature, adjustable with analysis |
| Base branch | main | origin/goldilocks |
| Target | Optimize existing perf | Close 2x gap vs KoalaBear |
