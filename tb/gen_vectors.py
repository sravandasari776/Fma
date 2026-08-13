"""Generate test vectors + expected outputs for tb_fma_top.sv, using
golden_model.py as the independent reference. Output: tb/vectors.txt,
one test per line:
  mixmode pra prm ewa ewm a_hex b_hex c_hex exp_hex label
all numeric fields in hex (unsigned), label is a single no-space token.
"""
import random
from golden_model import (
    FORMATS, LANES_OF_CLS, rand_bits, fma_accumulate,
    pack_lanes_to_bus, unpack_lanes_from_bus,
)

random.seed(0xF3A5EED)

OUT_PATH = 'vectors.txt'
lines = []


def add_line(mixmode, pra, prm, ewa, ewm, a, b, c, exp32, label):
    lines.append(f"{mixmode} {pra} {prm} {ewa} {ewm} "
                  f"{a:016x} {b:016x} {c:016x} {exp32:08x} {label}")


# ---------------- Category 1: multiple-precision mode, all formats ----------------
def gen_multiple(fmt, n):
    info = FORMATS[fmt]
    cls, ew = info['cls'], info['ew']
    nlanes = LANES_OF_CLS[cls]
    for _ in range(n):
        a_lanes = [rand_bits(fmt, random) for _ in range(4)]
        b_lanes = [rand_bits(fmt, random) for _ in range(4)]
        c_lanes = [rand_bits(fmt, random) for _ in range(4)]
        res_lanes = []
        for i in range(4):
            if i < nlanes:
                r = fma_accumulate(a_lanes[i], fmt, [(b_lanes[i], c_lanes[i], fmt)], fmt)
            else:
                r = 0
            res_lanes.append(r)
        a_bus = pack_lanes_to_bus(a_lanes, cls)
        b_bus = pack_lanes_to_bus(b_lanes, cls)
        c_bus = pack_lanes_to_bus(c_lanes, cls)
        exp_bus = pack_lanes_to_bus(res_lanes, cls)
        add_line(0, cls, cls, ew, ew, a_bus, b_bus, c_bus, exp_bus, f"MUL_{fmt}")


for fmt in FORMATS:
    gen_multiple(fmt, 40)

# ---------------- Category 2: mixed-precision mode, all supported combos ----------------
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


def gen_mixed(addend_fmt, prod_fmt, n):
    a_info = FORMATS[addend_fmt]
    p_info = FORMATS[prod_fmt]
    a_cls, a_ew = a_info['cls'], a_info['ew']
    p_cls, p_ew = p_info['cls'], p_info['ew']
    nprod = LANES_OF_CLS[p_cls]
    for _ in range(n):
        a_bits = rand_bits(addend_fmt, random)
        b_lanes = [rand_bits(prod_fmt, random) for _ in range(4)]
        c_lanes = [rand_bits(prod_fmt, random) for _ in range(4)]
        pairs = [(b_lanes[i], c_lanes[i], prod_fmt) for i in range(nprod)]
        result = fma_accumulate(a_bits, addend_fmt, pairs, addend_fmt)

        a_bus = pack_lanes_to_bus([a_bits], a_cls)
        b_bus = pack_lanes_to_bus(b_lanes, p_cls)
        c_bus = pack_lanes_to_bus(c_lanes, p_cls)
        exp_bus = pack_lanes_to_bus([result], a_cls)
        add_line(1, a_cls, p_cls, a_ew, p_ew, a_bus, b_bus, c_bus, exp_bus,
                  f"MIX_{addend_fmt}_{prod_fmt}")


for (afmt, pfmt) in MIXED_COMBOS:
    gen_mixed(afmt, pfmt, 40)

