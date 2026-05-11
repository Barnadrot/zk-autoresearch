# ZK Proof System — Actionable Ideas Index (arxiv Second Pass)

> **Reference stack:** KoalaBear (31-bit prime), quartic extension for FS, Poseidon1/2,
> WHIR PCS (FRI variant), GKR-based sumcheck, Merkle commitments, leanMultisig XMSS
> aggregation. Hash-only / post-quantum / no trusted setup. Prover wall-clock is the
> primary metric.

> **Status:** Second-pass survey, arxiv-focused. Paired with `ideas_index.md` (eprint
> first pass). Items here are NOT in the eprint index. Hardware-acceleration and
> systems-papers tilt because that is what arxiv (cs.AR / cs.DC / cs.PF) covers and
> eprint does not.

> **Caveat for our stack:** Most arxiv-side ZK acceleration work targets pairing-curve
> SNARKs (Groth16, HyperPlonk over BLS12-381) where MSM dominates. Our stack is
> hash-only over a 31-bit prime — *we have no MSM*. NTT/sumcheck/Merkle hash kernels
> remain directly transferable; pairing/MSM kernels do not. Each entry below flags
> applicability explicitly.

---

## Category A: GPU Acceleration (cs.DC / cs.AR / cs.PF)

### ZKProphet — Empirical GPU bottleneck characterization
- **Source:** *ZKProphet: Understanding Performance of Zero-Knowledge Proofs on GPUs.*
  arXiv [2509.22684](https://arxiv.org/abs/2509.22684), to appear at IEEE IISWC 2025.
- **Core insight:** Once MSM is GPU-optimized, **NTT becomes up to 90% of GPU prover
  latency.** GPU NTT implementations under-utilize asynchronous compute/memory and are
  bottlenecked by 32-bit integer pipelines with limited ILP because of butterfly data
  dependencies. Recommends precomputed inputs and alternative data layouts.
- **Applicable to:** GPU-side prover analysis. Fundamental finding shapes any GPU
  port roadmap.
- **Estimated impact:** Pure roadmap input — no kernel here. The "NTT is the new
  bottleneck after MSM" claim mirrors what Plonky3 sees on CPU, so the headline
  conclusion transfers.
- **Prerequisites:** None for the insight; substantial work to act on it.
- **Status in production:** Characterization paper; proposed optimizations not
  productized.
- **Relevance to our stack:** **MEDIUM (intel).** Confirms NTT is where to invest
  if/when we add a GPU node. Don't expect MSM-style wins; expect to fight integer-unit
  saturation.

### ZKPOG — End-to-end Plonky2 GPU including witness generation
- **Source:** *ZKPOG: Accelerating WitGen-Incorporated End-to-End Zero-Knowledge Proof
  on GPU.* [eprint 2025/765](https://eprint.iacr.org/2025/765).
- **Core insight:** Prior Plonky2-GPU implementations (e.g. ZPrize, Orbiter) leave
  witness generation, partial product, and quotient on the CPU — bus transfers and
  the CPU stages dominate. ZKPOG moves all stages to GPU and reports **22.8× average
  end-to-end speedup** vs Plonky2 CPU baseline.
- **Applicable to:** Plonky2-style hash-based provers (≈ our family of techniques —
  Plonky3 inherits). Witness gen is structurally similar.
- **Estimated impact:** End-to-end >20× over CPU when all stages are on-device.
- **Prerequisites:** GPU node; willingness to port WitGen.
- **Status in production:** Research; reference implementation reportedly available.
- **Relevance to our stack:** **MEDIUM.** If we ever add a GPU prover, the lesson is
  "don't half-port" — moving 80% of the prover to GPU and leaving WitGen on CPU is a
  trap.

### UniZK — Unified hardware accelerator for hash-based protocols
- **Source:** *UniZK: Accelerating Zero-Knowledge Proof with Unified Hardware and
  Flexible Kernel Mapping.* ASPLOS 2025.
- **Core insight:** A single ASIC fabric that maps to multiple hash-based protocols
  (Plonky2, Starky, …). Reports **267× speedup vs Plonky2 CPU.** Key idea is shared
  primitive units (NTT, Merkle, sumcheck) reused across protocol drivers.
- **Applicable to:** Hash-based (post-quantum) provers — same family as Plonky3 /
  leanMultisig.
- **Estimated impact:** ASIC-scale; competitive with SZKP/zkSpeed on the comparable
  protocols.
- **Prerequisites:** ASIC tape-out; not actionable software-side.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW (direct).** ASIC, not actionable. **MEDIUM (intel)**
  — confirms that the right primitive granularity to harden in silicon is
  NTT+Merkle+sumcheck, exactly what Plonky3 already factors out.

### AIR-ICICLE / ICICLE-Plonky3 — GPU AIR backend for Plonky3
- **Source:** Ingonyama. [*AIR-ICICLE: Plonky3 on ICICLE Part 1*](https://medium.com/@ingonyama/air-icicle-plonky3-on-icicle-part-1-2110d9e86ef9), Feb 2025.
- **Core insight:** Wraps Plonky3's AIR scripting in ICICLE field-library bindings so
  that trace generation and symbolic constraints run with GPU-backed field arithmetic
  while keeping the Plonky3 frontend.
- **Applicable to:** Anyone running Plonky3 (us, leanMultisig, SP1, RISC0 derivatives).
- **Estimated impact:** Per ICICLE-Stwo precedent, 3–7× over heavily-tuned SIMD CPU
  backend; depends on workload mix.
- **Prerequisites:** NVIDIA GPU; Plonky3 backend compatible with ICICLE field traits.
- **Status in production:** Released Feb 2025; tracking maturity.
- **Relevance to our stack:** **HIGH if we ever target GPUs.** This is *the* obvious
  zero-effort GPU port for Plonky3-based stacks like leanMultisig — and our existing
  index lacked a Plonky3-specific GPU integration entry.

### WebGPU + Stwo (zkSecurity / S-two) — Browser/mobile prover
- **Source:** zkSecurity Quarterly. [*Accelerating ZK Proving with WebGPU*](https://blog.zksecurity.xyz/posts/webgpu/);
  Starkware. [*Introducing S-two*](https://starkware.co/blog/s-two-prover/) (Nov 2025
  Starknet mainnet).
- **Core insight:** WGSL compute shaders implementing NTT butterflies in the browser.
  Reports **5× on constraint polynomial evaluation, 2× on the overall pipeline** when
  attached to Stwo. S-two ships CPU/SIMD/GPU/WebGPU/WASM backends.
- **Applicable to:** Any prover wanting client-side / mobile proving without CUDA.
- **Estimated impact:** Modest GPU speedup; major *deployment* unlock (no driver
  install, runs on phone).
- **Prerequisites:** Browser with WebGPU; WGSL kernel for the target field.
- **Status in production:** S-two on Starknet mainnet (Nov 2025).
- **Relevance to our stack:** **LOW today, MEDIUM if we ever want client-side
  signature aggregation proving.** A WGSL KoalaBear NTT kernel does not exist
  upstream as of this writing — would be a from-scratch effort.

### DistMSM — Multi-GPU MSM
- **Source:** ASPLOS 2024. *Accelerating Multi-Scalar Multiplication for Efficient ZKPs
  with Multi-GPU Systems*. Reports 6.39× geomean over single-GPU.
- **Relevance to our stack:** **NONE.** No MSM in WHIR. Listed for completeness.

### AVX-MSM — SIMD MSM framework
- **Source:** TCHES. *SIMD-accelerated Multi-Scalar Multiplication Framework.* 27.86×
  over Pippenger on BLS12-381.
- **Relevance to our stack:** **NONE.** Same reason as DistMSM.

---

## Category B: ASIC and FPGA Accelerators (cs.AR)

### zkSpeed — HyperPlonk ASIC (ISCA 2025)
- **Source:** *Need for zkSpeed: Accelerating HyperPlonk for Zero-Knowledge Proofs.*
  arXiv [2504.06211](https://arxiv.org/abs/2504.06211), ISCA 2025.
- **Core insight:** Full-protocol HyperPlonk ASIC. 366 mm² die, 2 TB/s HBM. **Geomean
  801× over CPU.** Targets witness commitments, wiring identity (permutation), and
  polynomial opening — explicitly accelerates *both* SumCheck and MSM (no NTT
  required because HyperPlonk avoids domain extension).
- **Applicable to:** HyperPlonk / multilinear-IOP provers on pairing curves.
- **Estimated impact:** ASIC-scale.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW (direct).** Pairing-curve, MSM-heavy, very
  different from KoalaBear+WHIR. **MEDIUM (intel)** — confirms even in
  no-NTT designs, sumcheck is one of the two top ASIC targets.

### zkPHIRE — Programmable sumcheck accelerator
- **Source:** *zkPHIRE: A Programmable Accelerator for ZKPs over High-degree Custom
  Gates.* arXiv [2508.16738](https://arxiv.org/abs/2508.16738).
- **Core insight:** First accelerator with **programmable sumcheck** for arbitrary
  custom gates rather than fixed-degree gates. Reports **1486× over CPU** on
  HyperPlonk, **11.87× over prior fixed-function ASICs** at iso-area, scaling to 2³⁰
  constraints with 4–5 KB proofs.
- **Applicable to:** Sumcheck-based provers with diverse / heterogeneous gate degrees
  (LogUp, Lasso, fractional sumcheck, …).
- **Estimated impact:** ASIC-scale.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW (direct), HIGH (intel).** Validates the
  thesis that a programmable sumcheck unit (rather than per-protocol fixed-degree)
  is the right hardware abstraction. Mirrors the case for keeping sumcheck round
  drivers generic in software (we should *not* fork a per-degree hot path).

### MTU — Multifunction Tree Unit (HASP 2025)
- **Source:** *MTU: The Multifunction Tree Unit for Accelerating Zero-Knowledge Proofs.*
  arXiv [2507.16793](https://www.arxiv.org/abs/2507.16793).
- **Core insight:** Hardware unit specialized for tree-structured ZK operations
  (Merkle build, FRI fold trees, generic tree traversal). Targets HyperPlonk, Spartan,
  PLONK.
- **Applicable to:** Any prover where Merkle-tree construction or FRI-style folding
  is a hot path — that is *us*.
- **Estimated impact:** ASIC-scale; not separately quantified in the abstract.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW (direct), MEDIUM (intel).** Tree-build is a
  documented bottleneck in our stack (Plonky3 packed-Poseidon2 Merkle). MTU's
  granularity argument is useful when prioritizing what to vectorize next on CPU.

### SZKP — First end-to-end ZKP ASIC (PACT 2024)
- **Source:** *SZKP: A Scalable Accelerator Architecture for Zero-Knowledge Proofs.*
  arXiv [2408.05890](https://arxiv.org/abs/2408.05890), PACT 2024.
- **Core insight:** Earliest ASIC to host an *entire* zkSNARK proof on-chip (NTT +
  MSM coordinated). Reports **>400× CPU, 12× GPU, 3× prior ASIC.** Solves
  irregular memory access in NTT and data-dependent access in Pippenger MSM.
- **Applicable to:** zkSNARK provers (Groth16-family).
- **Estimated impact:** ASIC-scale.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW.** Pairing-curve target.

### if-ZKP — Intel FPGA MSM accelerator
- **Source:** *if-ZKP: Intel FPGA-Based Acceleration of Zero Knowledge Proofs.*
  arXiv [2412.12481](https://arxiv.org/abs/2412.12481).
- **Core insight:** First FPGA result for BLS12-381 and BN128 MSM on Intel FPGAs via
  OneAPI. **110–150× vs reference software lib.**
- **Relevance to our stack:** **NONE (direct).** Pairing-curve MSM. Listed as
  competitive context.

### Cysic ZK ASIC line / DogeBox / ZK Pro / ZK Air
- **Source:** Cysic Network whitepaper (Sep 2025); DL News interview;
  [*Cysic is Live on the Succinct Prover Network*](https://blog.succinct.xyz/cysic/).
- **Core insight:** Vertical-stack ZK compute network: custom ASICs (charger-sized,
  claimed > server-grade GPU), GPU clusters, portable miners. Live on Succinct's prover
  network. ZK Pro claimed ≈50× RTX 4090.
- **Relevance to our stack:** **LOW.** Marketing-heavy, no public benchmarks against
  KoalaBear/Plonky3/WHIR. Track as commercial signal.

### Irreducible Binius FPGA / Ethereum State Proving Service
- **Source:** [*Reinventing Irreducible*](https://www.irreducible.com/posts/reinventing-irreducible);
  [*Binius Alpha + Ethereum State Proving*](https://www.irreducible.com/posts/ethereum-state-proving-service);
  [*Binius64*](https://www.irreducible.com/posts/announcing-binius64).
- **Core insight:** Custom FPGA datacenters tightly co-designed with Binius (binary
  towers). Binius64 is a CPU-optimized respin of Binius with simpler 64-bit
  AND/OR/XOR/MUL native constraints; release expected to add ZK by end-2025.
- **Relevance to our stack:** **LOW.** Different field family. Watch as competitive
  benchmark.

---

## Category C: CPU SIMD / Field Arithmetic (cs.AR / cs.PF)

### High-Precision NTT on AVX-512 (CMU PACT 2024)
- **Source:** *Accelerating High-Precision Number Theoretic Transforms using Intel
  AVX-512.* PACT 2024.
- **Core insight:** AVX-512-vectorized butterflies for high-precision (≥64-bit) NTT.
  **36× geomean** over scalar baseline across NTT sizes. Targets FHE primarily.
- **Applicable to:** Any NTT inner loop on AVX-512 hardware.
- **Estimated impact:** Already-realized 36× lives in the *high-precision* regime;
  for our 31-bit prime, smaller absolute lift but the dataflow patterns transfer.
- **Status in production:** Research; OpenFHE / Intel HEXL absorb related techniques.
- **Relevance to our stack:** **MEDIUM (intel).** KoalaBear NTT is at the small-prime
  end; Plonky3's packed AVX-512 already gets most of the lift. The paper's value is
  the catalogued layout patterns (Pease dataflow), not raw transferable code.

### MQX — Three new AVX-512 instructions for crypto (arxiv 2509.12494)
- **Source:** *Towards Closing the Performance Gap for Cryptographic Kernels Between
  CPUs and Specialized Hardware.* arXiv [2509.12494](https://arxiv.org/abs/2509.12494).
- **Core insight:** Proposes three new AVX-512 SIMD instructions
  (widening multiply, add-with-carry, sub-with-borrow) for 64-bit big-int arithmetic.
  Reports **38× NTT and 62× BLAS over CPU baselines** with software-only AVX-512;
  **+3.7×** with the proposed MQX extension, narrowing the ASIC gap to 35×.
- **Applicable to:** Big-prime field arithmetic (BLS12-381 Fr, BN254 Fr) — *not* the
  31-bit small primes.
- **Estimated impact:** Big for FHE / pairing-curve provers; small for KoalaBear.
- **Status in production:** ISA proposal, not yet shipping.
- **Relevance to our stack:** **LOW (direct, KoalaBear is 31-bit).** **MEDIUM
  (intel)** — useful framing: even in the 64-bit/128-bit world, dedicated
  carry-chain instructions matter, and Intel APX (already on the roadmap) introduces
  some of them.

---

## Category D: Distributed and Collaborative Proving (cs.CR / cs.DC)

### Scalable Collaborative zk-SNARK (USENIX Sec 2025)
- **Source:** *Scalable Collaborative zk-SNARK and Its Application to Fully Distributed
  Proof Delegation.* [eprint 2024/143](https://eprint.iacr.org/2024/143);
  USENIX Security 2025.
- **Core insight:** MPC-based prover where multiple servers each hold witness shares
  and run an MPC version of the prover. **128 servers × 4Gbps prove a 2²³ data-parallel
  circuit in 2.5 s with 0.5 GB/server.** Reports **19× over local Libra**, **877× over
  prior collab-zkSNARK work.**
- **Applicable to:** Workloads where the witness can be split across mutually
  distrusting parties (privacy applications, MPC-of-prover).
- **Estimated impact:** Drastically lowers per-server memory; enables proving tasks
  that don't fit single-machine RAM.
- **Status in production:** Open-source PoC; not in any major prover today.
- **Relevance to our stack:** **MEDIUM.** XMSS aggregation has the structural property
  of independent signatures, but our threat model doesn't require *mutually distrusting*
  parties. The MPC machinery is overkill for honest-but-distributed proving. Still, the
  communication-pattern analysis is the right reference for any future multi-machine
  leanMultisig deployment.

### CrowdProve — Community proving for ZK rollups
- **Source:** *CrowdProve: Community Proving for ZK Rollups.* arXiv [2501.03126](https://arxiv.org/abs/2501.03126).
- **Core insight:** Distribute proof generation across volunteer/incentivized
  community machines instead of centralized infra; achieves performance comparable to
  centralized deployments using commodity hardware.
- **Applicable to:** Any rollup-style proof workload that decomposes into shards.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW (direct).** We don't run a rollup. **MEDIUM (intel)**
  for if leanMultisig ever becomes a network-side prover that EthProofs-style operators
  bid for (Boundless / Aligned model).

### Reckle Trees — Updatable Merkle batch proofs
- **Source:** *Reckle Trees: Updatable Merkle Batch Proofs with Applications.*
  [eprint 2024/493](https://eprint.iacr.org/2024/493).
- **Core insight:** Recursive-SNARK-backed batch Merkle proofs that can be *updated*
  in O(log n) rather than re-proved from scratch. Massively-parallel implementation
  reports **270× over sequential.**
- **Applicable to:** State-update proofs (Ethereum-state-style); incremental Merkle
  commitments where leaves change one-at-a-time.
- **Status in production:** Research.
- **Relevance to our stack:** **LOW.** XMSS aggregation is one-shot per slot, not
  incrementally updated. Becomes relevant if we ever build state-history proofs
  for Ethereum.

### STARKPack — Aggregating STARKs over FRI
- **Source:** Nethermind. [*STARKPack: Aggregating STARKs for shorter proofs and faster
  verification*](https://www.nethermind.io/blog/starkpack-aggregating-starks-for-shorter-proofs-and-faster-verification).
- **Core insight:** Aggregate many FRI-based proofs (ethSTARK / Plonky2 / RISC0 /
  Boojum-style) into a single batched proof via shared FRI commit + per-instance
  query phases. Trades per-instance overhead for a one-time batched commit.
- **Applicable to:** FRI/WHIR-based provers proving multiple statements about
  *different* witnesses (not the same one).
- **Estimated impact:** Sub-linear scaling in #instances for argument size and
  verifier work.
- **Status in production:** Nethermind PoC.
- **Relevance to our stack:** **MEDIUM.** XMSS aggregation already aggregates
  *signatures into one statement*; STARKPack would aggregate *multiple aggregation
  proofs into one super-proof*. Useful if we ever batch slot-level proofs into
  epoch-level proofs.

---

## Category E: Streaming and Time–Space Tradeoffs (cs.CC / cs.DS)

### Time–Space Trade-Offs for Sumcheck (TCC 2025)
- **Source:** *Time-Space Trade-Offs for Sumcheck.* [eprint 2025/1473](https://eprint.iacr.org/2025/1473);
  springer TCC 2025.
- **Core insight:** Sharp characterization of prover time vs space for sumcheck on
  multilinear and product-of-multilinear claims. For single multilinear: **O(kN) time
  / O(N^{1/k}) space, optimal for non-adaptive provers.** For products: O(N(log log N
  + k)) / O(N^{1/k}). Reports **120× memory reduction at <2× time overhead** in their
  algorithm.
- **Applicable to:** Sumcheck drivers for memory-constrained provers; complements
  HOBBIT.
- **Estimated impact:** Up to 120× RAM reduction; <2× wall-clock penalty.
- **Status in production:** Research.
- **Relevance to our stack:** **MEDIUM.** Direct upgrade path for HOBBIT-style
  streaming sumcheck. Becomes HIGH if leanMultisig ever hits RAM ceilings (large
  validator sets).

### Blendy — Earlier time-space tradeoff for sumcheck
- **Source:** *A Time-Space Tradeoff for the Sumcheck Prover.* [eprint 2024/524](https://eprint.iacr.org/2024/524).
- **Core insight:** Predecessor to TCC 2025 result; family of prover algorithms with
  tunable time/space knobs. Already fits between linear-time/linear-space and
  log-space/superlinear-time prior endpoints.
- **Status in production:** Reference impl on github.
- **Relevance to our stack:** **MEDIUM.** Same use case as the newer TCC-2025 result;
  start here if exploring streaming sumcheck because the implementation exists.

### Streaming Zero-Knowledge Proofs (Cormode et al.)
- **Source:** arXiv [2301.02161](https://arxiv.org/abs/2301.02161).
- **Core insight:** Earlier theoretical foundation for streaming sumcheck-based
  proving in space-bounded models. Background reading for the recent applied papers.
- **Relevance to our stack:** **LOW (direct).** Useful background only.

---

## Category F: Survey / Characterization (cs.CR / cs.PF)

### Analyzing Performance Bottlenecks in ZK Rollups (arxiv 2503.22709)
- **Source:** *Analyzing Performance Bottlenecks in Zero-Knowledge Proof Based Rollups
  on Ethereum.* arXiv [2503.22709](https://arxiv.org/abs/2503.22709).
- **Core insight:** CPU profiling of zkRollup provers; **zk-SNARKs bottlenecked by
  pairing + field arithmetic; zk-STARKs by polynomial + big-integer ops.** Confirms
  proof-gen time scales with batch size, while verification stays constant.
- **Status in production:** Empirical study, 2025.
- **Relevance to our stack:** **MEDIUM (intel).** The "STARK provers are bound by
  poly + big-int ops" finding is consistent with our experience. Useful citation for
  future profiling write-ups.

### Comparative SNARK vs STARK on ARM (arxiv 2512.10020)
- **Source:** *A Comparative Analysis of zk-SNARKs and zk-STARKs: Theory and Practice.*
  arXiv [2512.10020](https://arxiv.org/abs/2512.10020).
- **Core insight:** Empirical SNARK-vs-STARK comparison on ARM. SNARKs **68×** faster
  prover, **123×** smaller proofs; STARKs verify faster, no setup, post-quantum.
- **Relevance to our stack:** **LOW.** Standard tradeoff; nothing actionable beyond
  reaffirming the post-quantum/no-setup choice we already made.

### ZKP Frameworks Systematic Survey (arxiv 2502.07063)
- **Source:** *Zero-Knowledge Proof Frameworks: A Systematic Survey.* arXiv
  [2502.07063](https://arxiv.org/abs/2502.07063).
- **Core insight:** Catalog/taxonomy of ZK frameworks with usability-vs-performance
  scoring.
- **Relevance to our stack:** **LOW.** Survey; no new technique.

### ZK ML Acceleration Survey (arxiv 2502.18535)
- **Source:** *A Survey of Zero-Knowledge Proof Based Verifiable Machine Learning.*
- **Core insight:** Survey of ZK-ML systems including zkLLM (CCS 2024) which proves
  inference for 13 B parameter LLMs in CUDA.
- **Relevance to our stack:** **LOW.** ML-specific; mentions zkLLM as a notable
  CUDA prover for tensor operations.

### Berkeley EECS-2025-32 — Co-Design Thesis
- **Source:** *Scaling Zero Knowledge Proofs Through Application and Proof System
  Co-Design.* UC Berkeley EECS-2025-32 (2025 PhD thesis).
- **Core insight:** Application-driven proof-system co-design — adapt proof-system
  parameters to application access patterns. Relevant for repeatable workloads
  (zkVMs, zkRollups, signature aggregation).
- **Relevance to our stack:** **MEDIUM (intel).** XMSS aggregation is exactly the
  kind of repeatable workload that benefits from co-design. Worth skimming for
  framing.

---

## Net-New Adjacent Findings (not separate entries)

- **Zera compiler (MIT thesis, 2025)** — high-level compiler that lowers ZK algorithms
  to parallel hardware patterns; mentioned in batched-sumcheck context. Useful as a
  framing for "where does this kernel's parallelism live."
- **Polygon Labs × Irreducible Binius zkVM** — Binius-based zkVM partnership
  announced 2025; competitive intel for hash-based zkVMs.
- **Orbiter Finance Plonky2 GPU** — community blog reports 59% speedup on a
  20-secp256k1-signature batch via partial GPU port. Anecdote; reinforces the
  "don't half-port" lesson from ZKPOG.

---

## Top Net-New Recommendations to MERGE into the Main Index Top-10

These are arxiv-side findings that belong in the main `ideas_index.md` Top-10 or
Honorable Mentions, ordered by realistic impact for our KoalaBear+WHIR+leanMultisig
stack:

### Tier 1 — Belongs in main Top-10

1. **AIR-ICICLE / ICICLE-Plonky3 (Ingonyama, Feb 2025).** Direct GPU integration
   path for Plonky3 stacks. Should replace or augment the existing generic ICICLE
   entry in main Top-10 honorable mentions, as it's the *Plonky3-specific*
   bridge — which is what we run. Slot: bump from "honorable mention" to a Top-10
   conditional entry ("if/when GPU node is added, this is the move").

2. **Time-Space Trade-Offs for Sumcheck (TCC 2025) + Blendy (eprint 2024/524).**
   Quantitatively sharper than the HOBBIT entry already in the index (120× RAM
   reduction at <2× time overhead, optimal characterization). Suggest replacing the
   single "HOBBIT streaming sumcheck" honorable mention with a combined entry that
   cites HOBBIT + Blendy + TCC 2025 — pointing to Blendy first because its
   reference impl exists.

3. **ZKProphet GPU bottleneck characterization (IISWC 2025).** Important
   *negative-result-style* finding: even with optimized MSM, NTT becomes 90% on GPUs
   — applies symmetrically to FRI/WHIR commit phase on hash-only GPU prover. Should
   be in main index as a pre-investment sanity-check before committing to a GPU port.

### Tier 2 — Add to "Honorable Mentions" / track

4. **zkPHIRE programmable sumcheck (ASIC, 2025).** Its *programmable-sumcheck-as-the-
   right-abstraction* thesis validates our existing software architectural choice
   (generic sumcheck driver in Plonky3). Cite as intel under Category 5 hardware
   when the main index revisits the "if we ever do hardware" theme.

5. **MTU Multifunction Tree Unit (HASP 2025).** Tree-build hardware concept directly
   relevant given Merkle is a hot path in our stack. Honorable mention.

6. **WebGPU + Stwo / S-two browser proving.** Becomes Top-3 if we ever pursue
   client-side aggregation proofs (validator nodes proving locally before gossip).

7. **Scalable Collaborative zk-SNARK (USENIX Sec 2025).** Becomes Top-5 if leanMultisig
   ever wants distributed-prover sharding *and* the threat model permits MPC-based
   coordination. The communication-pattern numbers (2²³ gates / 2.5 s on 128 servers)
   are the right reference design.

### Tier 3 — Note in "Skipped (out of scope)"

The following are net-new on arxiv but **out of scope for our stack** because they
target pairing-curve MSM that we do not have:

- zkSpeed (HyperPlonk ASIC), SZKP (zkSNARK ASIC), if-ZKP (FPGA MSM), DistMSM,
  AVX-MSM, MQX (helps mostly big-prime/FHE).

These should be listed in a "Skipped" section in the main index for completeness
so future-us doesn't re-research them. Their value is *competitive intel* on what
non-hash-based provers are doing in hardware, not actionable optimizations.

### Suggested updated main-index Top-10 (proposed delta)

> Items 1–10 from the existing main Top-10 stand. The arxiv pass adds:
> - **#10½ → AIR-ICICLE GPU integration** (replaces/augments the generic ICICLE
>   honorable mention).
> - **Honorable mention upgrade:** HOBBIT streaming sumcheck → "HOBBIT + Blendy +
>   Time-Space TCC 2025" combined entry.
> - **New honorable mention:** ZKProphet (sets GPU expectations).
> - **New honorable mention:** zkPHIRE (validates programmable-sumcheck thesis).
> - **New "Skipped" sub-section:** MSM-heavy hardware acceleration (zkSpeed, SZKP,
>   if-ZKP, DistMSM, AVX-MSM, MQX) — out-of-scope for hash-only KoalaBear stack,
>   tracked for competitive context only.

---

## Methodology Notes

- Searched arxiv cs.AR, cs.DC, cs.PF, cs.CR for 2024-01 through 2026-05.
- Cross-checked via Google Scholar and venue proceedings (ISCA 2025, PACT 2024,
  HASP 2025, ASPLOS 2024/2025, USENIX Security 2025, IISWC 2025, TCC 2025).
- Vendor blogs: Ingonyama, Cysic, Irreducible, Starkware, zkSecurity, Nethermind.
- Items already covered in `ideas_index.md` (eprint pass) are NOT duplicated here,
  with one exception: HOBBIT/Blendy/TCC-2025 are noted because the main index entry
  for HOBBIT predates the sharper TCC 2025 result and Blendy's reference impl.
- Hardware-acceleration entries skew lower-relevance for our stack because most
  arxiv ZK-systems work targets pairing-curve MSM, which our hash-only WHIR stack
  doesn't have. NTT/sumcheck/Merkle papers transfer; MSM papers don't.
