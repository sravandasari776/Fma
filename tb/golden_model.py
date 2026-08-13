"""Bit-exact golden reference model for U_FMA (MPFMA-DS-001).

Independent of the RTL: computes A + B*C (or A + sum(B_i*C_i) in mixed
mode) using exact rational arithmetic (Fraction) and rounds once, to
nearest-even, at the target format's precision -- the textbook-correct
IEEE-754-style answer. Used to generate test vectors and expected results
for tb_fma_top.sv.
"""
from fractions import Fraction
import random

# class ids match fma_pkg::fmt_class_e: CLS_8=0, CLS_16=1, CLS_32=2, CLS_19=3
CLS_8, CLS_16, CLS_32, CLS_19 = 0, 1, 2, 3

FORMATS = {
    'E4M3':      dict(cls=CLS_8,  ew=4, m=3,  total=8),
    'E5M2':      dict(cls=CLS_8,  ew=5, m=2,  total=8),
    'HP':        dict(cls=CLS_16, ew=5, m=10, total=16),
    'DLFloat16': dict(cls=CLS_16, ew=6, m=9,  total=16),
    'BFloat16':  dict(cls=CLS_16, ew=8, m=7,  total=16),
    'SP':        dict(cls=CLS_32, ew=8, m=23, total=32),
    'TF32':      dict(cls=CLS_19, ew=8, m=10, total=19),
}

LANES_OF_CLS = {CLS_8: 4, CLS_16: 2, CLS_32: 1, CLS_19: 1}


def bias_of(ew):
    return (1 << (ew - 1)) - 1


class Val:
    """Decoded operand: sign, and either a special tag or an exact Fraction magnitude."""
    def __init__(self, sign, kind, mag=None):
        self.sign = sign
        self.kind = kind  # 'zero','normal','inf','nan'
        self.mag = mag    # Fraction, magnitude only (>=0), for 'normal'


def unpack(bits, fmt):
    info = FORMATS[fmt]
    ew, m, total = info['ew'], info['m'], info['total']
    bias = bias_of(ew)
    sign = (bits >> (total - 1)) & 1
    expf = (bits >> m) & ((1 << ew) - 1)
    mant = bits & ((1 << m) - 1)
    if expf == 0:
        if mant == 0:
            return Val(sign, 'zero')
        mag = Fraction(mant, 1 << m) * Fraction(2) ** (1 - bias)
        return Val(sign, 'normal', mag)
    elif expf == (1 << ew) - 1:
        if mant != 0:
            return Val(sign, 'nan')
        return Val(sign, 'inf')
    else:
        mag = (1 + Fraction(mant, 1 << m)) * Fraction(2) ** (expf - bias)
        return Val(sign, 'normal', mag)


def pack(sign, kind, mag, fmt):
    """Round-to-nearest-even pack of (sign,kind,mag) into fmt's bit pattern."""
    info = FORMATS[fmt]
    ew, m, total = info['ew'], info['m'], info['total']
    bias = bias_of(ew)
    if kind == 'nan':
        return (sign << (total - 1)) | (((1 << ew) - 1) << m) | 1
    if kind == 'inf':
        return (sign << (total - 1)) | (((1 << ew) - 1) << m)
    if kind == 'zero' or mag == 0:
        return (sign << (total - 1))

    # find exponent e such that mag/2^e in [1,2)
    e = mag.numerator.bit_length() - mag.denominator.bit_length()
    while Fraction(2) ** e > mag:
        e -= 1
    while Fraction(2) ** (e + 1) <= mag:
        e += 1

    if e >= 1 - bias:
        # normal-range rounding
        frac = mag / Fraction(2) ** e - 1  # in [0,1)
        mant_scaled = frac * (1 << m)
        mant_int = mant_scaled.numerator // mant_scaled.denominator
        rem = mant_scaled - mant_int
        if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (mant_int % 2 == 1)):
            mant_int += 1
        expf = e + bias
        if mant_int == (1 << m):
            mant_int = 0
            expf += 1
        if expf >= (1 << ew) - 1:
            return (sign << (total - 1)) | (((1 << ew) - 1) << m)  # overflow -> inf
        return (sign << (total - 1)) | (expf << m) | mant_int
    else:
        # subnormal-range rounding (true correctly-rounded subnormal)
        scale = Fraction(2) ** (1 - bias)
        mant_scaled = mag / scale * (1 << m)
        mant_int = mant_scaled.numerator // mant_scaled.denominator
        rem = mant_scaled - mant_int
        if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (mant_int % 2 == 1)):
            mant_int += 1
        if mant_int >= (1 << m):
            # rounds up into smallest normal
            return (sign << (total - 1)) | (1 << m)
        return (sign << (total - 1)) | mant_int


