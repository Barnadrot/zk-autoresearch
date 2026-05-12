# Defense of the `+s` truncated feedforward hash against ePrint 2025/963

## 0. Notation

- $p \approx 2^{31}$ (KoalaBear); $b = 16$, $r = 12$, $c = b - r = 4$, $h = 8$. All quantities below are in *field elements* unless suffixed by "bits"; one field element carries $\log_2 p \approx 31$ bits.
- State $s \in \mathbb{F}^b$, decomposed as $s = (R, C)$ with $R \in \mathbb{F}^r$, $C \in \mathbb{F}^c$.
- Permutation $\pi : \mathbb{F}^b \to \mathbb{F}^b$, modeled as a uniformly random permutation.
- Compression and iteration:
  $$F(s,M) \;=\; \pi(x) + s, \qquad x \;=\; s + (M \,\|\, 0^c), \qquad s_0 = 0^b,\;\; s_i = F(s_{i-1}, M_i), \;\; \mathsf{H}(M) = (s_k)_{1:h}.$$
- SPONGE-DM (ePrint 2025/963) for comparison:
  $$F^{\mathsf{DM}}(s,M) \;=\; \pi(x) + x \;=\; \pi(x) + s + (M\,\|\,0^c).$$
- So $F^{\mathsf{DM}}(s,M) - F(s,M) = (M\,\|\,0^c)$. The constructions agree on the **capacity** output and differ on the **rate** output by $+M$.

---

## 1. Where the SPONGE-DM $c/2$ attack breaks on `+s`

The chosen-message-cancel attack giving SPONGE-DM its $c/2$ bound is a 2-block attack:

**Round 1 — inner-state collision.** Query $\pi$ on rate-varied inputs $(M, 0^c)$ from $s_0 = 0^b$; by birthday on the capacity ($c$ elements), find $M^{(1)}, M^{(2)}$ such that the capacity outputs agree. This costs $\approx p^{c/2} = 2^{c \log_2 p / 2} = 2^{62}$ for **both** SPONGE-DM and `+s` (capacity outputs are identical between the two). After round 1:
$$s_1 = (R_1, C^\star), \quad s_1' = (R_2, C^\star), \quad \Delta R := R_1 - R_2 \neq 0.$$

**Round 2 — message shift.** Apply $M^*$ to $s_1$ and $M'^* := M^* + \Delta R$ to $s_1'$. Then $x = (R_1 + M^*,\, C^\star)$ and $x' = (R_2 + M'^*,\, C^\star) = x$. The $\pi$ inputs coincide; write $\pi(x) = (P_R, P_C)$.

- **SPONGE-DM round-2 output:** $s_2 = (P_R + R_1 + M^*,\, P_C + C^\star)$ and $s_2' = (P_R + R_2 + M'^*,\, P_C + C^\star)$. Since $M'^* - M^* = \Delta R = R_1 - R_2$, the rate outputs satisfy $R_2 + M'^* = R_1 + M^*$. **Full-state collision**, cost $2^{62}$.
- **`+s` round-2 output:** $s_2 = (P_R + R_1,\, P_C + C^\star)$ and $s_2' = (P_R + R_2,\, P_C + C^\star)$. Rate residual is $\Delta R$, the *same* $\Delta R$ produced by round 1; it is independent of $M^*$. **No state collision; only capacity matches.**

The shift in SPONGE-DM works precisely because the $(M\,\|\,0^c)$ term appears in *both* the $\pi$ argument and the feedforward, so shifting $M$ simultaneously translates the $\pi$ input and cancels in the output. In `+s` the feedforward is $+s$, independent of $M$, so the same shift no longer kills the rate residual. The attack vector is dead, not merely degraded.

To salvage a collision from this starting point, the attacker must additionally cancel $\Delta R$ — either by finding round-1 capacity collisions with the additional constraint $R_1 = R_2$ on (at least) the first $h$ coordinates (an $h + c$-element birthday, $2^{(h+c)\log_2 p / 2} = 2^{186}$), or by extending to a third block where $\Delta R$ enters $\pi$'s input and must be cancelled by another shift — but the next round produces *its own* fresh rate residual via $+s$. The residual telescopes; it never cancels.

## 2. Reduction sketch: `+s` is Davies–Meyer over a fixed permutation

Define the unrestricted Davies–Meyer compression
$$\tilde F(s, M) \;=\; \pi(s + M) + s, \qquad M \in \mathbb{F}^b.$$

Then $F(s, M) = \tilde F(s, M\,\|\,0^c)$ for $M \in \mathbb{F}^r$. Any collision $(M_1, M_2, \dots)$ on $F$ lifts to a collision on $\tilde F$ with the same number of $\pi$ queries (just embed $M_i \mapsto (M_i\,\|\,0^c)$). Hence
$$\mathsf{Adv}^{\mathrm{coll}}_F(q) \;\le\; \mathsf{Adv}^{\mathrm{coll}}_{\tilde F}(q).$$

