"""Generate test vectors + expected outputs for tb_fma_top.v, using
golden_model.py as the independent reference. Output: tb/vectors.txt,
one test per line:
  mixmode pra prm ewa ewm a_hex b_hex c_hex exp_hex label
all numeric fields in hex (unsigned), label is a single no-space token
of the form CATEGORY_<format(s)>[_detail]. report.py maps each CATEGORY
to the MPFMA-DS-001 sign-off test IDs (F01-F13) it covers.

Categories:
  MUL_<fmt>          random multiple-precision A+B*C (half of them with
                     A's exponent clustered near B*C's -> cancellation)
  MIX_<a>_<p>        random mixed-precision A + sum(B_i*C_i), same idea
  SPECIAL_<fmt>      NaN / +-Inf / +-0 / max / min-subnormal operands
  SPECIALMIX_<a>_<p> the same in mixed-precision mode
  CANCEL_<fmt>       A = -round(B*C) (+-1 ULP): massive cancellation, result
                     is the product's rounding error -- the defining FMA case
  CANCELMIX_<a>_<p>  A = -round(sum of products), products clustered
  TIE_<fmt>          exact result exactly halfway between two neighbours
  OVF_<fmt>          operands near the top of the range (overflow -> Inf)
  UNF_<fmt>          operands near the bottom (subnormal / zero results)
  HEADROOM_<a>_<p>   addend and all products maximal, same sign (spec F09)
  ANCHOR_<a>_<p>     each product lane in turn the largest, tied largest
                     exponents, addend largest (spec F05/F07)
  DIR_<...>          hand-written directed cases (incl. every bug found)
"""
import argparse
import random
from golden_model import (
    FORMATS, LANES_OF_CLS, rand_bits, fma_accumulate, pack_lanes_to_bus,
    exact_value, is_rounding_tie, special_bits, make_bits, unbiased_exp,
    bias_of, unpack,
)

ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
ap.add_argument('--seed', type=lambda x: int(x, 0), default=0xF3A5EED,
                help='random seed (default 0xF3A5EED = the committed regression)')
ap.add_argument('--out', default='vectors.txt')
ap.add_argument('--demo-out', default='demo_vectors.txt')
args = ap.parse_args()

random.seed(args.seed)
rng = random

N_MUL, N_MIX = 500, 300
N_SPECIAL, N_SPECIALMIX = 60, 20
N_CANCEL, N_CANCELMIX = 60, 20
N_TIE, N_RANGE = 30, 30

OUT_PATH = args.out
DEMO_PATH = args.demo_out
lines = []
counts = {}


def add_line(mixmode, pra, prm, ewa, ewm, a, b, c, exp32, label):
    lines.append("%d %d %d %d %d %016x %016x %016x %08x %s" %
                 (mixmode, pra, prm, ewa, ewm, a, b, c, exp32, label))
    cat = label.split('_')[0]
    counts[cat] = counts.get(cat, 0) + 1


def emit_mul(fmt, a_l, b_l, c_l, label):
    """Multiple-precision: lane i computes a_l[i] + b_l[i]*c_l[i]."""
    info = FORMATS[fmt]
    cls, ew = info['cls'], info['ew']
    n = LANES_OF_CLS[cls]
    a_l, b_l, c_l = list(a_l), list(b_l), list(c_l)
    while len(a_l) < 4:
        a_l.append(rand_bits(fmt, rng)); b_l.append(rand_bits(fmt, rng)); c_l.append(rand_bits(fmt, rng))
    res = [fma_accumulate(a_l[i], fmt, [(b_l[i], c_l[i], fmt)], fmt) if i < n else 0
           for i in range(4)]
    add_line(0, cls, cls, ew, ew, pack_lanes_to_bus(a_l, cls), pack_lanes_to_bus(b_l, cls),
             pack_lanes_to_bus(c_l, cls), pack_lanes_to_bus(res, cls), label)