# ---------------- Category 3: directed edge cases ----------------
def directed():
    # E4M3 normal-mode: 0 + 0*0 = 0
    cls, ew = FORMATS['E4M3']['cls'], FORMATS['E4M3']['ew']
    a_bus = pack_lanes_to_bus([0, 0, 0, 0], cls)
    exp_bus = pack_lanes_to_bus([0, 0, 0, 0], cls)
    add_line(0, cls, cls, ew, ew, a_bus, a_bus, a_bus, exp_bus, "DIR_E4M3_allzero")

    # HP + 4xE4M3 mixed: all-zero addend/products -> zero
    acls, aew = FORMATS['HP']['cls'], FORMATS['HP']['ew']
    pcls, pew = FORMATS['E4M3']['cls'], FORMATS['E4M3']['ew']
    a_bus = pack_lanes_to_bus([0], acls)
    b_bus = pack_lanes_to_bus([0, 0, 0, 0], pcls)
    exp_bus = pack_lanes_to_bus([0], acls)
    add_line(1, acls, pcls, aew, pew, a_bus, b_bus, b_bus, exp_bus, "DIR_HP_E4M3_allzero")

    # mixed: addend dominates hugely, products are tiny -> result approx addend
    from golden_model import fma_accumulate
    a_bits = 0b0_11101_1111111111  # HP: large positive normal
    prod_zero = 0
    b_lanes = [prod_zero] * 4
    c_lanes = [prod_zero] * 4
    result = fma_accumulate(a_bits, 'HP', [(prod_zero, prod_zero, 'E4M3')] * 4, 'HP')
    a_bus = pack_lanes_to_bus([a_bits], acls)
    b_bus = pack_lanes_to_bus(b_lanes, pcls)
    exp_bus = pack_lanes_to_bus([result], acls)
    add_line(1, acls, pcls, aew, pew, a_bus, b_bus, b_bus, exp_bus, "DIR_HP_addend_dominates")

    # mixed: 4 products with alternating sign that should mostly cancel
    a_bits = 0  # zero addend
    b_lanes = [0b0_0110_001, 0b1_0110_001, 0b0_0101_010, 0b1_0101_010]  # E4M3 +v,-v,+w,-w
    c_lanes = [0b0_0111_000, 0b0_0111_000, 0b0_0111_000, 0b0_0111_000]  # E4M3 *1.0-ish
    result = fma_accumulate(a_bits, 'HP',
                             [(b_lanes[i], c_lanes[i], 'E4M3') for i in range(4)], 'HP')
    a_bus = pack_lanes_to_bus([a_bits], acls)
    b_bus = pack_lanes_to_bus(b_lanes, pcls)
    c_bus = pack_lanes_to_bus(c_lanes, pcls)
    exp_bus = pack_lanes_to_bus([result], acls)
    add_line(1, acls, pcls, aew, pew, a_bus, b_bus, c_bus, exp_bus, "DIR_HP_cancel")

    # SP + 2x HP mixed, subnormal HP product operand
    acls2, aew2 = FORMATS['SP']['cls'], FORMATS['SP']['ew']
    pcls2, pew2 = FORMATS['HP']['cls'], FORMATS['HP']['ew']
    a_bits2 = 0
    b_lanes2 = [0b0_00000_0000000001, 0b0_01111_0000000000]  # subnormal, 1.0
    c_lanes2 = [0b0_01111_0000000000, 0b0_01111_0000000000]  # 1.0, 1.0
    result2 = fma_accumulate(a_bits2, 'SP',
                              [(b_lanes2[i], c_lanes2[i], 'HP') for i in range(2)], 'SP')
    a_bus2 = pack_lanes_to_bus([a_bits2], acls2)
    b_bus2 = pack_lanes_to_bus(b_lanes2, pcls2)
    c_bus2 = pack_lanes_to_bus(c_lanes2, pcls2)
    exp_bus2 = pack_lanes_to_bus([result2], acls2)
    add_line(1, acls2, pcls2, aew2, pew2, a_bus2, b_bus2, c_bus2, exp_bus2, "DIR_SP_HP_subnorm")


directed()

random.shuffle(lines)
with open(OUT_PATH, 'w') as f:
    f.write(f"{len(lines)}\n")
    for l in lines:
        f.write(l + "\n")

print(f"wrote {len(lines)} vectors to {OUT_PATH}")
