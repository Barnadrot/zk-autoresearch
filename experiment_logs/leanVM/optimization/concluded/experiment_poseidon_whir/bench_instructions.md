# Benchmark instructions: exp5_poseidon_whir

Machine: Hetzner AX42-U
Goal: Measure exp5_poseidon_whir vs main on leanMultisig xmss_aggregate
Workload: xmss_aggregate, 1400 sigs, log_inv_rate=1

## Setup

```bash
cd ~/zk-autoresearch/leanMultisig
```

## Run 1: main baseline

```bash
git checkout main
git pull origin main
RUSTFLAGS="-C target-cpu=native" cargo build --release
./target/release/lean-multisig xmss --n-signatures 1400 -r 1 --repeat 5 2>&1 | tee /tmp/bench_main.log
```

Record: XMSS/s per leaf, total E2E time, proof size.

## Run 2: exp5_poseidon_whir (full branch)

```bash
git checkout exp5_poseidon_whir
RUSTFLAGS="-C target-cpu=native" cargo build --release
./target/release/lean-multisig xmss --n-signatures 1400 -r 1 --repeat 5 2>&1 | tee /tmp/bench_exp5.log
```

Record same metrics.

## Run 3: exp5 minus Poseidon1 cleanup (optional, only if Run 2 shows < 12% gain)

```bash
git checkout exp5_poseidon_whir
# Revert only the Poseidon1 InternalLayer16 change
git checkout main -- crates/backend/koala-bear/src/poseidon1_koalabear_16.rs
RUSTFLAGS="-C target-cpu=native" cargo build --release
./target/release/lean-multisig xmss --n-signatures 1400 -r 1 --repeat 5 2>&1 | tee /tmp/bench_exp5_no_poseidon.log
```

## Rules

- Do NOT modify any code beyond what's listed above
- Do NOT debug if something fails — report back immediately
- Do NOT run any other benchmarks or explore the repo
- RUSTFLAGS="-C target-cpu=native" on every build
- 5 repeats minimum, report all individual numbers + mean
- Report wall clock, XMSS/s, proof size for each run
