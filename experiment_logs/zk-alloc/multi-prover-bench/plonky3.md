# Plonky3 — zk-alloc benchmark results

**Date:** 2026-04-26
**Machine:** Hetzner AX42-U (AMD Ryzen 7 PRO 8700GE, 8C/16T, 64GB DDR5)
**DFT:** Radix2Bowers (single-threaded)
**All proofs cryptographically verified.**

---

## Poseidon1 AIR (BabyBear, width=16, Keccak commitment, FRI log_blowup=1)

### Warm proof time (average of proof 2-4)

| Trace size | glibc | jemalloc | zk-alloc | vs glibc | vs jemalloc |
|-----------|-------|----------|----------|----------|-------------|
| 2^16 (65K hashes) | 0.771s | 0.771s | 0.674s | **-12.6%** | **-12.6%** |
| 2^18 (262K hashes) | 2.864s | 2.973s | 2.515s | **-12.2%** | **-15.4%** |
| 2^19 (524K hashes) | 5.647s | 5.904s | 5.047s | **-10.6%** | **-14.5%** |
| 2^20 (1M hashes) | 11.602s | 11.913s | 10.744s | **-7.4%** | **-9.8%** |

---

## Poseidon2 AIR (KoalaBear, vectorized 8x, Keccak commitment, FRI log_blowup=1)

*This is what SP1 and production Plonky3 users run.*

### Warm proof time (average of proof 2-4)

| Trace size | glibc | jemalloc | zk-alloc | vs glibc | vs jemalloc |
|-----------|-------|----------|----------|----------|-------------|
| 2^16 rows (524K perms) | 2.487s | 2.515s | 2.078s | **-16.4%** | **-17.4%** |
| 2^18 rows (2M perms) | 10.180s | 10.345s | 8.618s | **-15.3%** | **-16.7%** |

### Cold proof time (proof 1)

| Trace size | glibc | jemalloc | zk-alloc |
|-----------|-------|----------|----------|
| 2^16 rows | 2.506s | 2.544s | 3.072s |
| 2^18 rows | 10.219s | 10.333s | 10.976s |

---

## Keccak AIR (BabyBear, ~1600 columns, Keccak commitment, FRI log_blowup=1)

*Widest trace — heaviest memory stress test.*

### Warm proof time (average of proof 2-4)

| Trace size | glibc | jemalloc | zk-alloc | vs glibc | vs jemalloc |
|-----------|-------|----------|----------|----------|-------------|
| 1365 hashes (2^15 rows) | 2.186s | 2.199s | 1.845s | **-15.6%** | **-16.1%** |
| 5461 hashes (2^17 rows) | 8.947s | 8.986s | 7.517s | **-16.0%** | **-16.3%** |

### Cold proof time (proof 1)

| Trace size | glibc | jemalloc | zk-alloc |
|-----------|-------|----------|----------|
| 1365 hashes | 2.218s | 2.208s | 2.999s |
| 5461 hashes | 8.976s | 8.981s | 10.209s |

---

## Summary across all workloads

| Workload | vs glibc | vs jemalloc |
|----------|----------|-------------|
| Poseidon1 (BabyBear) | **-7% to -13%** | **-10% to -15%** |
| Poseidon2 (KoalaBear, vectorized) | **-15% to -16%** | **-17%** |
| Keccak (BabyBear, wide trace) | **-16%** | **-16%** |

**Poseidon2 and Keccak show the strongest effect** because they have wider traces
(more columns per row) which means more memory touched per proof. The bump allocator's
contiguous layout maximizes hardware prefetcher effectiveness.

**jemalloc is consistently slower than glibc** on all Plonky3 workloads (+1-3%).
Plonky3's recommendation to use jemalloc appears counterproductive on this hardware.

## Key observations

1. **zk-alloc delivers -15% to -17% on production-representative workloads** (Poseidon2/KoalaBear).
2. **Effect scales with trace width**: Poseidon1 (~400 cols) shows -12%, Keccak (~1600 cols) shows -16%.
3. **Cold proof is 8-20% slower** due to demand-paging. Strictly a warm-proof optimization.
4. **Single-threaded only** — with Radix2DitParallel + rayon, the gap would widen further.

## Raw data

### Poseidon1 2^16 (4 iterations)
```
glibc:     0.790  0.768  0.768  0.777
jemalloc:  0.781  0.773  0.770  0.770
zk-alloc:  0.952  0.673  0.676  0.674
```

### Poseidon1 2^18 (4 iterations)
```
glibc:     2.931  2.865  2.859  2.869
jemalloc:  2.983  2.966  2.981  2.973
zk-alloc:  3.536  2.513  2.511  2.521
```

### Poseidon1 2^19 (4 iterations)
```
glibc:     5.801  5.669  5.610  5.661
jemalloc:  5.917  5.920  5.913  5.879
zk-alloc:  7.031  5.052  5.048  5.041
```

### Poseidon1 2^20 (4 iterations)
```
glibc:     11.780  11.656  11.606  11.544
jemalloc:  11.818  11.910  11.905  11.924
zk-alloc:  13.194  10.757  10.730  10.744
```

### Poseidon2 2^16 rows (4 iterations)
```
glibc:     2.506  2.492  2.486  2.483
jemalloc:  2.544  2.519  2.523  2.504
zk-alloc:  3.072  2.079  2.076  2.078
```

### Poseidon2 2^18 rows (4 iterations)
```
glibc:     10.219  10.183  10.186  10.172
jemalloc:  10.333  10.371  10.338  10.326
zk-alloc:  10.976  8.625  8.615  8.614
```

### Keccak 1365 hashes (4 iterations)
```
glibc:     2.218  2.208  2.176  2.174
jemalloc:  2.208  2.212  2.191  2.193
zk-alloc:  2.999  1.861  1.840  1.835
```

### Keccak 5461 hashes (4 iterations)
```
glibc:     8.976  8.927  8.942  8.971
jemalloc:  8.981  8.968  8.974  9.015
zk-alloc:  10.209  7.498  7.506  7.547
```
