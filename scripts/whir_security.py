"""Compute WHIR security parameters for original vs exp5 configurations.

Mirrors the logic in crates/whir/src/config.rs SecurityAssumption::JohnsonBound.
"""
import math

def log_eta_jb(log_inv_rate, log_c):
    return -(0.5 * log_inv_rate + log_c)

def log_1_delta_jb(log_inv_rate, log_c):
    eta = 2 ** log_eta_jb(log_inv_rate, log_c)
    rate = 1.0 / (1 << log_inv_rate)
    delta = 1 - math.sqrt(rate) - eta
    return math.log2(1 - delta)

def queries_jb(query_security_level, log_inv_rate, log_c):
    return math.ceil(-query_security_level / log_1_delta_jb(log_inv_rate, log_c))

def queries_error_jb(log_inv_rate, num_queries, log_c):
    return -num_queries * log_1_delta_jb(log_inv_rate, log_c)

def list_size_bits_jb(log_degree, log_inv_rate, log_c):
    log_inv_sqrt_rate = log_inv_rate / 2.0
    log_eta = log_eta_jb(log_inv_rate, log_c)
    return log_inv_sqrt_rate - (1 + log_eta)

def ood_error_jb(log_degree, log_inv_rate, field_size_bits, ood_samples, log_c):
    lsb = list_size_bits_jb(log_degree, log_inv_rate, log_c)
    error = 2 * lsb + log_degree * ood_samples
    return ood_samples * field_size_bits + 1 - error

def determine_ood_samples_jb(security_level, log_degree, log_inv_rate, field_size_bits, log_c):
    for ood in range(1, 64):
        if ood_error_jb(log_degree, log_inv_rate, field_size_bits, ood, log_c) >= security_level:
            return ood
    raise Exception("no ood found")

def prox_gaps_error_jb(log_degree, log_inv_rate, field_size_bits, num_functions, log_c):
    log_eta = log_eta_jb(log_inv_rate, log_c)
    eta = 2 ** log_eta
    rate = 1.0 / (1 << log_inv_rate)
    rho_sqrt = math.sqrt(rate)
    gamma = 1 - rho_sqrt - eta
    n = 1 << (log_degree + log_inv_rate)
    m = max(math.ceil(rho_sqrt / (2 * eta)), 3)
    num_1 = (2 * (m + 0.5) ** 5 + 3 * (m + 0.5) * gamma * rate) * n
    den_1 = 3 * rate * rho_sqrt
    num_2 = m + 0.5
    den_2 = rho_sqrt
    error_log = math.log2(num_1 / den_1 + num_2 / den_2)
    nf1_log = math.log2(num_functions - 1) if num_functions > 1 else 0
    return field_size_bits - (error_log + nf1_log)

def rbr_soundness_fold_sumcheck_jb(field_size_bits, num_variables, log_inv_rate, log_c):
    lsb = list_size_bits_jb(num_variables, log_inv_rate, log_c)
    return field_size_bits - 2 * lsb - 1

def folding_pow_bits_jb(security_level, field_size_bits, num_variables, log_inv_rate, log_c):
    fold_sound = rbr_soundness_fold_sumcheck_jb(field_size_bits, num_variables, log_inv_rate, log_c)
    return max(0, security_level - fold_sound)

def rbr_combination_jb(field_size_bits, num_variables, log_inv_rate, ood_samples, num_queries, log_c):
    ood_err = ood_error_jb(num_variables, log_inv_rate, field_size_bits, ood_samples, log_c)
    prox_err = prox_gaps_error_jb(num_variables, log_inv_rate, field_size_bits, num_queries, log_c)
    return min(ood_err, prox_err)

def compute_optimal_log_c(security_level, pow_bits, nv, slir, ff_0, ff_sub, rs_red, n_rounds, field_bits):
    s_0 = nv + 2.5 * slir
    if n_rounds == 0:
        worst_s = s_0
    else:
        delta_0 = 1.5 * ff_0 - 2.5 * rs_red
        per_round = 1.5 * ff_sub - 2.5
        s_last = s_0 + delta_0 + (n_rounds - 1) * per_round
        worst_s = max(s_0, s_last)
    budget = field_bits - (security_level - pow_bits) + math.log2(1.5) - worst_s
    if budget > 0:
        m_opt = int(2 ** (budget / 5) - 0.5)
    else:
        m_opt = 3
    m_opt = max(3, min(100, m_opt))
    return math.log2(2 * m_opt)