$\tilde F$ is the natural **fixed-permutation analog of Davies–Meyer**: $\pi$ replaces a keyed cipher; the input plays the role of message-via-XOR; the chaining value is the feedforward. In the random-permutation model, finding $(s_1, M_1) \neq (s_2, M_2)$ with $\pi(s_1 + M_1) + s_1 = \pi(s_2 + M_2) + s_2$ is equivalent to finding two $\pi$-queries $(x_1, y_1), (x_2, y_2)$ such that $y_1 - y_2 = -(s_1 - s_2)$ with $s_i = x_i - M_i$, i.e., $y_1 + x_1 - y_2 - x_2 = M_1 - M_2$. With $M_i$ freely chosen, the equation $y_1 + x_1 = y_2 + x_2 + (M_1 - M_2)$ is satisfiable as soon as two $\pi$ queries collide in $y + x$; this is the Black–Rogaway–Shrimpton (CRYPTO 2002, "Black-box analysis of the block-cipher-based hash-function constructions from PGV") setup, giving the classical
$$\mathsf{Adv}^{\mathrm{coll}}_{\tilde F}(q) \;\le\; \binom{q}{2} / p^{b} \;=\; q^2 / 2^{b\log_2 p + 1}$$
so collisions on full state require $q \approx 2^{b\log_2 p / 2} = 2^{248}$.