def emit_mix(afmt, pfmt, a, b_l, c_l, label):
    """Mixed-precision: a (afmt) + sum_i b_l[i]*c_l[i] (pfmt), result in afmt."""
    ai, pi = FORMATS[afmt], FORMATS[pfmt]
    n = LANES_OF_CLS[pi['cls']]
    pairs = [(b_l[i], c_l[i], pfmt) for i in range(n)]
    r = fma_accumulate(a, afmt, pairs, afmt)
    add_line(1, ai['cls'], pi['cls'], ai['ew'], pi['ew'], pack_lanes_to_bus([a], ai['cls']),
             pack_lanes_to_bus(b_l, pi['cls']), pack_lanes_to_bus(c_l, pi['cls']),
             pack_lanes_to_bus([r], ai['cls']), label)


def lanes(fmt):
    return LANES_OF_CLS[FORMATS[fmt]['cls']]


def emax(fmt):
    return bias_of(FORMATS[fmt]['ew'])


def emin(fmt):
    return 1 - bias_of(FORMATS[fmt]['ew'])


def neg(bits, fmt):
    return bits ^ (1 << (FORMATS[fmt]['total'] - 1))


def finite_nonzero(bits, fmt):
    return unpack(bits, fmt).kind == 'normal'


def clustered_triplet(fmt):
    """b, c random normals with a product in range; a's exponent near b*c's."""
    lo, hi = emin(fmt), emax(fmt)
    eb = rng.randint(lo // 2, hi // 2)
    ec = rng.randint(lo // 2, hi // 2)
    b = rand_bits(fmt, rng, exp=eb)
    c = rand_bits(fmt, rng, exp=ec)
    a = rand_bits(fmt, rng, exp=eb + ec + rng.randint(-3, 3))
    return a, b, c


# ---------------- Category MUL: multiple-precision mode, all formats ----------------
MUL_FORMATS = list(FORMATS)
for fmt in MUL_FORMATS:
    for k in range(N_MUL):
        if k % 2 == 0:
            emit_mul(fmt, [rand_bits(fmt, rng) for _ in range(4)],
                     [rand_bits(fmt, rng) for _ in range(4)],
                     [rand_bits(fmt, rng) for _ in range(4)], "MUL_%s" % fmt)
        else:
            t = [clustered_triplet(fmt) for _ in range(4)]
            emit_mul(fmt, [x[0] for x in t], [x[1] for x in t], [x[2] for x in t], "MUL_%s" % fmt)

# ---------------- Category MIX: mixed-precision mode, all supported combos ----------------
MIXED_COMBOS = []
for addend_fmt in ['HP', 'DLFloat16', 'BFloat16']:
    for prod_fmt in ['E4M3', 'E5M2']:
        MIXED_COMBOS.append((addend_fmt, prod_fmt))
for addend_fmt in ['SP', 'TF32']:
    for prod_fmt in ['E4M3', 'E5M2']:
        MIXED_COMBOS.append((addend_fmt, prod_fmt))
for addend_fmt in ['SP', 'TF32']:
    for prod_fmt in ['HP', 'DLFloat16', 'BFloat16']:
        MIXED_COMBOS.append((addend_fmt, prod_fmt))


def clustered_mix(afmt, pfmt):
    """Products with exponents in a narrow window; addend near their sum."""
    n = lanes(pfmt)
    lo, hi = emin(pfmt), emax(pfmt)
    e0 = rng.randint(lo // 2, hi // 2)
    b_l = [rand_bits(pfmt, rng, exp=e0 + rng.randint(-2, 2)) for _ in range(4)]
    c_l = [rand_bits(pfmt, rng, exp=rng.randint(-2, 2)) for _ in range(4)]
    a = rand_bits(afmt, rng, exp=e0 + rng.randint(-3, 3))
    return a, b_l, c_l


for (afmt, pfmt) in MIXED_COMBOS:
    for k in range(N_MIX):
        if k % 2 == 0:
            emit_mix(afmt, pfmt, rand_bits(afmt, rng), [rand_bits(pfmt, rng) for _ in range(4)],
                     [rand_bits(pfmt, rng) for _ in range(4)], "MIX_%s_%s" % (afmt, pfmt))
        else:
            a, b_l, c_l = clustered_mix(afmt, pfmt)
            emit_mix(afmt, pfmt, a, b_l, c_l, "MIX_%s_%s" % (afmt, pfmt))

# ---------------- Category SPECIAL: NaN / Inf / zero / extremes ----------------
SPECIAL_KINDS = ['zero', 'inf', 'nan', 'max', 'minsub', 'rand', 'rand', 'rand']


def special_operand(fmt):
    kind = rng.choice(SPECIAL_KINDS)
    if kind == 'rand':
        return rand_bits(fmt, rng)
    return special_bits(fmt, kind, rng.randint(0, 1))


for fmt in MUL_FORMATS:
    for _ in range(N_SPECIAL):
        emit_mul(fmt, [special_operand(fmt) for _ in range(4)], [special_operand(fmt) for _ in range(4)],
                 [special_operand(fmt) for _ in range(4)], "SPECIAL_%s" % fmt)
for (afmt, pfmt) in MIXED_COMBOS:
    for _ in range(N_SPECIALMIX):
        emit_mix(afmt, pfmt, special_operand(afmt), [special_operand(pfmt) for _ in range(4)],
                 [special_operand(pfmt) for _ in range(4)], "SPECIALMIX_%s_%s" % (afmt, pfmt))

# ---------------- Category CANCEL: A = -round(B*C) (+-1 ULP) ----------------
for fmt in MUL_FORMATS:
    made = 0
    while made < N_CANCEL:
        a_l, b_l, c_l = [], [], []
        for _ in range(4):
            _, b, c = clustered_triplet(fmt)
            p = fma_accumulate(special_bits(fmt, 'zero'), fmt, [(b, c, fmt)], fmt)  # round(b*c)
            a = neg(p, fmt)
            nudge = rng.choice([0, 0, 1, -1])
            if finite_nonzero(a, fmt) and finite_nonzero(a + nudge, fmt):
                a += nudge
            a_l.append(a); b_l.append(b); c_l.append(c)
        emit_mul(fmt, a_l, b_l, c_l, "CANCEL_%s" % fmt)
        made += 1
for (afmt, pfmt) in MIXED_COMBOS:
    for _ in range(N_CANCELMIX):
        _, b_l, c_l = clustered_mix(afmt, pfmt)
        pairs = [(b_l[i], c_l[i], pfmt) for i in range(lanes(pfmt))]
        s = fma_accumulate(special_bits(afmt, 'zero'), afmt, pairs, afmt)  # round(sum)
        emit_mix(afmt, pfmt, neg(s, afmt), b_l, c_l, "CANCELMIX_%s_%s" % (afmt, pfmt))

# ---------------- Category TIE: exact result halfway between two neighbours ----------------
for fmt in MUL_FORMATS:
    found = []
    tries = 0
    while len(found) < 4 * N_TIE and tries < 400000:
        tries += 1
        lo, hi = emin(fmt), emax(fmt)
        eb = rng.randint(lo // 2, hi // 2)
        ec = rng.randint(lo // 2, hi // 2)
        b = rand_bits(fmt, rng, exp=eb, short=True)
        c = rand_bits(fmt, rng, exp=ec, short=True)
        a = rand_bits(fmt, rng, exp=eb + ec + rng.randint(-4, 4), short=True)
        if is_rounding_tie(exact_value(a, fmt, [(b, c, fmt)]), fmt):
            found.append((a, b, c))
    for k in range(0, len(found) - 3, 4):
        grp = found[k:k + 4]
        emit_mul(fmt, [g[0] for g in grp], [g[1] for g in grp], [g[2] for g in grp], "TIE_%s" % fmt)

# ---------------- Category OVF / UNF: range extremes ----------------
for fmt in MUL_FORMATS:
    hi, lo = emax(fmt), emin(fmt)
    for _ in range(N_RANGE):
        t = []
        for _ in range(4):
            b = rand_bits(fmt, rng, exp=rng.randint(hi // 2, hi))
            c = rand_bits(fmt, rng, exp=rng.randint(hi // 2, hi))
            a = rand_bits(fmt, rng, exp=rng.randint(hi - 3, hi))
            t.append((a, b, c))
        emit_mul(fmt, [x[0] for x in t], [x[1] for x in t], [x[2] for x in t], "OVF_%s" % fmt)
    for _ in range(N_RANGE):
        t = []
        for _ in range(4):
            e = rng.randint(lo - 4, lo // 2 + 2)
            b = rand_bits(fmt, rng, exp=rng.randint(lo // 2 - 2, 0))
            c = rand_bits(fmt, rng, exp=e - unbiased_exp(b, fmt) + rng.randint(-2, 2))
            a = rng.choice([special_bits(fmt, 'zero', rng.randint(0, 1)),
                            rand_bits(fmt, rng, exp=lo), special_bits(fmt, 'minsub', rng.randint(0, 1))])
            t.append((a, b, c))
        emit_mul(fmt, [x[0] for x in t], [x[1] for x in t], [x[2] for x in t], "UNF_%s" % fmt)

# ---------------- Category HEADROOM (F09) / ANCHOR (F05, F07): mixed-mode structure ----------------
for (afmt, pfmt) in MIXED_COMBOS:
    n = lanes(pfmt)
    m = FORMATS[pfmt]['m']
    for sign in (0, 1):
        for full in (True, False):
            # every product (1.11..1)^2 * 2^e (or random mantissas) with the same sign
            e = rng.randint(0, emax(pfmt) // 2)
            b_l, c_l = [], []
            for _ in range(4):
                mb = (1 << m) - 1 if full else rng.randint(0, (1 << m) - 1)
                mc = (1 << m) - 1 if full else rng.randint(0, (1 << m) - 1)
                b_l.append(make_bits(pfmt, sign, e + bias_of(FORMATS[pfmt]['ew']), mb))
                c_l.append(make_bits(pfmt, 0, bias_of(FORMATS[pfmt]['ew']), mc))
            pairs = [(b_l[i], c_l[i], pfmt) for i in range(n)]
            # addend as large as one product, same sign
            a = fma_accumulate(special_bits(afmt, 'zero'), afmt, pairs[:1], afmt)
            emit_mix(afmt, pfmt, a, b_l, c_l, "HEADROOM_%s_%s" % (afmt, pfmt))
    for rep in range(3):
        # lane k is the anchor (largest), others 1..6 binades smaller, random signs
        for k in range(n):
            e0 = rng.randint(0, emax(pfmt) // 2)
            b_l = [rand_bits(pfmt, rng, exp=e0 if i == k else e0 - rng.randint(1, 6)) for i in range(4)]
            c_l = [rand_bits(pfmt, rng, exp=0) for _ in range(4)]
            a = rand_bits(afmt, rng, exp=e0 - rng.randint(1, 6))
            emit_mix(afmt, pfmt, a, b_l, c_l, "ANCHOR_%s_%s_lane%d" % (afmt, pfmt, k))
        # tied: every product has the same exponent (Comparator tie)
        e0 = rng.randint(0, emax(pfmt) // 2)
        b_l = [rand_bits(pfmt, rng, exp=e0) for _ in range(4)]
        c_l = [rand_bits(pfmt, rng, exp=0) for _ in range(4)]
        emit_mix(afmt, pfmt, rand_bits(afmt, rng, exp=e0 - 2), b_l, c_l,
                 "ANCHOR_%s_%s_tied" % (afmt, pfmt))
        # the addend is the largest term
        b_l = [rand_bits(pfmt, rng, exp=e0 - rng.randint(0, 4)) for _ in range(4)]
        emit_mix(afmt, pfmt, rand_bits(afmt, rng, exp=e0 + rng.randint(1, 5)), b_l, c_l,
                 "ANCHOR_%s_%s_addend" % (afmt, pfmt))


# ---------------- Category DIR: directed edge cases ----------------
def directed():
    E4M3_1_0, E4M3_1_75 = 0x38, 0x3E
    HP_1_75 = 0x3F00
    SP_1_0, SP_INF = 0x3F800000, 0x7F800000

    # all-zero, both modes
    emit_mul('E4M3', [0] * 4, [0] * 4, [0] * 4, "DIR_E4M3_allzero")
    emit_mix('HP', 'E4M3', 0, [0] * 4, [0] * 4, "DIR_HP_E4M3_allzero")
    # addend dominates hugely, products zero
    emit_mix('HP', 'E4M3', 0b0_11101_1111111111, [0] * 4, [0] * 4, "DIR_HP_addend_dominates")
    # 4 products with alternating sign that cancel
    emit_mix('HP', 'E4M3', 0, [0b0_0110_001, 0b1_0110_001, 0b0_0101_010, 0b1_0101_010],
             [0b0_0111_000] * 4, "DIR_HP_E4M3_cancel")
    # subnormal HP product operand, SP addend
    emit_mix('SP', 'HP', 0, [0b0_00000_0000000001, 0b0_01111_0000000000],
             [0b0_01111_0000000000] * 2, "DIR_SP_HP_subnorm")

    # --- one case per bug found and fixed (docs/DEVIATIONS.md) ---
    # Bug 4: accumulator headroom -- 1.75 + 4*(1.75*1.0) = 8.75 (was -7.25)
    emit_mix('HP', 'E4M3', HP_1_75, [E4M3_1_75] * 4, [E4M3_1_0] * 4, "DIR_BUG4_headroom_pos")
    emit_mix('HP', 'E4M3', HP_1_75 | 0x8000, [E4M3_1_75 | 0x80] * 4, [E4M3_1_0] * 4, "DIR_BUG4_headroom_neg")
    # Bug 5 (and 1): exact FMA cancellation a = -round(b*c) -> 2^-46 exactly
    emit_mul('SP', [0xBF800002], [0x3F800001], [0x3F800001], "DIR_BUG5_SP_exact_cancel")
    # Bug 1: SP product guard bit (was 1 ULP low)
    emit_mul('SP', [0x00000000], [0x1139e399], [0xaee23e77], "DIR_BUG1_SP_product_guard")
    # Bug 2: subnormal result must be rounded, not truncated (E5M2 -> 0x01)
    emit_mul('E5M2', [0xaa, 0xb9, 0x80, 0x80], [0x82, 0x01, 0xbb, 0x01], [0x00, 0x04, 0x81, 0x01],
             "DIR_BUG2_E5M2_subnormal_round")
    # Bug 3: truncated negated term, negative result (was 1 ULP too big)
    emit_mix('BFloat16', 'E5M2', 0x0000, [0xc0, 0x79, 0x74, 0x00], [0x82, 0xe9, 0xd7, 0xa5],
             "DIR_BUG3_sticky_sign")
    # Bug 6: -Inf addend -> -Inf (was +Inf)
    emit_mul('SP', [SP_INF | 0x80000000], [SP_1_0], [SP_1_0], "DIR_BUG6_neg_inf")
    # Bug 7: Inf - Inf -> NaN (was Inf)
    emit_mul('SP', [SP_INF], [SP_INF | 0x80000000], [SP_1_0], "DIR_BUG7_inf_minus_inf")
    # Bug 8: -0 + (-0)*(+1) -> -0 (was +0)
    emit_mul('SP', [0x80000000], [0x80000000], [SP_1_0], "DIR_BUG8_neg_zero")
    # other specials
    emit_mul('SP', [SP_1_0], [SP_INF], [0], "DIR_SP_inf_times_zero")
    emit_mul('SP', [0x7F7FFFFF], [0x7F7FFFFF], [SP_1_0], "DIR_SP_overflow")
    emit_mul('SP', [0x7FC00000], [SP_1_0], [SP_1_0], "DIR_SP_nan_in")


directed()

# small, readable demo set for waveform viewing (run_sim.sh --demo): every
# DIR_ case plus the first vector of each MUL/MIX format, in a fixed order
demo, seen = [], set()
for l in lines:
    lab = l.split()[-1]
    key = lab if lab.startswith('DIR_') else lab.split('_')[0] + '_' + '_'.join(lab.split('_')[1:3])
    if (lab.startswith('DIR_') or lab.startswith('MUL_') or lab.startswith('MIX_')) and key not in seen:
        seen.add(key)
        demo.append(l)
with open(DEMO_PATH, 'w') as f:
    f.write("%d\n" % len(demo))
    for l in demo:
        f.write(l + "\n")

rng.shuffle(lines)  # consecutive vectors switch mode/format constantly (spec F13)
with open(OUT_PATH, 'w') as f:
    f.write("%d\n" % len(lines))
    for l in lines:
        f.write(l + "\n")

print("wrote %d vectors to %s (+ %d-vector demo set %s)" % (len(lines), OUT_PATH, len(demo), DEMO_PATH))
for cat in sorted(counts):
    print("  %-11s %5d" % (cat, counts[cat]))