def compute_num_rounds(nv, ff_0, ff_sub, max_send):
    nv_after = nv - ff_0
    if nv_after <= max_send:
        return 0
    return math.ceil((nv_after - max_send) / ff_sub)

def analyze(label, ff_0, ff_sub, rs_red, pow_bits,
            security_level=123, nv=26, slir=1, max_send=8, field_bits=31):
    n_rounds = compute_num_rounds(nv, ff_0, ff_sub, max_send)
    log_c = compute_optimal_log_c(security_level, pow_bits, nv, slir, ff_0, ff_sub, rs_red, n_rounds, field_bits)
    query_sec = security_level - pow_bits

    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"{'='*60}")
    print(f"  FF = ({ff_0}, {ff_sub})")
    print(f"  rs_domain_initial_reduction_factor = {rs_red}")
    print(f"  pow_bits = {pow_bits}")
    print(f"  security_level = {security_level}")
    print(f"  num_variables = {nv}, starting_log_inv_rate = {slir}")
    print(f"  num_rounds = {n_rounds}")
    print(f"  log_c = {log_c:.3f}")
    print(f"  query_security_level = {query_sec}")
    print()

    commit_ood = determine_ood_samples_jb(security_level, nv, slir, field_bits, log_c)
    start_fold_pow = folding_pow_bits_jb(security_level, field_bits, nv, slir, log_c)
    print(f"  commitment_ood_samples = {commit_ood}")
    print(f"  starting_folding_pow_bits = {start_fold_pow:.1f}")
    print()

    log_inv_rate = slir
    nv_moving = nv - ff_0
    total_queries = 0
    min_security = float("inf")

    for r in range(n_rounds):
        rs_red_r = rs_red if r == 0 else 1
        ff_r = ff_0 if r == 0 else ff_sub
        next_rate = log_inv_rate + ff_r - rs_red_r

        nq = queries_jb(query_sec, log_inv_rate, log_c)
        ood = determine_ood_samples_jb(security_level, nv_moving, next_rate, field_bits, log_c)

        qerr = queries_error_jb(log_inv_rate, nq, log_c)
        comb_err = rbr_combination_jb(field_bits, nv_moving, next_rate, ood, nq, log_c)
        qpow = max(0, security_level - min(qerr, comb_err))
        fpow = folding_pow_bits_jb(security_level, field_bits, nv_moving, next_rate, log_c)

        round_sec = min(qerr, comb_err) + pow_bits
        min_security = min(min_security, round_sec)

        print(f"  Round {r}: queries={nq}, ood={ood}, "
              f"query_pow={qpow:.1f}, fold_pow={fpow:.1f}, "
              f"rate {log_inv_rate}->{next_rate}, "
              f"round_security={round_sec:.1f}")
        total_queries += nq

        nv_moving -= ff_sub
        log_inv_rate = next_rate

    # Final queries
    final_q = queries_jb(query_sec, log_inv_rate, log_c)
    final_qerr = queries_error_jb(log_inv_rate, final_q, log_c)
    final_sec = final_qerr + pow_bits
    min_security = min(min_security, final_sec)
    total_queries += final_q

    print(f"  Final:   queries={final_q}, "
          f"rate={log_inv_rate}, "
          f"final_security={final_sec:.1f}")

    print()
    print(f"  TOTAL QUERIES across all rounds: {total_queries}")
    print(f"  MINIMUM SECURITY (weakest link): {min_security:.1f} bits")
    print(f"  Target: {security_level} bits")
    gap = min_security - security_level
    if gap >= 0:
        print(f"  --> MEETS target (+{gap:.1f} bits margin)")
    else:
        print(f"  --> BELOW target ({gap:.1f} bits short)")