For the iterated, truncated digest $\mathsf{H}(\cdot) = (s_k)_{1:h}$, a standard Merkle–Damgård-style argument (Damgård CRYPTO '89, plus truncation accounting) gives
$$\mathsf{Adv}^{\mathrm{coll}}_{\mathsf{H}}(q) \;\le\; \mathsf{Adv}^{\mathrm{coll}}_{\tilde F}(q) \;+\; q^2 / 2^{h\log_2 p + 1} \;\le\; q^2 / 2^{248 \cdot 2} \;+\; q^2 / 2^{249},$$
so $q \approx 2^{h\log_2 p / 2} = 2^{124}$ is required for a digest collision. The bottleneck is the truncated-output birthday, exactly as Emile's "$h/2$" leg states. There is **no $c/2$ leg** in this analysis because the inner-state collision lemma used in the standard sponge proof relies on the shift trick, which (by §1) does not transfer.

## 3. Where this could still go wrong

The reduction in §2 has one soft spot: zero-padding restricts the attacker's message space to a rate-only affine subspace of $\mathbb{F}^b$. Restricting message freedom **cannot make collision attacks easier on $F$ than on $\tilde F$** (any attack on $F$ is an attack on $\tilde F$), so the upper bound $\le 2^{248}$ on full-state collisions carries. What restriction *could* break is a **lower bound** ("$F$ is at least as secure as $\tilde F$ in the other direction") if one tried to argue from $\tilde F$ to $F$ — but that is not what we need.

The other soft spot is that the Merkle–Damgård collision-resistance proof assumes the compression is collision-resistant *as a fixed-input-length function*; the truncated final block introduces no new collisions beyond birthday. Both hold here.

## 4. Closest published cousins

1. **Black, Rogaway, Shrimpton — CRYPTO 2002** ("Black-box analysis of the block-cipher-based hash-function constructions from PGV"). All 12 secure PGV modes — including Davies–Meyer, Matyas–Meyer–Oseas, Miyaguchi–Preneel — achieve $2^{n/2}$ collision resistance on the full state width $n$. The `+s` construction is the fixed-permutation analog of DM mode (message-XORed into the plaintext, chaining value used as feedforward). Their bound transports through the reduction in §2.
2. **Stam — CRYPTO 2008** ("Beyond uniformity: better security/efficiency tradeoffs for permutation based hashing"). Establishes that single-call permutation-based compressions with feedforward attain $2^{n/2}$ collision resistance when the feedforward and the $\pi$-argument are *not collinear in the message* — i.e., when the message does not appear both inside $\pi$ and outside in the same direction. SPONGE-DM violates this (the $(M\,\|\,0)$ term appears in both); `+s` satisfies it (no $M$ in feedforward). This is the structural reason §1's shift attack works for SPONGE-DM and fails for `+s`.
3. **Lefèvre & Mennink — ToSC 2022** ("Tight preimage resistance of the sponge construction"). The standard sponge $c/2$ inner-state attack relies on the shift trick. The 2025/963 paper extends this analysis to SPONGE-DM where the shift still works because of the rate-side feedforward. Neither paper's $c/2$ lower-bound attack applies once that feedforward is removed.

The cleanest framing: **SPONGE-DM is a sponge with a DM-style feedforward; `+s` is a Davies–Meyer hash with a sponge-style padded input.** Emile's classification places it in the first family; structurally and proof-wise it sits in the second.

---

## 5. Concrete bounds and operational cost

| Bound | SPONGE-DM (2025/963) | `+s` (this defense) |
|---|---|---|
| Inner-state attack | $2^{c\log_2 p / 2} = 2^{62}$ | not applicable (§1) |
| DM-style full-state | not applicable | $2^{b\log_2 p / 2} = 2^{248}$ |
| Truncated digest birthday | $2^{h\log_2 p / 2} = 2^{124}$ | $2^{h\log_2 p / 2} = 2^{124}$ |
| Wagner 3-list on full state | $2^{b\log_2 p / 3} \approx 2^{165}$ | $2^{b\log_2 p / 3} \approx 2^{165}$ |
| **Effective** | $\mathbf{2^{62}}$ | $\mathbf{2^{124}}$ (heuristic; pending Mennink-group endorsement) |

**Cost of being conservative (ship $c = 8$).** Emile's "$2\times$" claim is a worst-case sketch. At fixed width $b = 16$, raising $c$ from $4$ to $8$ drops $r$ from $12$ to $8$ — a $12/8 = 1.5\times$ ratio of absorptions per input element, not $2\times$. For the dominant cost (Merkle leaf hashing in `first_digest_layer_with_initial_state`, currently $\sim 17\%$ of total proof time hashing $\sim 110$ base-field elements per row over $256\text{K}$ rows):

- $c = 4$: $\lceil 110 / 12 \rceil = 10$ absorptions/row.
- $c = 8$: $\lceil 110 / 8 \rceil = 14$ absorptions/row.

That is a $1.4\times$ regression on $17\%$ of total runtime, i.e. **$+6.8\%$ end-to-end** at the same proof size. (Smaller WHIR-round Merkle trees absorb a similar penalty on a smaller base, adding maybe another $1$–$2\%$.) Realistic total: **$+7$–$9\%$ wall-clock** to ship with $c = 8$ under the standard sponge bound.

If we instead widen to $b = 24$ (Plonky3 has a Poseidon2-24 KoalaBear variant) with $c = 8$, $r = 16$, the per-permutation cost is $\sim 1.5\times$ but absorptions drop by $16/12$ vs the current rate-12 setup, giving a probable net win — but that is a separate engineering project (~500 LoC: new AIR, new precompile, regen reference proofs).

---

## 6. What we conclude, ask, and ship

**Conclude.** Emile's analysis correctly identifies that no published proof of $2^{124}$ for `+s` exists, and correctly observes that SPONGE-DM is a closely related construction with a $c/2$ bound. We push back on the classification: structurally, `+s` is a fixed-permutation Davies–Meyer hash with zero-padded message input, not a sponge with feedforward. The $c/2$ attack against SPONGE-DM relies on a shift trick that requires the message to appear in *both* the $\pi$-argument and the feedforward; in `+s` it appears only in the $\pi$-argument, and the attack produces a residual rate disagreement that telescopes across blocks rather than cancelling. Under the random-permutation model, the natural reduction to fixed-permutation DM (Black–Rogaway–Shrimpton, Stam) gives full-state collision bound $2^{b\log_2 p / 2} = 2^{248}$, hence truncated-digest collision bound $2^{h\log_2 p / 2} = 2^{124}$, matching the design target.

This argument is heuristic — a careful indifferentiability proof in the style of Bertoni–Daemen–Peeters–Van Assche (Eurocrypt 2008) or a direct compression-collision proof following Stam 2008 is needed to make it formal.

**Ask.** Send this note to the 2025/963 author group (Sun, Li, Zhang, Lefèvre, Mennink, Qin, Feng). Two specific questions: (a) does their Theorem 1 admit a `+s` variant with the rate-feedforward removed, and what is the bound; (b) if their lower-bound attack adapts to `+s`, what is the residual-rate-cancellation cost, and does it close on $c/2$ or land between $c/2$ and $h/2$? Their answer determines whether we ship `+s` or fall back to $c = 8$.

**Ship.** Until we hear back: **ship `+s` with $c = 4$ on the development branch only**, gate the production tag behind external review. If the Mennink group declines to opine or returns a $c/2$ attack we cannot rule out, swap to $c = 8$ at the $\sim 7$–$9\%$ wall-clock cost quantified in §5; alternatively, scope the Poseidon2-24 widening project, which dominates either choice once landed.

We do not believe `+s` is broken at $c/2$. We do believe it is unproven at $h/2$, and "unproven" is the load-bearing word in a cryptographic dependency.
