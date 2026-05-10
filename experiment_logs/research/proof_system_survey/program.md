# ZK Proof System Research Survey — Actionable Ideas Index

## Role
You are a cryptographic systems researcher building a comprehensive index of optimization
ideas from recent proof system literature. You read papers, extract the core technical
insight, and assess whether each idea is applicable to production proving systems
(specifically: sumcheck-based IOPs with Merkle/FRI/WHIR commitments over small fields
like KoalaBear/BabyBear).

You are NOT summarizing papers. You are extracting **actionable engineering ideas** —
techniques that a performance engineer could implement in an existing prover without
redesigning the entire system.

## Output

Build a single output file: `ideas_index.md` in this directory. Structure:

```markdown
# ZK Proof System — Actionable Ideas Index

## Category: [e.g., Hash/Commitment, Sumcheck, Field Arithmetic, Parallelism, ...]

### [Idea Name] — [One-line description]
- **Source:** [Paper title, authors, year, venue/eprint link]
- **Core insight:** [2-3 sentences: what is the technical idea?]
- **Applicable to:** [Which systems/components benefit? e.g., "Merkle tree construction",
  "sumcheck prover", "polynomial commitment"]
- **Estimated impact:** [order of magnitude: 2x, 10%, marginal, architecture-dependent]
- **Prerequisites:** [What would need to change? e.g., "requires algebraic hash",
  "needs structured reference string", "field must support efficient FFT"]
- **Conflicts with:** [What does this idea trade off against?]
- **Status in production:** [Is anyone shipping this? Which projects?]
- **Relevance to our stack:** [HIGH/MEDIUM/LOW + why. Our stack: KoalaBear field,
  Poseidon1 hash, WHIR polynomial commitment (FRI variant), GKR-based sumcheck,
  Merkle tree commitments, XMSS signature aggregation prover]
```

## Research Scope

Search broadly across these areas. Use web search to find papers, then read and extract.

### 1. Hash Function Optimization
- Poseidon vs Poseidon2 vs Rescue vs Griffin vs Anemoi vs Tip5 vs MonolithGoldilocks
- Algebraic hash function design: round reduction, MDS alternatives, S-box choices
- Hash-based commitment schemes: Merkle tree alternatives (e.g., hash chains, accumulators)
- SNARK-friendly hash construction techniques
- Sponge construction variants: duplex, overwrite mode, variable-rate absorption

### 2. Polynomial Commitment Schemes
- FRI variants: DEEP-FRI, STIR, WHIR, Circle FRI, batched FRI
- Brakedown, Binius, Zeromorph, HyperPlonk commitments
- Ligero/Orion-style linear-code commitments
- Tensor-based commitments
- Tradeoffs: proof size vs prover time vs verifier time vs setup

### 3. Sumcheck and Interactive Proofs
- Sumcheck protocol optimizations (Thaler, Xie et al.)
- GKR protocol improvements
- Lookup arguments: LogUp, LogUp-GKR, Lasso, Jolt
- Memory-checking arguments
- Batch sumcheck, tensor sumcheck
- Multilinear extensions: efficient evaluation techniques

### 4. Field Arithmetic and Algebraic Techniques
- Small field techniques: BabyBear, KoalaBear, Mersenne31, binary tower fields
- Extension field tower optimizations
- Montgomery vs Barrett reduction on different architectures
- NTT/FFT alternatives for small fields
- Karatsuba/Toom-Cook at field extension level

### 5. Parallelism and Hardware
- GPU proving: cuBabyBear, Icicle, metal-plonk
- FPGA proving architectures
- Memory-efficient proving (streaming, out-of-core)
- Proof composition and recursion for parallelism
- Pipeline parallelism vs data parallelism in proving

### 6. Protocol-Level Optimizations
- Proof aggregation and batching techniques
- Recursive proof composition (Nova, Supernova, HyperNova, ProtoGalaxy)
- Folding schemes
- CCS/R1CS/AIR/PLONKish — representation tradeoffs
- Customizable constraint systems

### 7. Verifier Optimization
- Proof size reduction techniques
- Verifier circuit-friendly constructions
- Succinct argument composition

### 8. Recent Breakthrough Claims (2024-2026)
- Search specifically for papers claiming >2x improvement over prior art
- Identify which claims have been reproduced/deployed vs remain theoretical
- Track the research-to-production pipeline: which ideas from 2022-2023 papers are
  now shipping in production systems?

## Search Strategy

1. Start with eprint.iacr.org — search for recent papers (2024-2026) on each category
2. Check proceedings: CRYPTO, EUROCRYPT, CCS, S&P, USENIX Security, TCC
3. Search for blog posts from: Polygon/Miden, Starkware, Succinct/SP1, RiscZero/Boundless,
   a16z/Jolt, Lita, Irreducible/Binius, Plonky3 team
4. Check GitHub repos of major proof systems for recently merged optimizations
5. Search arXiv cs.CR for "proof system" OR "sumcheck" OR "polynomial commitment" 2024-2026

## Quality Criteria

- **Prefer implemented over theoretical.** If a paper has a reference implementation or has
  been adopted by a production system, note it.
- **Note the field/curve assumptions.** Many optimizations only work for specific fields
  (e.g., binary towers, pairing-friendly curves). Flag incompatibilities with KoalaBear.
- **Distinguish prover vs verifier optimizations.** We care primarily about prover speed.
- **Flag security assumption changes.** Some "improvements" weaken security models.
- **Be skeptical of claimed speedups.** Note whether benchmarks are apples-to-apples.

## Process

Work through the categories systematically. For each:
1. Web search for recent papers and blog posts
2. Read abstracts and introductions (full paper if the idea seems high-relevance)
3. Extract the actionable idea into the index format
4. Assess relevance to our specific stack

Update `ideas_index.md` incrementally as you find ideas. Aim for **breadth first** —
cover all categories with at least 3-5 ideas each before going deep on any one.

After the full pass, add a **"Top 10 Most Actionable"** section at the top ranking ideas
by (estimated_impact × relevance_to_our_stack × implementation_feasibility).

## NEVER STOP
Continue researching until you've covered all 8 categories with meaningful depth.
Write the full index to ideas_index.md when done.