def compare(configs):
    """Side-by-side cost comparison of WHIR configs that all target the same security_level."""
    results = []
    for label, kw in configs:
        nv = kw.get("nv", 26)
        slir = kw.get("slir", 1)
        ff_0 = kw["ff_0"]
        ff_sub = kw["ff_sub"]
        rs_red = kw["rs_red"]
        pow_bits = kw["pow_bits"]
        security_level = kw.get("security_level", 123)
        max_send = kw.get("max_send", 8)
        field_bits = kw.get("field_bits", 31)

        n_rounds = compute_num_rounds(nv, ff_0, ff_sub, max_send)
        log_c = compute_optimal_log_c(security_level, pow_bits, nv, slir,
                                       ff_0, ff_sub, rs_red, n_rounds, field_bits)
        query_sec = security_level - pow_bits

        log_inv_rate = slir
        nv_moving = nv - ff_0
        total_queries = 0
        total_query_pow = 0
        total_fold_pow = 0
        round_details = []

        for r in range(n_rounds):
            rs_red_r = rs_red if r == 0 else 1
            ff_r = ff_0 if r == 0 else ff_sub
            next_rate = log_inv_rate + ff_r - rs_red_r

            nq = queries_jb(query_sec, log_inv_rate, log_c)
            ood = determine_ood_samples_jb(security_level, nv_moving, next_rate, field_bits, log_c)
            qerr = queries_error_jb(log_inv_rate, nq, log_c)
            comb_err = rbr_combination_jb(field_bits, nv_moving, next_rate, ood, nq, log_c)
            qpow = max(0, security_level - min(qerr, comb_err))
            fpow = folding_pow_bits_jb(security_level, field_bits, nv_moving, next_rate, log_c)

            # Merkle tree height = log_inv_rate + (nv - ff_total_so_far)
            tree_h = log_inv_rate + nv_moving
            round_details.append(dict(r=r, nq=nq, ood=ood, qpow=qpow, fpow=fpow,
                                       rate_before=log_inv_rate, rate_after=next_rate,
                                       tree_height=tree_h))
            total_queries += nq
            total_query_pow += qpow
            total_fold_pow += fpow

            nv_moving -= ff_sub
            log_inv_rate = next_rate

        final_q = queries_jb(query_sec, log_inv_rate, log_c)
        total_queries += final_q

        results.append(dict(
            label=label, ff_0=ff_0, ff_sub=ff_sub, rs_red=rs_red,
            pow_bits=pow_bits, n_rounds=n_rounds, total_queries=total_queries,
            total_query_pow=total_query_pow, total_fold_pow=total_fold_pow,
            final_q=final_q, rounds=round_details, log_c=log_c,
        ))

    # Print comparison
    print("\n" + "=" * 70)
    print("  WHIR Security Cost Comparison")
    print("  All configs target 123-bit security (JohnsonBound)")
    print("  num_variables=26, starting_log_inv_rate=1, field=KoalaBear (31-bit)")
    print("=" * 70)

    header = f"{'Metric':<40}"
    for r in results:
        header += f"  {r['label']:<18}"
    print(header)
    print("-" * len(header))

    def row(metric, key, fmt="{}", extract=None):
        line = f"  {metric:<38}"
        for r in results:
            v = extract(r) if extract else r[key]
            line += f"  {fmt.format(v):<18}"
        print(line)

    row("FF (initial, subsequent)", None, fmt="{}", extract=lambda r: f"({r['ff_0']}, {r['ff_sub']})")
    row("rs_domain_initial_red_factor", "rs_red")
    row("pow_bits (PoW grinding)", "pow_bits")
    row("num_rounds", "n_rounds")
    print()
    row("Total queries (all rounds)", "total_queries")
    row("Final queries", "final_q")
    print()

    # Per-round details
    max_rounds = max(r["n_rounds"] for r in results)
    for rnd in range(max_rounds):
        items = []
        for r in results:
            if rnd < len(r["rounds"]):
                rd = r["rounds"][rnd]
                items.append(f"q={rd['nq']}, ood={rd['ood']}")
            else:
                items.append("(no round)")
        line = f"  Round {rnd:<35}"
        for item in items:
            line += f"  {item:<18}"
        print(line)

    print()
    row("Total query_pow_bits", None, fmt="{:.0f}", extract=lambda r: r["total_query_pow"])
    row("Total fold_pow_bits", None, fmt="{:.0f}", extract=lambda r: r["total_fold_pow"])
    row("Total PoW (pow + q_pow + f_pow)", None, fmt="{:.0f}",
        extract=lambda r: r["pow_bits"] + r["total_query_pow"] + r["total_fold_pow"])

    print()
    print("  Notes:")
    print("  - Both configs achieve 123-bit security by construction")
    print("  - Fewer queries = smaller proof size")
    print("  - Less PoW grinding = faster prover")
    print("  - Fewer rounds = fewer Merkle commitments")

if __name__ == "__main__":
    compare([
        ("ORIGINAL", dict(ff_0=7, ff_sub=5, rs_red=5, pow_bits=18)),
        ("NEW (exp5)", dict(ff_0=11, ff_sub=5, rs_red=7, pow_bits=16)),
    ])
