# ZK Proof System — Actionable Ideas Index

> **Reference stack for relevance scoring:** KoalaBear (31-bit prime) base field, quartic
> extension for FS challenges, Poseidon1 hash, WHIR polynomial commitment (FRI variant),
> GKR-based sumcheck, Merkle tree commitments, XMSS hash-based signature aggregation
> prover (leanMultisig). Prover-side performance is the primary metric.

> **Status:** First-pass breadth survey. Top-10 ranking section follows the categories.

---

## Category 1: Hash Function Optimization

### Poseidon2 — Faster linear layers and reduced partial-round MDS
- **Source:** Grassi, Khovratovich, Schofnegger. *Poseidon2: A Faster Version of the Poseidon Hash Function*, AFRICACRYPT 2023. [eprint 2023/323](https://eprint.iacr.org/2023/323)
- **Core insight:** Replace Poseidon's MDS matrix in partial rounds with a much sparser
  diagonal-plus-one matrix; replace the full-round MDS with a 4×4 circulant matrix
  (M4 ⊗ I) that has the same diffusion as MDS but with far fewer multiplications. Net:
  ~2× faster native hashing and ~30% fewer constraints in arithmetic circuits.
- **Applicable to:** Merkle tree construction, Fiat-Shamir transcript, sponge-based
  commitment hashing across virtually any prime-field prover.
- **Estimated impact:** 2× native speedup over Poseidon1 at equal security. End-to-end
  prover impact in hash-heavy systems (e.g., XMSS aggregation, Merkle-heavy STARKs)
  often 20–40%.
- **Prerequisites:** Re-derive MDS/RC tables for the target field (BabyBear, KoalaBear,
  M31, Goldilocks all have published instantiations); re-audit cryptanalysis margins.
- **Conflicts with:** Existing Poseidon1 verification keys, on-chain verifiers, or
  hardcoded constants in deployed circuits.
- **Status in production:** Default in Plonky3, RISC Zero, Stwo, SP1, leanMultisig.
- **Relevance to our stack:** **HIGH.** We currently use Poseidon1 in leanMultisig.
  Migrating to Poseidon2 (KoalaBear-tuned) is a known win and is already the default
  in upstream Plonky3 components we depend on. Likely already partially deployed in
  the dependency tree — worth auditing whether *all* our hashing paths use Poseidon2.

### Monolith — x² S-box plus lookup-based bricks
- **Source:** Grassi, Khovratovich, Lüftenegger, Rechberger, Schofnegger, Walch.
  *Monolith: Circuit-Friendly Hash Functions with New Nonlinear Layers for Fast and
  Constant-Time Implementations*. [eprint 2023/1025](https://eprint.iacr.org/2023/1025)
- **Core insight:** Replace high-degree monomial S-box (x⁵ or x⁷) with x² plus a
  "Bricks" lookup-table-based nonlinear layer. Native execution drops dramatically
  (claimed fastest ZK-friendly hash) because x² is a single multiplication vs 4 for x⁷.
- **Applicable to:** Native hashing (Merkle tree leaves, transcript). Strong fit for
  small prime fields like Goldilocks/BabyBear.
- **Estimated impact:** Claimed 1.5–3× faster native than Poseidon2; circuit cost
  trades native speed for slightly more constraints due to lookup-based nonlinearity.
- **Prerequisites:** Need lookup-table support in the constraint system (cheap with
  LogUp/Lasso). Field-specific Bricks tables.
- **Conflicts with:** Pure non-lookup AIR systems pay a circuit-side penalty.
- **Status in production:** Used in Horizen Labs' systems; not yet default in Plonky3
  family.
- **Relevance to our stack:** **MEDIUM.** Native speedup attractive, but our hashing
  bottleneck is in proving over hash trees, not native hashing. Switching from Poseidon2
  → Monolith would only help leaves/Merkle if the AIR side's lookup machinery is mature.

### Skyscraper / Skyscraper-v2 — Big-prime hashing for SNARK-recursion verifiers
- **Source:** Ashur, Bhati, Dhooghe, Khovratovich, Pereira, Schofnegger, Walch.
  *Skyscraper: Fast Hashing on Big Primes*, TCHES 2025. [eprint 2025/058](https://eprint.iacr.org/2025/058)
- **Core insight:** For 256-bit primes (BLS12-381 scalar field), exploit structure of
  the prime to minimize modulo reductions; combine algebraic round with low-degree
  non-invertible "bar" function. Native ~135 ns / 2-to-1 hash on BLS12-381 scalar field
  (vs ~2 µs for Poseidon).
- **Applicable to:** The outer/wrap layer in stacked proof systems where a hash-based
  inner proof is recursed into a pairing-curve outer proof for on-chain verification.
- **Estimated impact:** >15× over Poseidon2 on big primes. Massive speedup for the
  recursive wrapping step.
- **Prerequisites:** A big-prime field on the outer layer (BN254, BLS12-381 Fr).
- **Conflicts with:** Pure small-field hash-only stacks gain nothing.
- **Status in production:** Deployed/being deployed in recursive wrap layers; Aztec,
  zkSync (Era) and Polygon are evaluating.
- **Relevance to our stack:** **LOW.** Our stack is hash-only over KoalaBear; we do not
  wrap into a pairing-curve SNARK. Becomes HIGH if a Groth16/Plonk wrap is ever added
  for L1 verification.

### MonolithGoldilocks / Tip5 / Rescue-Prime / Griffin — Catalog of sponge alternatives
- **Source:** *Tip5* (Szepieniec), [eprint 2023/107](https://eprint.iacr.org/2023/107);
  *Griffin* (Grassi et al.), [eprint 2022/403](https://eprint.iacr.org/2022/403);
  *Rescue-Prime* [eprint 2020/1143](https://eprint.iacr.org/2020/1143);
  *Anemoi* [eprint 2022/840](https://eprint.iacr.org/2022/840).
- **Core insight:** A family of design-space points trading native speed vs constraint
  count vs cryptanalysis margin. Rescue uses inverse S-box (asymmetric round equation
  reduces constraints); Anemoi uses Flystel construction; Griffin uses heterogeneous
  S-box arrangement.
- **Applicable to:** Different points on the design space — Tip5 was tailored to
  Goldilocks (Triton VM); Anemoi is among the lowest-constraint over BLS12-381 Fr;
  Griffin balances constraints and native speed.
- **Estimated impact:** 1.5×–3× variations on each axis; rarely a clear strict
  winner — depends on whether constraints or native speed dominates.
- **Prerequisites:** Each requires its own cryptanalysis evaluation in your specific
  field; Anemoi recently had cryptanalysis updates that tightened margins.
- **Conflicts with:** Standardization; switching hashes always costs interop and audit.
- **Status in production:** Tip5 in Triton VM; Rescue-Prime in old Polygon Miden; Anemoi
  in some pairing-curve SNARKs.
- **Relevance to our stack:** **LOW.** None is a clear win over Poseidon2 in our
  KoalaBear+native context. A specialty redesign over KoalaBear could outperform but
  would be a multi-month research effort.

### Poseidon2 compression mode for Merkle trees (vs sponge mode)
- **Source:** Poseidon2 paper [eprint 2023/323](https://eprint.iacr.org/2023/323);
  Plonky3 `poseidon2-compression` discussion.
- **Core insight:** For 2-to-1 Merkle compression, use Poseidon2 in fixed-input
  compression mode (one permutation, take first half of output) instead of sponge
  mode (which pads, absorbs, squeezes). Saves the padding/squeezing overhead and
  is cryptanalytically equivalent for fixed input.
- **Applicable to:** All Merkle tree internal nodes; large fraction of FRI/WHIR
  hashing.
- **Estimated impact:** ~1.5–2× over sponge mode for Merkle internal hashing.
- **Prerequisites:** Permutation must support the chosen state width (Poseidon2-WIDTH=16
  for two leaves of width 8).
- **Conflicts with:** Generic sponge-mode codepaths.
- **Status in production:** Default in Plonky3; probably already in our stack.
- **Relevance to our stack:** **HIGH — likely already adopted.** Audit confirms.

### Vision-Mark32 / Tip4'-Lite — KoalaBear-native designs
- **Source:** Vision-Mark32 [eprint 2023/1454](https://eprint.iacr.org/2023/1454)
  and follow-ups; community discussion on KoalaBear-tuned variants in Plonky3 issues.
- **Core insight:** Hash designs tuned to a specific field's exponent structure
  (KoalaBear is 2^31 − 2^24 + 1; gcd(α, p−1)=1 for α∈{3,5,7,9,…}). Mark32's design
  goal is shortest CPU latency for the target field's modular reduction.
- **Applicable to:** The native hashing kernel — leaves, intermediate nodes, transcript.
- **Estimated impact:** 10–30% over generic Poseidon2-KoalaBear; not transformative.
- **Prerequisites:** Custom round constants and MDS for KoalaBear; cryptanalysis review.
- **Conflicts with:** Algebraic simplicity / formal-verification of canonical Poseidon.
- **Status in production:** Not yet adopted; Plonky3 retains Poseidon2 as default.
- **Relevance to our stack:** **MEDIUM.** Worth a focused experiment if hashing is
  >25% of our wall-clock; requires confidence that we won't be rebuilding Poseidon
  poorly (cf. Principle #10).

---

## Category 2: Polynomial Commitment Schemes

### WHIR — Sub-millisecond verifier with optimal proximity testing
- **Source:** Arnon, Chiesa, Fenzi, Yogev. *WHIR: Reed–Solomon Proximity Testing with
  Super-Fast Verification*, EUROCRYPT 2025. [eprint 2024/1586](https://eprint.iacr.org/2024/1586)
- **Core insight:** Constrain the codeword space (weights to enforce proximity to a
  *constrained* RS code), letting the verifier do dramatically fewer checks while
  preserving the same prover-time profile as FRI. Verifier ~1.0 ms vs FRI 3.9 ms / STIR
  3.8 ms at 100-bit security. Doubles as a multilinear PCS by merging in-domain and
  out-of-domain queries into a single sumcheck step.
- **Applicable to:** Polynomial commitment in any FRI-based STARK / IOP. Direct drop-in
  replacement for FRI in many systems.
- **Estimated impact:** 3–4× verifier speedup; modest prover-side savings (5–20% over
  FRI at similar parameters); larger proofs than STIR but smaller than FRI.
- **Prerequisites:** RS-code-friendly field (any with a power-of-2 multiplicative
  subgroup OR Circle-FRI-style adaptation for M31).
- **Conflicts with:** Mature FRI implementations have heavy investment; switching costs
  audit time.
- **Status in production:** Used by Whirlaway (LambdaClass), being adopted in leanMultisig,
  Lean Ethereum cryptographic stack.
- **Relevance to our stack:** **HIGH — already adopted.** WHIR is our PCS. Read this
  entry as "stay current with WHIR upstream optimizations." Watch for Whir-PCS-with-skip,
  out-of-domain query batching, and GPU-friendly Merkle layout improvements.

### STIR — Tradeoff: smaller proofs at moderate verifier cost
- **Source:** Arnon, Chiesa, Fenzi, Yogev. *STIR: Reed–Solomon Proximity Testing with
  Fewer Queries*. [eprint 2024/390](https://eprint.iacr.org/2024/390)
- **Core insight:** Each round halves the rate but reduces the number of queries
  per round substantially, yielding shorter proofs than FRI at the same security.
  Predecessor of WHIR but with a different optimization target (proof size).
- **Applicable to:** Same drop-in slot as FRI/WHIR.
- **Estimated impact:** 1.5–2× smaller proofs vs FRI; verifier somewhat slower than WHIR.
- **Prerequisites:** Same as FRI.
- **Conflicts with:** WHIR strictly dominates STIR for verifier time; STIR wins on
  proof size.
- **Status in production:** Used in some research prototypes; mostly superseded by WHIR.
- **Relevance to our stack:** **LOW.** WHIR already chosen; if proof size becomes a
  binding constraint (e.g., gossip-bandwidth-limited slots), revisit.

### BaseFold — Field-agnostic foldable code commitment
- **Source:** Zeilberger, Chen, Fisch. *BaseFold: Efficient Field-Agnostic Polynomial
  Commitment Schemes from Foldable Codes*, CRYPTO 2024. [eprint 2023/1705](https://eprint.iacr.org/2023/1705)
- **Core insight:** Generalizes FRI to "foldable codes" that don't need a multiplicative
  smooth subgroup — works over arbitrary fields including non-FFT-friendly ones.
  Provides a multilinear PCS directly (no sumcheck wrapping needed) at competitive
  prover cost.
- **Applicable to:** Multilinear-IOP provers (sumcheck-based) over any field — including
  fields where NTT is awkward (e.g., non-smooth primes).
- **Estimated impact:** Comparable to FRI for prover; better than FRI for proof size
  in multilinear setting; opens up small fields without smooth FFT subgroups.
- **Prerequisites:** Pre-computed encoding matrices for the chosen foldable code.
- **Conflicts with:** WHIR has caught up on verifier time, so the relative advantage
  has narrowed.
- **Status in production:** Several research prototypes; not yet a default in
  major production zkVMs.
- **Relevance to our stack:** **LOW–MEDIUM.** WHIR already covers our use case;
  BaseFold is most interesting if we ever switched fields or if a hybrid code that
  outperforms RS becomes attractive.

### DeepFold — RS-code multilinear PCS at list-decoding radius
- **Source:** Guo, Liu, Tang, Xu. *DeepFold: Efficient Multilinear Polynomial Commitment
  from Reed-Solomon Code*, USENIX Security 2025. [eprint 2024/1595](https://eprint.iacr.org/2024/1595)
- **Core insight:** Operates at the *list*-decoding radius rather than unique decoding,
  allowing more aggressive parameter choices. Achieves ~3× smaller proofs than BaseFold
  with similar prover time.
- **Applicable to:** Multilinear PCS slot in sumcheck-based provers.
- **Estimated impact:** 3× proof-size reduction over BaseFold; prover cost similar.
- **Prerequisites:** RS code over an FFT-friendly field; conjectured (not proven)
  soundness up to list-decoding radius — accepts the standard FRI conjecture.
- **Conflicts with:** Slightly weaker security model (relies on conjecture); WHIR is
  proven.
- **Status in production:** Research stage; published USENIX Security 2025.
- **Relevance to our stack:** **LOW.** WHIR is our default; DeepFold's win is proof
  size, not what we're optimizing for.

### Brakedown / Orion / Blaze — Linear-code "tensor-IOP" commitments
- **Source:** *Brakedown* (Golovnev, Lee, Setty, Thaler, Wahby), [eprint 2021/1043](https://eprint.iacr.org/2021/1043);
  *Orion* (Xie, Zhang, Song), [eprint 2022/1010](https://eprint.iacr.org/2022/1010);
  *Blaze* (Brehm, Chen, Fisch, et al.), EUROCRYPT 2025, [eprint 2024/1609](https://eprint.iacr.org/2024/1609).
- **Core insight:** Commit to a polynomial as a tensor; encode rows with a linear-time
  encodable code; prove evaluation via a linear-combination check. Brakedown is
  field-agnostic, hash-only, fastest known prover. Orion improves with explicit
  expander codes. Blaze uses *Interleaved RAA Codes* for substantially smaller proofs
  than Brakedown while keeping linear-time encoding.
- **Applicable to:** PCS slot in any sumcheck-based prover where prover time is the
  primary objective and proof size can be amortized via a recursive wrap.
- **Estimated impact:** 2–10× faster prover than FRI/WHIR (especially at large
  instance sizes); proofs are large (Brakedown: ~10 MB at billion-gate scale; Blaze
  considerably smaller).
- **Prerequisites:** No FFT needed; works over any field. Need expander code parameters
  with proven distance for chosen security level.
- **Conflicts with:** Verifier time is sub-linear but proof size is large; usually
  needs a recursive wrap for production deployment.
- **Status in production:** Lasso/Jolt evaluated Brakedown internally; not yet in mainnet
  zkVMs.
- **Relevance to our stack:** **MEDIUM.** Could be a faster prover option for the
  multisig aggregation use case if proof size gossip is acceptable. Worth a
  bench experiment in the leanMultisig framework — specifically Blaze on KoalaBear.

### zip — Removing duplicate hashes in multi-point Merkle openings
- **Source:** Fenzi, Chiesa, et al. *zip: Reducing Proof Sizes for Hash-Based SNARGs*.
  [eprint 2025/1446](https://eprint.iacr.org/2025/1446)
- **Core insight:** When a FRI/WHIR query phase opens a Merkle tree at t locations,
  the standard transcript repeats sibling hashes at every shared ancestor. zip
  removes those duplicates, dropping argument size from roughly λ·t·log n to
  λ·t·(log n − log t) — meaningful when t is in the hundreds.
- **Applicable to:** Argument-size optimization for any hash-based SNARG with multi-point
  Merkle openings (FRI, WHIR, BaseFold, DeepFold).
- **Estimated impact:** 10–30% argument-size reduction at typical FRI parameters; pure
  encoding optimization, no security impact.
- **Prerequisites:** Verifier must follow the new opening protocol; trivial code change
  on both sides.
- **Conflicts with:** Existing fixed-format proof transcripts.
- **Status in production:** New (2025); not yet adopted in major provers.
- **Relevance to our stack:** **HIGH.** Free proof-size reduction for our WHIR-based
  protocol. Cheap to implement; worth a localized experiment in whir-p3.

### FRI soundness above Johnson bound via threshold halving
- **Source:** *FRI Soundness Above the Johnson Bound via Threshold Halving*.
  [eprint 2026/858](https://eprint.iacr.org/2026/858)
- **Core insight:** Replaces the conjectural soundness baseline that current FRI/WHIR
  deployments assume (FRI security beyond the Johnson bound) with a theorem. Lets
  operators reduce query repetition counts safely, since the soundness analysis is
  tighter.
- **Applicable to:** All hash-based SNARK provers using FRI/WHIR (SP1, RISC Zero,
  Plonky3, Stwo, leanMultisig).
- **Estimated impact:** Smaller query parameters → fewer Merkle openings, smaller
  proofs, less wrapper-verifier work. ~10–25% argument-size reduction at the same
  security level.
- **Prerequisites:** Re-derive query counts from the new theorem; update verifier.
- **Conflicts with:** Audited deployments where any parameter change is expensive.
- **Status in production:** Very recent (early 2026); EthProofs slate operators
  evaluating.
- **Relevance to our stack:** **HIGH.** Direct soundness improvement, no algorithmic
  change to the prover; just smaller parameters. Track for adoption upstream.

### Distributed / Fold-and-Batch FRI
- **Source:** *A FRI-based Polynomial Commitment Scheme for Distributed Proving*.
  [eprint 2025/1285](https://eprint.iacr.org/2025/1285); *Shred-to-Shine
  Metamorphosis of (Distributed) Polynomial Commitments*. [eprint 2025/1354](https://eprint.iacr.org/2025/1354).
- **Core insight:** Distribute FRI commit-phase work across worker nodes, each folding
  its local polynomial chunk before shipping a small intermediate to the master node.
  Reduces both per-worker runtime and inter-node communication compared to naïve
  shard-then-combine.
- **Applicable to:** Multi-machine prover deployments with shardable polynomial
  workloads.
- **Estimated impact:** Near-linear scaling with worker count for FRI-bound provers;
  communication cost scales sub-linearly.
- **Prerequisites:** Multi-node infrastructure; coordinated random beacon for FRI
  challenges.
- **Conflicts with:** Single-machine deployments.
- **Status in production:** Research; implementation work in progress at several
  cloud-prover teams.
- **Relevance to our stack:** **MEDIUM.** Becomes HIGH if leanMultisig is ever
  deployed across multiple prover machines. The Fold-and-Batch communication pattern
  is the right reference design.

### Merkle leaf packing — Pack multi-polynomial evaluations into a single leaf
- **Source:** Folkloric; explicitly described in [On amortization techniques for
  FRI-based SNARKs (eprint 2024/661)](https://eprint.iacr.org/2024/661); used by
  Plonky3's [Field Merkle Tree](https://hackmd.io/@0xKanekiKen/H1ww-qWKa).
- **Core insight:** When committing to multiple polynomials evaluated on the same
  domain, pack their evaluations into a single Merkle leaf and open one tree instead
  of N. Saves N−1 Merkle inclusion proofs per FRI query.
- **Applicable to:** First-round commitment in multi-polynomial FRI/WHIR.
- **Estimated impact:** Proof-size reduction proportional to N; commit-phase hashing
  reduction proportional to N at the leaf level.
- **Prerequisites:** All polynomials share the same evaluation domain (typical).
- **Conflicts with:** Polynomials with different domain sizes (use jagged variant).
- **Status in production:** Plonky3 / leanMultisig (default).
- **Relevance to our stack:** **HIGH — already adopted via Plonky3's MMCS.** Audit
  that we're using the packed leaf format end-to-end.

### Binius / FRI-Binius — Towers-of-binary-fields commitments
- **Source:** Diamond, Posen. *Succinct Arguments over Towers of Binary Fields*, [eprint 2023/1784](https://eprint.iacr.org/2023/1784)
  and *FRI-Binius: Improved Polynomial Commitments for Binary Towers* (Irreducible blog).
- **Core insight:** Use binary tower fields (Wiedemann construction) where addition is XOR
  and multiplication has hardware-friendly structure. Bit-level operations natively map
  to small subfields — the prover commits to and operates on actual bit-typed data
  without the small-into-large embedding overhead inherent in 31-bit prime fields.
- **Applicable to:** Hardware-target provers where a bit-oriented program exists
  (zkVMs over RISC-V, hashing inner workings, EVM).
- **Estimated impact:** Substantial for bit-heavy workloads (XOR, AND, shift); similar
  or worse for arithmetic-heavy workloads. Hardware (FPGA/ASIC) very favorable.
- **Prerequisites:** Re-architect entire stack around binary tower fields; not a
  drop-in replacement.
- **Conflicts with:** Existing prime-field IR / circuits / lookup tables; community
  expertise; cryptanalysis.
- **Status in production:** Irreducible's Binius / Binius64 (released early 2025);
  not in Plonky3 family.
- **Relevance to our stack:** **LOW.** A full-system bet, not a local optimization.
  Worth understanding to track competitive pressure but not actionable in our
  current framework.

### Zeromorph / HyperKZG — Multilinear over pairing-curve KZG
- **Source:** *Zeromorph* (Kohrita, Towa), [eprint 2023/917](https://eprint.iacr.org/2023/917);
  *HyperKZG* (Setty, Angel, Gupta), in Spartan & Nova literature.
- **Core insight:** Adapt univariate KZG to evaluate multilinear polynomials directly,
  avoiding the boolean-hypercube → univariate transformation cost.
- **Applicable to:** Pairing-curve provers (BN254, BLS12-381) using multilinear IOPs.
- **Estimated impact:** 2× over univariate-KZG-with-hypercube-encoding; constant proof
  size in field elements.
- **Prerequisites:** Trusted setup; pairing-friendly curve.
- **Conflicts with:** Hash-only/post-quantum requirements; transparent setup.
- **Status in production:** Used in Lasso/Jolt's first version; HyperPlonk variants.
- **Relevance to our stack:** **LOW.** Incompatible with our post-quantum / no-setup
  requirement.

---

## Category 3: Sumcheck and Interactive Proofs

### Univariate skip (Gruen) — Fuse boolean variables into a higher-degree variable
- **Source:** Gruen. *Some Improvements for the PIOP for ZeroCheck*. [eprint 2024/108](https://eprint.iacr.org/2024/108)
- **Core insight:** When sumcheck inputs come from a small base field but the protocol
  runs over a large extension, "skip" several boolean variables by merging them into
  one higher-degree variable. The prover operates in the base field for those variables
  rather than in the extension.
- **Applicable to:** Any sumcheck or zero-check over an extension of a small field —
  GKR, HyperPlonk, Lasso, leanMultisig.
- **Estimated impact:** 2–4× sumcheck prover speedup when base-field operands dominate.
- **Prerequisites:** Inputs structured as base-field values lifted to the extension.
- **Conflicts with:** Designs that intentionally randomize input domain to the extension.
- **Status in production:** Adopted in Plonky3 sumcheck implementation, Stwo,
  leanMultisig. Standard technique now.
- **Relevance to our stack:** **HIGH — already adopted.** Verify our implementation
  uses univariate skip across all sumcheck instances; track upstream optimizations.

### Bagad–Dao–Domb–Thaler — eq-polynomial small-value sumcheck (Spartan first round)
- **Source:** Bagad, Dao, Domb, Thaler. *Speeding Up Sum-Check Proving*.
  [eprint 2025/1117](https://eprint.iacr.org/2025/1117) (extended version
  [eprint 2026/587](https://eprint.iacr.org/2026/587)). Combines and supersedes
  2024/1046 and 2024/1210.
- **Core insight:** For the canonical Spartan-style sumcheck of `eq(r, x) · p(x)`,
  exploit two structures simultaneously: (1) p evaluations are typically small
  (32-bit ints) so most work can stay in the base field, (2) eq has multiplicative
  factorization that lets you precompute incrementally. Reports 2–3× consistent
  speedup, up to 20× when the baseline approaches RAM limits.
- **Applicable to:** Spartan-style sumcheck, GKR, any `eq(r, ·) · f(·)` summation.
- **Estimated impact:** 2–3× sumcheck-prover speedup; 20× in memory-bound regimes.
- **Prerequisites:** Polynomial values are in base field or small subfield.
- **Conflicts with:** Sumchecks where every value is a uniform extension-field element.
- **Status in production:** Being integrated in Jolt / Plonky3 sumcheck drivers.
- **Relevance to our stack:** **HIGH.** Strongly applicable; likely the single
  biggest sumcheck-prover algorithmic win available right now. Verify our
  sumcheck implementation has both optimizations.

### Dao–Thaler additional optimizations — Toom-Cook product folding for sumcheck
- **Source:** Dao, Thaler. *More Optimizations to Sum-Check Proving*. [eprint 2024/1210](https://eprint.iacr.org/2024/1210);
  extended at [Speeding Up Sum-Check Proving (eprint 2025/1117)](https://eprint.iacr.org/2025/1117).
- **Core insight:** Standard sumcheck rounds compute a polynomial as point evaluations;
  Dao–Thaler observe that for product-of-multilinears (the typical structure), the
  univariate polynomial computed each round can be evaluated more efficiently via
  Toom-Cook-style point-folding. Saves ~2n+1 multiplications per round on top of Gruen.
- **Applicable to:** Generic sumcheck on products of multilinears (most GKR-like protocols).
- **Estimated impact:** 10–25% prover speedup for sumcheck stages; multiplicative on
  top of univariate skip and small-field optimizations.
- **Prerequisites:** None beyond the standard sumcheck structure.
- **Conflicts with:** Custom sumcheck variants (e.g., fractional-LogUp) need re-derivation.
- **Status in production:** Being added to Plonky3 / Lasso; mention in Jolt 6× speedup
  blog.
- **Relevance to our stack:** **HIGH.** Direct, drop-in algorithmic improvement to our
  sumcheck prover. Should be evaluated for inclusion if not already there.

### Bagad–Domb–Thaler — Sumcheck over fields of small characteristic
- **Source:** Bagad, Domb, Thaler. *The Sum-Check Protocol over Fields of Small
  Characteristic*. [eprint 2024/1046](https://eprint.iacr.org/2024/1046)
- **Core insight:** When sumcheck operates over an extension of a small-characteristic
  base field (esp. binary towers), keep most prover multiplications in the base field
  by exploiting linearity and Frobenius-like structure. Reduces number of expensive
  extension-field multiplications by orders of magnitude when polynomial evaluations
  lie in the base field.
- **Applicable to:** Binary tower provers (Binius); also useful for small-characteristic
  prime fields under structural conditions.
- **Estimated impact:** Multiple-orders-of-magnitude reduction in extension-field
  multiplications when applicable; smaller speedup when not.
- **Prerequisites:** Small-characteristic base field where extension multiplications
  are substantially more expensive than base.
- **Conflicts with:** KoalaBear is *not* small characteristic — its characteristic is
  the prime itself (~2^31). So this technique mainly applies to binary towers in our
  comparator set.
- **Status in production:** Binius prover.
- **Relevance to our stack:** **LOW (direct), HIGH (analog).** The *direct* technique
  doesn't apply to KoalaBear, but the *principle* (keep prover work in base field
  whenever possible) is identical to univariate-skip and other small-prime techniques
  we already use.

### Packed sumcheck / Packed ZeroCheck — SIMD-friendly sumcheck rounds
- **Source:** Bagad, Soukhanov, et al. *Packed Sumcheck over Fields of Small
  Characteristic*. [eprint 2025/719](https://eprint.iacr.org/2025/719)
- **Core insight:** Pack multiple base-field elements into a single SIMD register and
  process several sumcheck rounds in parallel via SIMD vector operations. Generalizes
  to packed ZeroCheck with the same asymptotic complexity.
- **Applicable to:** Sumcheck/ZeroCheck implementations targeting modern CPUs with
  AVX-512 / NEON / SVE.
- **Estimated impact:** Up to vector-width speedup (4–16×) on the inner loop, but
  end-to-end gain depends on what fraction of prover time is in sumcheck.
- **Prerequisites:** Vectorizable field arithmetic (already true for KoalaBear in
  Plonky3 with packed-field implementations).
- **Conflicts with:** Round structures that intermix scalar control flow with
  vectorizable bulk work.
- **Status in production:** Reference impl in Binius; being explored in Plonky3 packed
  field crates.
- **Relevance to our stack:** **HIGH.** KoalaBear already has packed-field
  implementations in Plonky3; explicitly using a packed-sumcheck driver should
  produce measurable speedup. Worth benching.

### Lasso — Lookup arguments via sparse-MLE sumcheck
- **Source:** Setty, Thaler, Wahby. *Unlocking the Lookup Singularity with Lasso*. [eprint 2023/1216](https://eprint.iacr.org/2023/1216)
- **Core insight:** Replace dedicated lookup arguments with a sumcheck on the sparse
  multilinear extension of the lookup table; only commit to multiplicities. Tables of
  enormous size (up to 2^128) become tractable when they have MLE-structure (e.g.,
  bitwise ops, range checks).
- **Applicable to:** Range checks, bitwise operations, byte decomposition — anywhere
  lookup tables are used.
- **Estimated impact:** Roughly equal proving cost to LogUp for unstructured tables;
  asymptotically better for structured tables; opens up much larger tables.
- **Prerequisites:** Tables must be expressible as MLEs with low evaluation cost
  (decomposable or structured).
- **Conflicts with:** Existing LogUp-GKR setups; tables that are inherently random.
- **Status in production:** Jolt zkVM (production).
- **Relevance to our stack:** **MEDIUM.** Our stack uses LogUp-style. If we add
  range-check or bit-op heavy precompiles in leanMultisig, Lasso could win. For pure
  hash aggregation, LogUp is sufficient.

### LogUp-GKR — GKR-batched logarithmic-derivative lookups
- **Source:** Haböck, Levit, Papini. *Improving Logarithmic Derivative Lookups Using
  GKR*. [eprint 2023/1284](https://eprint.iacr.org/2023/1284)
- **Core insight:** The expensive part of LogUp is the fractional-sumcheck on
  Σ m_i / (X − t_i). Wrap that in a GKR layer to amortize across columns and reduce
  commitment cost.
- **Applicable to:** Any prover with multiple lookup-using columns.
- **Estimated impact:** 2–5× lookup-overhead reduction at moderate-to-large column
  counts.
- **Prerequisites:** GKR sumcheck infrastructure.
- **Conflicts with:** Single-column or very-small lookup workloads.
- **Status in production:** Plonky3, Stwo, leanMultisig.
- **Relevance to our stack:** **HIGH — already adopted.** Standard for us.

### Logup* — Faster LogUp for small indexed tables
- **Source:** Soukhanov. *Logup\*: faster, cheaper logup argument for small-table
  indexed lookups*. [eprint 2025/946](https://eprint.iacr.org/2025/946)
- **Core insight:** For lookups into a single-column public table, the prover only needs
  to commit to *multiplicities*; everything else is derived. Removes per-lookup-call
  commitment overhead.
- **Applicable to:** Small public tables (e.g., 8-bit or 16-bit indexed lookups).
- **Estimated impact:** 2–4× cheaper per small-table lookup.
- **Prerequisites:** Public, indexed table layout; LogUp-GKR substrate.
- **Conflicts with:** Multi-column or witness-dependent tables.
- **Status in production:** Recently published; not yet widespread.
- **Relevance to our stack:** **MEDIUM.** If our zkVM uses small public tables for
  byte ops, this is a localized but easy win.

### Twist & Shout — Sparse-vector memory checking
- **Source:** Setty, Thaler, et al. *Twist and Shout: Faster Memory Checking
  Arguments via One-Hot Addressing and Increments*. [eprint 2025/105](https://eprint.iacr.org/2025/105)
- **Core insight:** Reformulate memory checking by committing to a very large but
  sparse "one-hot" vector of memory accesses. Sumcheck pays only for non-zero
  elements. Eliminates the need to decompose ops into smaller subtables in Lasso/Jolt.
- **Applicable to:** zkVM memory model (read/write checking).
- **Estimated impact:** >10× over prior offline-memory-checking approaches; central
  contributor to Jolt's 6× overall speedup.
- **Prerequisites:** A sparse-vector commitment scheme. Sumcheck-based prover.
- **Conflicts with:** Stateless protocols; non-zkVM applications.
- **Status in production:** Jolt mainline (2025).
- **Relevance to our stack:** **MEDIUM.** leanMultisig has a memory model (zkVM-style);
  if memory checking shows up as a non-trivial fraction of prove time, Twist & Shout is
  the modern answer. For pure XMSS aggregation, less critical.

### Dot-product MLE evaluation (Vu et al.) — Streaming MLE eval
- **Source:** Vu, Setty, Blumberg, Walfish. (Original Allspice / Pantry literature; see
  also *Spartan*: Setty, [eprint 2019/550](https://eprint.iacr.org/2019/550).)
- **Core insight:** Evaluate a multilinear extension at a point r in O(2^n) field ops
  using a single dot-product-like pass over the MLE evaluations, rather than O(n·2^n)
  recursive folding.
- **Applicable to:** Anywhere an MLE is evaluated at a verifier challenge point.
- **Estimated impact:** Linear-factor (n) reduction at this step, but the step is rarely
  bottleneck. ~5–10% end-to-end.
- **Prerequisites:** None.
- **Conflicts with:** Streaming-only or memory-constrained provers.
- **Status in production:** Standard.
- **Relevance to our stack:** **HIGH — already adopted.** Standard.

---

## Category 4: Field Arithmetic and Algebraic Techniques

### KoalaBear / BabyBear / M31 — Native-word small primes
- **Source:** Plonky3 koala-bear, baby-bear, mersenne-31 crates; design lineage from
  RISC Zero (BabyBear) and Stwo (Mersenne31).
- **Core insight:** Pick a prime ≤ 2^31 such that (a) reduction is one or two cheap
  ops (subtract, conditional add), (b) it has a smooth multiplicative subgroup for
  NTT, and (c) it has the security headroom to support a quartic/quintic extension
  giving ≥120-bit FS soundness.
- **Applicable to:** Any prover where field-mul throughput is the bottleneck.
- **Estimated impact:** 4× over BLS12-381 Fr-style 256-bit primes; AVX-512 packs 16
  field elements per vector reg.
- **Prerequisites:** Re-tune everything (hash, lookup tables, MDS) to the field.
- **Conflicts with:** Pairing-friendly recursion.
- **Status in production:** Plonky3 (BabyBear/KoalaBear), Stwo (M31), SP1 (BabyBear),
  RISC Zero (BabyBear). leanMultisig: KoalaBear.
- **Relevance to our stack:** **HIGH — already adopted.** Stay aware of the design
  tradeoffs (KoalaBear vs M31 in particular: M31 has Circle-FFT advantage; KoalaBear
  has standard NTT).

### Delayed reduction — Defer modular reduction across batched additions / dot products
- **Source:** Plonky3 [issue #252](https://github.com/Plonky3/Plonky3/issues/252);
  technique from classical NTT literature (Montgomery, Solinas, Lyubashevsky).
- **Core insight:** Field operations like `Σ a_i · b_i` can accumulate in a wider
  integer (u64 or u128) before performing one reduction at the end, instead of
  reducing after each multiply. Critical for AVX-512 / NEON throughput.
- **Applicable to:** Inner products (NTT butterflies, MDS application, sumcheck round
  coefficient computation).
- **Estimated impact:** 2–3× over naïve reduce-each-op on AVX-512; the difference
  between getting AVX-512 utilization and not.
- **Prerequisites:** Headroom in accumulator type (e.g., u64 holds many 31-bit muls
  before overflow); careful overflow analysis per use site.
- **Conflicts with:** Code clarity — these inner loops become unreadable.
- **Status in production:** Plonky3 packed-field (M31, BabyBear, KoalaBear) inner
  loops use it; Stwo as well.
- **Relevance to our stack:** **HIGH — already adopted in deps.** Confirm our hot
  paths (sumcheck round, MDS inside Poseidon2) inherit this; if we wrote any custom
  inner loops, they should use the same pattern.

### Quartic extension fields with sparse irreducible polynomial
- **Source:** Plonky3 KoalaBear / BabyBear quartic extension crate; Stwo quartic
  M31 extension.
- **Core insight:** Pick a quartic extension X^4 − w with w small (e.g., 11 for KoalaBear)
  so that multiplication uses Karatsuba-like reduction with only a few multiplications
  by w. The choice of w changes performance but not security.
- **Applicable to:** All Fiat-Shamir challenges over the extension; final claim
  evaluation in extension.
- **Estimated impact:** 30–50% over generic quartic extensions; not transformative but
  dependable.
- **Prerequisites:** w must be a quadratic non-residue to ensure irreducibility.
- **Conflicts with:** Algebraic uniformity across fields (each field needs its own w).
- **Status in production:** Plonky3, Stwo.
- **Relevance to our stack:** **HIGH — already adopted.** Standard.

### Plonky3 packed fields — AVX-512 / NEON / SVE field-element packing
- **Source:** Plonky3 mersenne-31, baby-bear, koala-bear `packing` modules;
  [Small Fields in Plonky3](https://hackmd.io/@Syxton/small_fields_in_plonky3).
- **Core insight:** Define an abstract `PackedField` trait that holds a SIMD register
  worth of field elements, with vectorized add / mul / reduce primitives. Algorithms
  that operate generically on `PackedField` get AVX-512 (16 lanes for 31-bit fields),
  NEON (4 lanes), or SVE for free.
- **Applicable to:** Any inner loop that processes independent field elements (NTT,
  MDS, sumcheck round-poly evaluation).
- **Estimated impact:** Up to lane-count speedup (16× on AVX-512 for 31-bit fields).
  Realized: typically 4–10× on real workloads.
- **Prerequisites:** Generic PackedField-aware code paths; CPU with target ISA.
- **Conflicts with:** Branchy / divergent code; very small instances where setup cost
  dominates.
- **Status in production:** Plonky3 / Stwo / SP1 / leanMultisig.
- **Relevance to our stack:** **HIGH — already adopted.** Confirm RUSTFLAGS includes
  `-C target-cpu=native` everywhere (see CLAUDE.md note: forgetting this silently 2×
  slows benchmarks).

### Circle group on M31 — Replace multiplicative subgroup with circle
- **Source:** Habök, Haböck, Levit, Papini, et al. *Circle STARKs* (2024);
  Vitalik blog [exploring circle STARKs](https://vitalik.eth.limo/general/2024/07/23/circlestarks.html).
- **Core insight:** M31 = 2^31 − 1 has no large smooth multiplicative subgroup (p−1 has
  small odd factors). Instead, use the unit circle x²+y²=1 over M31, which has 2^31
  points and a nice 2-adic structure. Enables FFT-like algorithms ("Circle FFT") and
  FRI-like proximity testing.
- **Applicable to:** Any prover wanting Mersenne31 instead of Solinas-prime fields.
- **Estimated impact:** Enables the entire M31 ecosystem (Stwo, etc.); not directly an
  optimization within KoalaBear stacks.
- **Prerequisites:** Pick M31 specifically.
- **Conflicts with:** KoalaBear / BabyBear use standard NTT on multiplicative subgroup.
- **Status in production:** Stwo, Starkware.
- **Relevance to our stack:** **LOW.** We're committed to KoalaBear. Circle STARK is a
  parallel-universe choice rather than an addition to our stack.

### Karatsuba/Toom-Cook in extension multiplication
- **Source:** Classical (Karatsuba 1962); Toom-Cook generalizations; applied throughout
  modern PCS implementations.
- **Core insight:** Multiplying two degree-n extension polynomials with Karatsuba uses
  ~3 base mults (vs 4 schoolbook); Toom-3 uses 5 (vs 9); etc. Cumulative across the
  prover.
- **Applicable to:** Extension-field multiplication in challenges, in Fiat-Shamir
  sponge state.
- **Estimated impact:** ~25% over schoolbook for quartic extensions.
- **Prerequisites:** None.
- **Conflicts with:** None.
- **Status in production:** Plonky3, all serious provers.
- **Relevance to our stack:** **HIGH — already adopted.** Standard.

### Montgomery vs Solinas/canonical reduction
- **Source:** Plonky3 issue threads; Lemire, Granlund classical references.
- **Core insight:** For Solinas-friendly primes (KoalaBear's structure), direct
  reduction (subtract one or two times) is faster than Montgomery, because Montgomery
  pays a multiplication. Use Solinas reduction at the SIMD level.
- **Applicable to:** Hot-path field-mul + reduction.
- **Estimated impact:** 1.5–2× over Montgomery for small primes; less for large primes.
- **Prerequisites:** Prime structure must be Solinas-friendly.
- **Conflicts with:** Generic-field code that uses Montgomery uniformly.
- **Status in production:** Plonky3, Stwo.
- **Relevance to our stack:** **HIGH — already adopted.** Standard.

---

## Category 5: Parallelism and Hardware

### ICICLE — CUDA library with BabyBear / KoalaBear / M31 support
- **Source:** Ingonyama, [GitHub](https://github.com/ingonyama-zk/icicle); blog series
  [ICICLE-Stwo](https://medium.com/@ingonyama/introducing-icicle-stwo-a-gpu-accelerated-stwo-prover-550b413d4f88),
  [ICICLE-Halo2 v2](https://www.ingonyama.com/post/2-fast-2-furious-icicle-halo2-v2).
- **Core insight:** GPU-accelerated MSM, NTT, polynomial arith, hashing, Merkle tree
  build, FRI commit/query. Field-generic backend supports small fields.
- **Applicable to:** Drop-in for the largest hot-path kernels in any STARK/SNARK
  prover with GPU available.
- **Estimated impact:** ICICLE-Stwo reports 3.25–7× over heavily-optimized SIMD CPU
  backends. NTT and Merkle-build typically see 5–10×.
- **Prerequisites:** NVIDIA GPU; CUDA toolchain; per-field bindings.
- **Conflicts with:** CPU-only deployment targets; AMD/Apple GPU stacks (separate effort).
- **Status in production:** Used by Kroma (SP1), Polygon, Aleo zkSNARK acceleration.
- **Relevance to our stack:** **HIGH if we ever target GPUs.** leanMultisig is CPU-bound
  on Hetzner. If we add a GPU node, ICICLE-KoalaBear is the obvious starting point.
  Currently MEDIUM in priority because we're CPU-only.

### NVRTC runtime CUDA compilation (Lita)
- **Source:** Lita Foundation, [NVRTC blog](https://www.lita.foundation/blog/nvrtc-cuda-poc-building-a-gpu-prover-with-runtime-compilation).
- **Core insight:** Generate specialized CUDA kernels per circuit at runtime via
  NVRTC, instead of generic kernels. The constraint shape becomes a compile-time
  constant, enabling aggressive constant folding and register allocation.
- **Applicable to:** Provers where constraint structure is repeated and known
  (most precompiles).
- **Estimated impact:** Claimed 2× over hand-tuned generic kernels; depends on
  constraint shape.
- **Prerequisites:** NVRTC; willingness to JIT-compile at deploy time.
- **Conflicts with:** Cold-start latency (kernel compile ~seconds); deployment
  toolchain complexity.
- **Status in production:** Lita prover.
- **Relevance to our stack:** **LOW.** Specialized; we don't have a GPU prover yet.

### Streaming / out-of-core proving — Memory-efficient sumcheck
- **Source:** *HOBBIT: Space-Efficient zkSNARK with Optimal Prover Time*. [eprint 2025/1214](https://eprint.iacr.org/2025/1214);
  *Proving CPU Executions in Small Space*. [eprint 2025/611](https://eprint.iacr.org/2025/611).
- **Core insight:** Standard sumcheck stores all 2^n MLE evaluations; HOBBIT-style
  algorithms reduce space to O(2^(n/2)) or even O(n) with a small time penalty.
  Critical for very-large-instance provers that don't fit in RAM.
- **Applicable to:** Provers where the witness exceeds RAM (e.g., proving Ethereum
  blocks on consumer hardware).
- **Estimated impact:** Enables instances that previously OOM'd; 1.2–2× wall-clock
  penalty compared to in-memory.
- **Prerequisites:** Re-architect sumcheck driver for streaming.
- **Conflicts with:** Ultra-low-latency provers where RAM is plentiful.
- **Status in production:** Research. SP1's Hypercube split proves sub-blocks; similar
  effect.
- **Relevance to our stack:** **MEDIUM.** XMSS aggregation might fit in RAM today; if
  we scale to whole-validator-set proofs, streaming becomes relevant.

### FPGA proving (Blaze hardware, Cysic, Ulvetanna)
- **Source:** [Ingonyama Blaze FPGA blog](https://medium.com/@ingonyama/introducing-blaze-zk-acceleration-for-fpga-6f5f7cc50e1f);
  Cysic / Ulvetanna marketing material.
- **Core insight:** MSM and NTT map well to FPGA dataflow. Single-FPGA throughput
  competitive with multi-GPU on these primitives.
- **Applicable to:** Cloud-prover deployments with sustained workloads.
- **Estimated impact:** Order of magnitude perf/W vs GPU.
- **Prerequisites:** FPGA target board; multi-week toolchain investment per circuit.
- **Conflicts with:** Rapid iteration (FPGAs not friendly to frequent algorithm changes).
- **Status in production:** Cysic, Ulvetanna offer commercial FPGA proving.
- **Relevance to our stack:** **LOW.** Not in our roadmap.

### Pipeline parallelism via recursive composition
- **Source:** SP1 Hypercube architecture (a16z analysis); RISC0 Bonsai.
- **Core insight:** Split a long execution into sub-trace shards that prove in parallel
  on different machines, then aggregate via a recursive proof. Splits "long thin"
  workload into "short fat".
- **Applicable to:** zkVMs with shardable execution traces (most of them).
- **Estimated impact:** Near-linear with shard count; aggregation overhead is sub-linear.
- **Prerequisites:** A recursion layer (cheap inside the same prover, expensive across
  systems).
- **Conflicts with:** Single-machine deployment scenarios; per-shard fixed overhead
  (commitments) limits speedup at very small shards.
- **Status in production:** SP1, RISC0, Boundless, Aligned all do this for cloud
  proving.
- **Relevance to our stack:** **HIGH.** XMSS aggregation is exactly a parallelizable
  workload — each signature is independent. Our experiments should be measuring
  per-signature throughput and confirming aggregation overhead is in the expected
  sub-linear range.

### Data parallelism within sumcheck (ZipNet / Jagged PCS)
- **Source:** SP1 Hypercube + Jagged PCS (5× claim).
- **Core insight:** Multiple independent sumcheck instances can share the same Merkle
  commitment infrastructure ("jagged" because different sub-traces have different
  heights). Amortize commit cost.
- **Applicable to:** Multi-shard zkVM provers.
- **Estimated impact:** Up to 5× over naïve per-shard FRI commit (per SP1 claim);
  varies with shard size distribution.
- **Prerequisites:** Multi-shard execution; sumcheck-based PCS.
- **Conflicts with:** Single-instance proving.
- **Status in production:** SP1 Hypercube (2025).
- **Relevance to our stack:** **MEDIUM.** Our XMSS workload is already independent
  signatures — if we end up with many shards, jagged PCS is a relevant pattern.

---

## Category 6: Protocol-Level Optimizations

### Folding (Nova / Supernova / HyperNova / Mova / NeutronNova)
- **Source:** *Nova* [eprint 2021/370](https://eprint.iacr.org/2021/370); *Supernova*
  [eprint 2022/1758](https://eprint.iacr.org/2022/1758); *HyperNova* [eprint 2023/573](https://eprint.iacr.org/2023/573);
  *Mova* [eprint 2024/1220](https://eprint.iacr.org/2024/1220); *NeutronNova* [eprint 2024/1606](https://eprint.iacr.org/2024/1606).
- **Core insight:** Instead of recursive SNARK-of-SNARK (expensive), fold multiple
  instances of a relation into a single instance whose SNARK is computed once at the
  end. HyperNova generalizes to CCS (covers Plonkish / R1CS / AIR uniformly); Mova
  pushes folding cost down by removing pairing-curve operations from the folder;
  NeutronNova folds zero-checks.
- **Applicable to:** IVC (Incrementally Verifiable Computation), aggregation, recursion.
- **Estimated impact:** 10–100× over naïve recursive SNARK-wrapping for IVC workloads.
- **Prerequisites:** A foldable relation (CCS, customizable constraint system); for
  HyperNova's MSM-only folder, an MSM-friendly commitment.
- **Conflicts with:** Pure non-recursive workloads gain nothing.
- **Status in production:** Nova in Aleo / Sonobe; HyperNova being implemented in
  Sonobe and arkworks-folding-experimental.
- **Relevance to our stack:** **MEDIUM.** XMSS aggregation could be modeled as folding
  signatures one-by-one, but our current approach (proving a single batch in one
  STARK) sidesteps folding overhead. If signature counts ever exceed single-STARK
  comfort, folding becomes relevant.

### ProtoStar / ProtoGalaxy — Folding without commitment-randomness
- **Source:** *Protostar* [eprint 2023/620](https://eprint.iacr.org/2023/620);
  *Protogalaxy* [eprint 2023/1106](https://eprint.iacr.org/2023/1106).
- **Core insight:** Folding compatible with high-degree custom gates (Plonkish), where
  Nova required degree-2. Folder cost dominated by error-term commitments. ProtoGalaxy
  folds *multiple* instances simultaneously, amortizing folder overhead.
- **Applicable to:** Custom-gate Plonkish provers needing IVC.
- **Estimated impact:** 2–10× over pairwise folding when batching.
- **Prerequisites:** Same as Nova — committed relation, MSM-friendly commitment.
- **Conflicts with:** Hash-only commitment stacks (no MSM); WHIR-only setups.
- **Status in production:** Sonobe; Aztec / experimental settings.
- **Relevance to our stack:** **LOW.** Our PCS is hash-only (WHIR), not MSM. Folding
  literature is largely pairing-curve-anchored.

### CCS (Customizable Constraint Systems)
- **Source:** Setty, Thaler, Wahby. *Customizable constraint systems for succinct
  arguments*. [eprint 2023/552](https://eprint.iacr.org/2023/552)
- **Core insight:** Single constraint-system formalism that captures R1CS, Plonkish,
  AIR, and arbitrary degree custom gates. Lets a prover backend handle any frontend
  uniformly.
- **Applicable to:** Frontend → backend abstraction.
- **Estimated impact:** Engineering cleanliness; small (5–15%) overhead vs hand-tuned
  per-frontend backends.
- **Prerequisites:** Backend implements CCS sumcheck.
- **Conflicts with:** Tightly-tuned domain-specific provers.
- **Status in production:** HyperNova, Sonobe.
- **Relevance to our stack:** **LOW.** We don't have multiple frontends to unify; AIR
  is fine for our single use case.

### AIR with custom gates / RAP (Randomized AIR with Preprocessing)
- **Source:** Plonky3 *RAP* design notes; AIR formalism in StarkWare papers.
- **Core insight:** Allow AIR constraints to depend on phase-1 challenges (preprocessed
  randomness), enabling lookups, permutation arguments, LogUp directly inside AIR.
  Makes AIR as expressive as Plonkish for many purposes while keeping the AIR mental
  model.
- **Applicable to:** STARK provers wanting lookups and permutations without Plonkish
  conversion.
- **Estimated impact:** Same asymptotics as Plonkish; concrete wins from removing
  conversion overhead.
- **Prerequisites:** Multi-phase prover protocol.
- **Conflicts with:** Pure single-phase AIR.
- **Status in production:** Plonky3 (uair / RAP), leanMultisig.
- **Relevance to our stack:** **HIGH — already adopted.** This is how we do lookups.

### Recursive STARK→SNARK wrap for proof size
- **Source:** Plonky2 → Groth16 (Polygon zkEVM); RISC0 Aux Prover; SP1 Plonk wrap;
  Boojum 1.0 Wrap.
- **Core insight:** Inner STARK is fast to produce but produces a large proof; wrap it
  in a SNARK over a pairing curve to get a 200-byte on-chain proof.
- **Applicable to:** On-chain verification scenarios.
- **Estimated impact:** Proof-size reduction from ~200KB to ~200B; verifier cost from
  millions of gas to ~250K gas.
- **Prerequisites:** A SNARK that can verify a STARK as a circuit; recursion-friendly
  hash inside the wrap.
- **Conflicts with:** Latency budget — wrap step is often slow (seconds).
- **Status in production:** Polygon zkEVM, SP1, RISC0, Stwo (planned).
- **Relevance to our stack:** **LOW (today), HIGH (if we go on-chain).** Lean
  Ethereum's plan is hash-only end-to-end; we don't need this. But if leanMultisig
  proofs ever need ETH L1 verification, this is the pattern.

---

## Category 7: Verifier Optimization

### WHIR sub-millisecond verification
- See entry under Category 2 — same paper, double-listed because the verifier-time
  contribution is independently noteworthy.
- **Relevance to our stack:** **HIGH — already adopted.**

### Recursive proof composition for on-chain verification
- See "Recursive STARK→SNARK wrap" under Category 6.

### Constant-size proofs via Brakedown-like + KZG wrap
- **Source:** Generic technique used in HyperPlonk, Spartan-with-KZG, Lasso-with-Hyrax.
- **Core insight:** Replace the linear-size component of a transparent commitment with
  a KZG opening of an aggregated polynomial; gets you constant-size proofs while
  keeping the transparent commit's prover advantage.
- **Applicable to:** Hybrid stacks where a trusted-setup wrap is acceptable.
- **Estimated impact:** Proof size from O(√n) or O(log n) down to O(1) field elements.
- **Prerequisites:** Trusted setup; pairing-friendly curve; aggregated PCS structure.
- **Conflicts with:** Post-quantum requirements; transparent setup requirements.
- **Status in production:** HyperPlonk-derived stacks.
- **Relevance to our stack:** **LOW.** Post-quantum requirement rules this out.

### Verifier-circuit-friendly hash for recursion (Poseidon2 / Skyscraper)
- **Source:** See Category 1 entries.
- **Core insight:** When a prover must verify a previous proof inside its circuit,
  the inner proof's hash function is evaluated as constraints. Use a hash with
  optimal constraint-cost-per-bit-of-output.
- **Applicable to:** Recursive verifiers, IVC.
- **Estimated impact:** 2–10× constraint reduction in the verifier circuit when
  swapping a non-friendly hash (SHA-256) for a friendly one (Poseidon2).
- **Prerequisites:** Algebraic hash inside the proof system being verified.
- **Conflicts with:** Native verifier speed (algebraic hashes are slower natively).
- **Status in production:** Standard everywhere.
- **Relevance to our stack:** **HIGH — already adopted.** Poseidon2 is verifier-friendly.

### Succinct-argument composition (Halo2-style accumulation)
- **Source:** Halo (Bowe, Grigg, Hopwood); Halo2.
- **Core insight:** Verifier defers the most expensive checks and instead accumulates
  them; the next proof in the chain inherits the accumulation. Net: amortized verifier
  cost.
- **Applicable to:** Long IVC chains.
- **Estimated impact:** Amortized verifier work goes from O(steps) to O(1).
- **Prerequisites:** Accumulation-friendly commitment (originally KZG-with-no-trust).
- **Conflicts with:** Non-MSM commitments don't have analogous accumulation schemes
  (yet).
- **Status in production:** Halo2 (zcash, scroll).
- **Relevance to our stack:** **LOW.** WHIR doesn't have an accumulation scheme today.

### Proof aggregation via Snark-of-Snarks
- **Source:** Boundless (RISC0), Aligned, SP1 cluster aggregation.
- **Core insight:** N independent proofs are aggregated into a single proof via a
  SNARK that verifies all N. Common pattern for proof markets.
- **Applicable to:** Proof markets, batch on-chain verification.
- **Estimated impact:** Per-proof verification cost reduced by ~N at the cost of
  one aggregation step.
- **Prerequisites:** Aggregation circuit (recursive verifier); SNARK over pairing
  curve usually.
- **Conflicts with:** Latency-sensitive single-proof scenarios.
- **Status in production:** Boundless, Aligned, multiple proof markets.
- **Relevance to our stack:** **MEDIUM.** XMSS aggregation in leanMultisig is itself
  a form of aggregation; understanding off-chain aggregation patterns helps frame
  what we're doing.

---

## Category 8: Recent Breakthrough Claims (2024–2026)

### Jolt 6× speedup via Twist & Shout
- **Source:** [a16z crypto blog, *Jolt gets a 6× speedup*](https://a16zcrypto.com/posts/article/jolt-6x-speedup/);
  Twist & Shout [eprint 2025/105](https://eprint.iacr.org/2025/105).
- **Claim:** ~1M RISC-V cycles/sec on 32-core CPU; ~500K on MacBook. ~6× over prior
  Jolt; "well over 10×" cheaper memory-checking than prior art.
- **Reproducibility:** Open source (`a16z/jolt`); benchmarks rerunable.
- **Production status:** Jolt mainline (2025).
- **Relevance to our stack:** **MEDIUM** — see Category 3 Twist & Shout entry.

### SP1 Hypercube + Jagged PCS — 5× via shard parallelism
- **Source:** Succinct Labs blog series; [Ethproofs report 2025-05-26](https://www.hozk.io/news/ethproofs-report-2025-05-26).
- **Claim:** Ethereum block proving in ~12s on 50–160 GPUs; 5× over prior SP1.
- **Reproducibility:** Open source (`succinctlabs/sp1`); benchmarks rerunable but
  require GPU cluster.
- **Production status:** SP1 mainline (2025).
- **Relevance to our stack:** **MEDIUM** — patterns transfer to our shard
  aggregation.

### RISC Zero R0VM 2.0 — 35min → 44s for Ethereum block proving
- **Source:** [Introducing R0VM 2.0](https://risczero.com/blog/introducing-R0VM-2.0).
- **Claim:** 35 min → 44 s wall-clock; 5× cost drop; user memory expanded to 3GB.
- **Reproducibility:** Internal benchmarks; open-source verifier.
- **Production status:** Powering Boundless mainnet beta (July 2025).
- **Relevance to our stack:** **LOW.** Different system, but indicates the absolute
  pace of zkVM improvements (~50× in a year for SOTA Eth-block proving).

### Stwo / Circle STARK — Targeted 100× over Stone
- **Source:** [Blockworks: A STARK breakthrough](https://blockworks.com/news/starkware-polygon-labs-stwo-zk-prover);
  [Stwo on L2BEAT](https://l2beat.com/zk-catalog/stwo).
- **Claim:** 100× target (anticipated, not all delivered); Mersenne31 + Circle FFT.
- **Reproducibility:** Open source (`starkware-libs/stwo`); benchmarks rerunable.
- **Production status:** Replacing Stone in Starknet 2025–2026.
- **Relevance to our stack:** **LOW.** M31 stack vs our KoalaBear; principles transfer
  but not direct.

### ZKsync Airbender — 10× cheaper than Boojum
- **Source:** [ZKsync Airbender announcement](https://zksync.mirror.xyz/ZgRmbYA_EE3wfGcXWv81m-xcED-ppNKkRzkleS6YZRc).
- **Claim:** $0.0001/transfer; 10× over Boojum; "fastest open-source RISC-V zkVM".
- **Reproducibility:** Open source.
- **Production status:** Rolling out to ZKsync chains 2025–2026.
- **Relevance to our stack:** **LOW (direct), MEDIUM (intel).** Worth reading their
  design notes; comparison-set for our work.

### Binius64 — 64-bit native binary tower SNARK
- **Source:** [Announcing Binius64](https://www.irreducible.com/posts/announcing-binius64).
- **Claim:** Native 64-bit AND/OR/XOR/shift/MUL constraints; targets bit-heavy
  workloads.
- **Reproducibility:** Open source (`IrreducibleOSS/binius`).
- **Production status:** Released early 2025.
- **Relevance to our stack:** **LOW.** Different field family (binary towers);
  competitive comparison only.

### Skyscraper-v2 — Big-prime hashing 15× over Poseidon2
- **Source:** [eprint 2025/058](https://eprint.iacr.org/2025/058). See Category 1.
- **Claim:** 256 ns / 2-to-1 hash on BLS12-381 Fr; 15× faster than Poseidon2 on
  256-bit primes.
- **Reproducibility:** Reference impl on GitHub.
- **Production status:** Being evaluated by zk-EVM teams.
- **Relevance to our stack:** **LOW (direct), HIGH (intel for outer wrap).**

### WHIR — 3.8× verifier speedup over FRI
- **Source:** See Category 2.
- **Claim:** 1.0 ms verifier vs FRI 3.9 ms.
- **Reproducibility:** Reference impl in `arkworks` and `Whirlaway`.
- **Production status:** Adopted in leanMultisig, Whirlaway, being integrated in
  several Plonky3-derivative provers.
- **Relevance to our stack:** **HIGH — already adopted.**

### Blaze — Interleaved RAA codes for fast SNARKs
- **Source:** [eprint 2024/1609](https://eprint.iacr.org/2024/1609), EUROCRYPT 2025.
- **Claim:** Faster prover than all but Brakedown for large instances; significantly
  smaller proofs than Brakedown.
- **Reproducibility:** Reference impl referenced in paper.
- **Production status:** Research → adoption in progress.
- **Relevance to our stack:** **MEDIUM.** Could be a faster PCS for our use case if
  proof size is acceptable.

### UltraFold — Distributed BaseFold via packed interleaved Merkle trees
- **Source:** [eprint 2026/266](https://eprint.iacr.org/2026/266).
- **Claim:** Distributes BaseFold prover across machines via packed interleaved Merkle
  trees, reducing per-machine RAM and enabling near-linear scaling.
- **Reproducibility:** New (early 2026); not yet widely benchmarked.
- **Production status:** Research.
- **Relevance to our stack:** **MEDIUM.** If we move to a multi-machine prover
  arrangement, the distributed-Merkle technique is directly applicable to WHIR too.

---

## Top 10 Most Actionable for Our Stack

Ranked by (estimated impact × relevance × implementation feasibility) given our
KoalaBear / Poseidon2 / WHIR / GKR-sumcheck / leanMultisig stack. Items marked
"already adopted" in the index are excluded — we want *net new* wins.

1. **Bagad–Dao–Domb–Thaler eq-poly small-value sumcheck** (Category 3,
   [eprint 2025/1117](https://eprint.iacr.org/2025/1117)). 2–3× sumcheck-prover
   speedup, up to 20× when memory-bound. Drop-in algorithmic change; combinable
   with everything else. **Single largest known unrealized prover win.** Audit our
   `eq` handling first; integrate if not present.
2. **FRI soundness above Johnson bound (threshold halving)** (Category 2,
   [eprint 2026/858](https://eprint.iacr.org/2026/858)). Replaces the FRI
   conjecture with a theorem so we can safely reduce query repetition counts.
   ~10–25% argument-size reduction with no prover algorithmic change. Track
   upstream WHIR adoption and update parameters when available.
3. **Packed sumcheck via SIMD** (Category 3,
   [eprint 2025/719](https://eprint.iacr.org/2025/719)). KoalaBear PackedField
   already exists; a packed-sumcheck driver is mostly engineering. Expected 2–4×
   on the sumcheck inner loop, multiplicative with #1.
4. **zip — multi-point Merkle opening dedup** (Category 2,
   [eprint 2025/1446](https://eprint.iacr.org/2025/1446)). Free 10–30%
   argument-size reduction; small encoding change on prover/verifier; no security
   impact.
5. **Dao–Thaler Toom-Cook product folding** (Category 3,
   [eprint 2024/1210](https://eprint.iacr.org/2024/1210)). 10–25% sumcheck
   speedup, layered on #1. Verify Plonky3 sumcheck driver has it; if not, port.
6. **Pipeline parallelism for XMSS aggregation** (Category 5). Workload is
   embarrassingly parallel by signature. Confirm near-linear per-signature scaling
   with shard count and sub-linear aggregation overhead. If we're not seeing it,
   the sharding/aggregation glue is the bug.
7. **Logup\* for small indexed lookups** (Category 3,
   [eprint 2025/946](https://eprint.iacr.org/2025/946)). If our zkVM uses ≤16-bit
   public tables for byte/range ops, 2–4× cheaper per lookup. Small, localized.
8. **End-to-end Poseidon2 audit (incl. compression mode)** (Category 1). Cheap
   audit. Ensure (a) every hashing path uses Poseidon2, not Poseidon1; (b) Merkle
   internal nodes use compression mode, not sponge; (c) packed-field hashing kernels
   are wired through. Any miss here is silent regression.
9. **Twist & Shout memory checking** (Category 3,
   [eprint 2025/105](https://eprint.iacr.org/2025/105)). >10× over prior
   memory-checking only matters if leanMultisig's memory model is a hot spot —
   profile before adopting.
10. **Blaze / linear-code PCS bench experiment** (Category 2,
    [eprint 2024/1609](https://eprint.iacr.org/2024/1609)). Run a controlled
    bench against WHIR at our typical instance sizes. Goal: quantify the WHIR
    choice rather than blindly defend it; surface the proof-size vs prover-time
    tradeoff curve so future decisions are data-driven.

### Honorable mentions (worth tracking, lower priority today)

- **Distributed / Fold-and-Batch FRI** (Category 2). Becomes top-3 if we ever
  deploy across multiple prover machines.
- **HOBBIT streaming sumcheck** (Category 5). Becomes top-5 if we hit RAM ceilings
  as signature counts grow.
- **Skyscraper-v2** (Category 1). Becomes top-3 if we ever add a pairing-curve
  wrap layer for L1 verification.
- **GPU acceleration via ICICLE-KoalaBear** (Category 5). Becomes top-3 if/when
  we add a GPU prover node — would likely be the largest single throughput
  improvement available.

---

## Methodology Notes

- All estimated impacts are paper-claimed or reasoned from public benchmarks; none
  reflect benchmarking in our specific stack. Actual impact requires per-idea
  benchmark experiments.
- "Already adopted" items are kept in the index as documentation of what makes our
  current stack competitive and as a hedge against regression — if any of them ever
  drops out, performance will silently degrade.
- Skipped: pairing-curve-only optimizations not adaptable to our hash-only stack;
  trusted-setup-only schemes; proof-size-only optimizations where our use case
  doesn't bind on size.
- Search was breadth-first across ePrint 2024–2026, EUROCRYPT/CRYPTO 2024–2025
  proceedings, and major prover-team blogs (a16z, Succinct, RISC Zero, Starkware,
  zkSync, Ingonyama, Irreducible, LambdaClass).