def signed_val(v):
    """Return signed Fraction (0 for zero), or None for inf/nan."""
    if v.kind in ('inf', 'nan'):
        return None
    if v.kind == 'zero':
        return Fraction(0)
    return -v.mag if v.sign else v.mag


def fma_accumulate(a_bits, a_fmt, pairs, out_fmt):
    """pairs: list of (b_bits,c_bits,fmt) dot-product operand pairs (same fmt).
    Returns packed out_fmt bits for a_bits(a_fmt) + sum(b*c)."""
    av = unpack(a_bits, a_fmt)

    # NaN/Inf propagation (simplified: any NaN -> NaN; Inf (no NaN) -> signed Inf
    # of that operand; 0*Inf treated as NaN).
    any_nan = (av.kind == 'nan')
    inf_sign = None
    for (bb, cb, fmt) in pairs:
        bv = unpack(bb, fmt)
        cv = unpack(cb, fmt)
        if bv.kind == 'nan' or cv.kind == 'nan':
            any_nan = True
        if (bv.kind == 'inf' and cv.kind == 'zero') or (cv.kind == 'inf' and bv.kind == 'zero'):
            any_nan = True
        if bv.kind == 'inf' or cv.kind == 'inf':
            s = (bv.sign ^ cv.sign) if (bv.kind != 'zero' and cv.kind != 'zero') else 0
            inf_sign = s if inf_sign is None else inf_sign
    if av.kind == 'inf':
        inf_sign = av.sign if inf_sign is None else inf_sign

    if any_nan:
        return pack(0, 'nan', None, out_fmt)
    if inf_sign is not None:
        return pack(inf_sign, 'inf', None, out_fmt)

    total = signed_val(av)
    for (bb, cb, fmt) in pairs:
        bv = unpack(bb, fmt)
        cv = unpack(cb, fmt)
        bsv = signed_val(bv)
        csv = signed_val(cv)
        total += bsv * csv

    if total == 0:
        return pack(0, 'zero', None, out_fmt)
    sign = 1 if total < 0 else 0
    return pack(sign, 'normal', abs(total), out_fmt)


# ---------------- packing convention (must match fma_top.sv / fma_funcs.sv) ----------------

def pack_lanes_to_bus(values, cls):
    """values: list of per-lane raw field ints (already in that format's bit width).
    Returns the 64-bit a_i/b_i/c_i style bus value. Padded with 0 if fewer
    values than the class nominally holds are given (e.g. a single mixed-
    precision addend value packed into a 2-lane 16-bit class slot -- only
    lane 0 is meaningful in that case)."""
    values = list(values) + [0] * 4
    if cls == CLS_8:
        r = 0
        for i in range(4):
            r |= (values[i] & 0xFF) << (8 * i)
        return r
    elif cls == CLS_16:
        r = 0
        for i in range(2):
            r |= (values[i] & 0xFFFF) << (16 * i)
        return r
    elif cls == CLS_32:
        return values[0] & 0xFFFFFFFF
    elif cls == CLS_19:
        return values[0] & 0x7FFFF
    raise ValueError(cls)


def unpack_lanes_from_bus(bus, cls):
    if cls == CLS_8:
        return [(bus >> (8 * i)) & 0xFF for i in range(4)]
    elif cls == CLS_16:
        return [(bus >> (16 * i)) & 0xFFFF for i in range(2)]
    elif cls == CLS_32:
        return [bus & 0xFFFFFFFF]
    elif cls == CLS_19:
        return [bus & 0x7FFFF]
    raise ValueError(cls)


# ---------------- random value generation ----------------

def rand_bits(fmt, rng, kind_weights=None):
    info = FORMATS[fmt]
    ew, m, total = info['ew'], info['m'], info['total']
    kinds = ['zero', 'subnormal', 'normal', 'normal', 'normal', 'normal']
    kind = rng.choice(kinds)
    sign = rng.randint(0, 1)
    if kind == 'zero':
        expf, mant = 0, 0
    elif kind == 'subnormal':
        expf = 0
        mant = rng.randint(1, (1 << m) - 1) if m > 0 else 0
    else:
        expf = rng.randint(1, (1 << ew) - 2)
        mant = rng.randint(0, (1 << m) - 1) if m > 0 else 0
    return (sign << (total - 1)) | (expf << m) | mant
