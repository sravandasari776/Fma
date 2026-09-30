#!/usr/bin/env python3
"""Try U_FMA on your own numbers and get a worksheet you can check by hand.

The paper's FMA computes   result = round( A + B*C )            (multiple-precision)
                    or     result = round( A + sum_i Bi*Ci )    (mixed-precision)
with ONE round-to-nearest-even at the end (IEEE 754). For every case this
script writes out that math step by step -- operands in binary, the exact
sum, the guard/sticky rounding decision, the packed result -- then runs the
same inputs through the real RTL (fma_top, via tb/run_sim.sh) and shows
the hardware's output next to it.

Examples
  python3 tb/try_fma.py SP 1.5 2 3                 # A + B*C in single precision
  python3 tb/try_fma.py HP 1 2 3  0.5 -4 0.25      # 2 HP lanes: 1+2*3 and 0.5+(-4)*0.25
  python3 tb/try_fma.py E4M3 1 2 3                 # 8-bit (up to 4 lanes = 12 numbers)
  python3 tb/try_fma.py SP+E4M3 1  2 3  -1 0.5  1.5 1  0.25 1
                                                   # mixed: A + B0*C0 + B1*C1 + B2*C2 + B3*C3
  python3 tb/try_fma.py --file my_cases.txt        # one case per line, same syntax, # = comment
  python3 tb/try_fma.py SP 1.5 2 3 --gui           # also open the waveform in SimVision

Numbers: decimals (1.5, -0.1, 1e-3, 3/4), inf, -inf, nan, -0, or a raw
encoding in hex (0x3E00). A decimal the format cannot hold exactly (0.1,
say) is first rounded to the nearest value it can hold -- shown as
"stored as" -- because that is what the hardware receives.
Formats: E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP  (also fp16, bf16, fp32).
Mixed combinations (from the paper): HP/DLFloat16/BFloat16 + E4M3/E5M2,
SP/TF32 + E4M3/E5M2, SP/TF32 + HP/DLFloat16/BFloat16.

The worksheet is also saved to tb/out/try_fma_worksheet.txt.
"""
import os
import subprocess
import sys
from fractions import Fraction

TB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TB_DIR)
from golden_model import (  # noqa: E402
    FORMATS, LANES_OF_CLS, unpack, pack, bias_of, fma_accumulate,
    pack_lanes_to_bus, unpack_lanes_from_bus,
)

ALIASES = {'e4m3': 'E4M3', 'e5m2': 'E5M2', 'hp': 'HP', 'fp16': 'HP', 'half': 'HP',
           'dlfloat16': 'DLFloat16', 'dlf16': 'DLFloat16', 'bfloat16': 'BFloat16',
           'bf16': 'BFloat16', 'tf32': 'TF32', 'sp': 'SP', 'fp32': 'SP', 'single': 'SP'}
MIXED_OK = {(a, p) for a in ('HP', 'DLFloat16', 'BFloat16') for p in ('E4M3', 'E5M2')} | \
           {(a, p) for a in ('SP', 'TF32') for p in ('E4M3', 'E5M2', 'HP', 'DLFloat16', 'BFloat16')}
CLASS_NAME = {0: '8-bit', 1: '16-bit', 2: '32-bit', 3: '19-bit'}


class UsageError(Exception):
    pass


# ------------------------------------------------------------------ helpers

def fmt_name(s):
    f = ALIASES.get(s.lower())
    if not f:
        raise UsageError("unknown format '%s' (use E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP)" % s)
    return f


def dec(fr):
    """Exact decimal text of a Fraction when short, else 17 significant digits."""
    if fr == 0:
        return '0'
    sign = '-' if fr < 0 else ''
    fr = abs(fr)
    d = fr.denominator
    k = d.bit_length() - 1
    if d == 1 << k:                        # every value here is n / 2^k
        s = str(fr.numerator * 5 ** k).rjust(k + 1, '0')
        if k:
            s = (s[:-k] + '.' + s[-k:]).rstrip('0').rstrip('.')
        if len(s.replace('.', '').lstrip('0')) <= 24:
            return sign + s
    return sign + '%.17g' % float(fr)


def log2_floor(mag):
    e = mag.numerator.bit_length() - mag.denominator.bit_length()
    while Fraction(2) ** e > mag:
        e -= 1
    while Fraction(2) ** (e + 1) <= mag:
        e += 1
    return e


def bin_digits(fr, n):
    """First n binary digits of fr (0 <= fr < 1); returns (digits, remainder)."""
    s = ''
    for _ in range(n):
        fr *= 2
        if fr >= 1:
            s += '1'
            fr -= 1
        else:
            s += '0'
    return s, fr


def fields(bits, fmt):
    info = FORMATS[fmt]
    ew, m, total = info['ew'], info['m'], info['total']
    s = (bits >> (total - 1)) & 1
    e = (bits >> m) & ((1 << ew) - 1)
    mt = bits & ((1 << m) - 1)
    return '%d | %s | %s' % (s, format(e, '0%db' % ew), format(mt, '0%db' % m) if m else '')


def hexw(bits, fmt):
    return '0x%0*X' % ((FORMATS[fmt]['total'] + 3) // 4, bits)


def value_text(bits, fmt):
    v = unpack(bits, fmt)
    if v.kind == 'nan':
        return 'NaN'
    if v.kind == 'inf':
        return '-Inf' if v.sign else '+Inf'
    if v.kind == 'zero':
        return '-0' if v.sign else '0'
    return dec(-v.mag if v.sign else v.mag)


def sci_binary(bits, fmt):
    """e.g. '+1.1000000000b x 2^0' (normal) or '+0.0000000001b x 2^-14' (subnormal)."""
    info = FORMATS[fmt]
    ew, m, total = info['ew'], info['m'], info['total']
    v = unpack(bits, fmt)
    if v.kind != 'normal':
        return {'zero': 'zero', 'inf': 'infinity (exponent all ones, mantissa 0)',
                'nan': 'NaN (exponent all ones, mantissa not 0)'}[v.kind]
    s = '-' if v.sign else '+'
    e = (bits >> m) & ((1 << ew) - 1)
    mt = format(bits & ((1 << m) - 1), '0%db' % m) if m else ''
    if e == 0:
        return '%s0.%sb x 2^%d  (subnormal)' % (s, mt, 1 - bias_of(ew))
    return '%s1.%sb x 2^%d' % (s, mt, e - bias_of(ew))


def encode(text, fmt):
    """User text -> (bits, note). Decimals are rounded to nearest-even in fmt."""
    t = text.strip()
    tl = t.lower()
    info = FORMATS[fmt]
    if tl in ('inf', '+inf', 'infinity'):
        return pack(0, 'inf', None, fmt), ''
    if tl in ('-inf', '-infinity'):
        return pack(1, 'inf', None, fmt), ''
    if tl in ('nan', '+nan', '-nan'):
        return pack(0, 'nan', None, fmt), ''
    if tl.startswith('0x'):
        bits = int(t, 16)
        if bits >> info['total']:
            raise UsageError("%s does not fit in %d-bit %s" % (t, info['total'], fmt))
        return bits, ''
    try:
        v = Fraction(t)
    except (ValueError, ZeroDivisionError):
        raise UsageError("cannot read the number '%s'" % text)
    sign = 1 if (v < 0 or t.startswith('-')) else 0
    if v == 0:
        return pack(sign, 'zero', None, fmt), ''
    bits = pack(sign, 'normal', abs(v), fmt)
    stored = unpack(bits, fmt)
    if stored.kind == 'inf':
        return bits, 'too large for %s -> stored as %sInf' % (fmt, '-' if sign else '+')
    sv = -stored.mag if stored.sign else (stored.mag if stored.kind == 'normal' else Fraction(0))
    if sv != v:
        return bits, 'not exactly representable in %s -> stored as %s (the nearest %s value)' % (fmt, dec(sv), fmt)
    return bits, ''


# ------------------------------------------------------------------ worksheet math

def round_worksheet(total, fmt, out):
    """Write the round-to-nearest-even steps for exact value `total` into `out`;
    return the packed bits."""
    info = FORMATS[fmt]
    ew, m, width = info['ew'], info['m'], info['total']
    bias = bias_of(ew)
    emin, emax = 1 - bias, (1 << ew) - 2 - bias
    sign = 1 if total < 0 else 0
    sg = '-' if sign else '+'
    mag = abs(total)
    e = log2_floor(mag)
    E = max(e, emin)
    scaled = mag / Fraction(2) ** E            # [1,2) normal, [0,1) subnormal
    lead = 1 if scaled >= 1 else 0
    kept, rem = bin_digits(scaled - lead, m)
    guard = 1 if rem >= Fraction(1, 2) else 0
    rest = rem * 2 - guard
    sticky = 1 if rest != 0 else 0
    preview, left = bin_digits(rest, 12)
    kept_int = (lead << m) | (int(kept, 2) if m else 0)

    out.append('    Write the exact value as 1.xxx x 2^e and cut it after %d mantissa bits'
               ' (shown as  kept bits | guard bit | rest):' % m)
    if e < emin:
        out.append('    (its exponent %d is below %s\'s minimum %d, so it is written as 0.xxx x 2^%d: subnormal)'
                   % (e, fmt, emin, emin))
    out.append('      %s%d.%s | %d | %s%s  x 2^%d' % (sg, lead, kept, guard, preview,
                                                      '...' if left else '', E))
    if guard == 0 and sticky == 0:
        up, why = 0, 'nothing below the kept bits -> exact, no rounding needed'
    elif guard == 0:
        up, why = 0, 'guard bit 0 -> less than half a step -> round DOWN (drop the rest)'
    elif sticky:
        up, why = 1, 'guard bit 1 and more 1s after it -> more than half a step -> round UP'
    elif kept_int & 1:
        up, why = 1, 'exactly half a step (tie), last kept bit is 1 (odd) -> round UP to even'
    else:
        up, why = 0, 'exactly half a step (tie), last kept bit is 0 (even) -> stay (round to even)'
    out.append('    Rounding: guard=%d, sticky=%d: %s' % (guard, sticky, why))

    res = kept_int + up
    if res >> (m + 1):                          # 1.111..1 + 1 = 10.000..0
        res >>= 1
        E += 1
        out.append('    Rounding carried into a new leading bit -> shift right, exponent +1')
    if E > emax:
        bits = (sign << (width - 1)) | (((1 << ew) - 1) << m)
        out.append('    Exponent %d is above %s\'s maximum %d -> overflow -> %sInf' % (E, fmt, emax, sg))
        out.append('    Pack: %s  -> %s' % (fields(bits, fmt), hexw(bits, fmt)))
        return bits
    normal = (res >> m) & 1
    expf = E + bias if normal else 0
    mant = res & ((1 << m) - 1)
    bits = (sign << (width - 1)) | (expf << m) | mant
    val = Fraction(res, 1 << m) * Fraction(2) ** E
    out.append('    Result: %s%d.%sb x 2^%d = %s' % (sg, normal, format(mant, '0%db' % m) if m else '', E,
                                                 dec(-val if sign else val)))
    if normal:
        how = 'exponent field = %d + bias %d = %d' % (E, bias, expf)
    else:
        how = 'subnormal -> exponent field 0'
    out.append('    Pack:   sign | exponent | mantissa = %s   (%s)  -> %s' % (fields(bits, fmt), how, hexw(bits, fmt)))
    return bits


def special_note(a_bits, afmt, pairs):
    """Explain the IEEE special-value rule that applies, or None."""
    av = unpack(a_bits, afmt)
    kinds = [av.kind] + [k for (b, c, f) in pairs for k in (unpack(b, f).kind, unpack(c, f).kind)]
    if 'nan' in kinds:
        return 'an operand is NaN -> the result is NaN'
    for (b, c, f) in pairs:
        kb, kc = unpack(b, f).kind, unpack(c, f).kind
        if (kb == 'inf' and kc == 'zero') or (kc == 'inf' and kb == 'zero'):
            return 'Inf x 0 is undefined -> the result is NaN'
    signs = set()
    if av.kind == 'inf':
        signs.add(av.sign)
    for (b, c, f) in pairs:
        bv, cv = unpack(b, f), unpack(c, f)
        if bv.kind == 'inf' or cv.kind == 'inf':
            signs.add(bv.sign ^ cv.sign)
    if len(signs) == 2:
        return '+Inf and -Inf meet -> undefined -> the result is NaN'
    if signs:
        return 'an infinite term -> the result is %sInf' % ('-' if signs.pop() else '+')
    return None


def signed(bits, fmt):
    v = unpack(bits, fmt)
    return Fraction(0) if v.kind == 'zero' else (-v.mag if v.sign else v.mag)


# ------------------------------------------------------------------ cases

class Case(object):
    pass


def parse_case(tokens, n):
    if not tokens:
        raise UsageError('empty case')
    spec = tokens[0]
    nums = tokens[1:]
    c = Case()
    c.n = n
    if '+' in spec:
        af, pf = [fmt_name(x) for x in spec.split('+', 1)]
        if (af, pf) not in MIXED_OK:
            raise UsageError('mixed %s + %s is not a combination the paper supports' % (af, pf))
        npairs = LANES_OF_CLS[FORMATS[pf]['cls']]
        if len(nums) < 3 or len(nums) % 2 == 0 or (len(nums) - 1) // 2 > npairs:
            raise UsageError('%s: give A then 1..%d pairs B C (%d numbers at most)' % (spec, npairs, 1 + 2 * npairs))
        c.mix, c.afmt, c.pfmt = 1, af, pf
        c.a_txt = nums[0]
        c.pair_txt = [(nums[1 + 2 * i], nums[2 + 2 * i]) for i in range((len(nums) - 1) // 2)]
    else:
        f = fmt_name(spec)
        lanes = LANES_OF_CLS[FORMATS[f]['cls']]
        if not nums or len(nums) % 3 or len(nums) // 3 > lanes:
            raise UsageError('%s: give A B C for 1..%d lane(s) (%d numbers at most)' % (spec, lanes, 3 * lanes))
        c.mix, c.afmt, c.pfmt = 0, f, f
        c.lane_txt = [tuple(nums[3 * i:3 * i + 3]) for i in range(len(nums) // 3)]
    return c


def build(c):
    """Encode the case into bus values + a vector line."""
    ai, pi = FORMATS[c.afmt], FORMATS[c.pfmt]
    zero_a, zero_p = pack(0, 'zero', None, c.afmt), pack(0, 'zero', None, c.pfmt)
    if c.mix:
        c.a_bits, c.a_note = encode(c.a_txt, c.afmt)
        enc = [(encode(b, c.pfmt), encode(cc, c.pfmt)) for (b, cc) in c.pair_txt]
        c.pairs = [(eb[0], ec[0], c.pfmt) for (eb, ec) in enc]
        c.pair_notes = [(eb[1], ec[1]) for (eb, ec) in enc]
        n = LANES_OF_CLS[pi['cls']]
        b_l = [p[0] for p in c.pairs] + [zero_p] * (n - len(c.pairs))
        c_l = [p[1] for p in c.pairs] + [zero_p] * (n - len(c.pairs))
        # unused product lanes are fed 0*0 by the hardware; they count for the
        # signed-zero rule, so the reference result includes them too
        c.calc_pairs = c.pairs + [(zero_p, zero_p, c.pfmt)] * (n - len(c.pairs))
        exp = fma_accumulate(c.a_bits, c.afmt, c.calc_pairs, c.afmt)
        c.lanes = [(c.a_bits, c.pairs)]
        c.a_bus = pack_lanes_to_bus([c.a_bits], ai['cls'])
        c.b_bus = pack_lanes_to_bus(b_l, pi['cls'])
        c.c_bus = pack_lanes_to_bus(c_l, pi['cls'])
        c.exp_bus = pack_lanes_to_bus([exp], ai['cls'])
    else:
        n = LANES_OF_CLS[ai['cls']]
        c.lanes, c.notes = [], []
        a_l, b_l, c_l, e_l = [], [], [], []
        for (ta, tb, tc) in c.lane_txt:
            (a, na), (b, nb), (cc, nc) = encode(ta, c.afmt), encode(tb, c.afmt), encode(tc, c.afmt)
            c.lanes.append((a, [(b, cc, c.afmt)]))
            c.notes.append((na, nb, nc))
            a_l.append(a); b_l.append(b); c_l.append(cc)
            e_l.append(fma_accumulate(a, c.afmt, [(b, cc, c.afmt)], c.afmt))
        while len(a_l) < n:                       # unused lanes: 0 + 0*0
            a_l.append(zero_a); b_l.append(zero_a); c_l.append(zero_a); e_l.append(zero_a)
        c.a_bus, c.b_bus, c.c_bus = [pack_lanes_to_bus(x, ai['cls']) for x in (a_l, b_l, c_l)]
        c.exp_bus = pack_lanes_to_bus(e_l, ai['cls'])
    c.line = '%d %d %d %d %d %016x %016x %016x %08x DIR_TRY_%d' % (
        c.mix, ai['cls'], pi['cls'], ai['ew'], pi['ew'], c.a_bus, c.b_bus, c.c_bus, c.exp_bus, c.n)


def worksheet(c, got_bus, out):
    ai = FORMATS[c.afmt]
    bar = '=' * 78
    out.append(bar)
    if c.mix:
        k = len(c.pairs)
        expr = 'A + ' + ' + '.join('B%d*C%d' % (i, i) for i in range(k))
        out.append(' Case %d: mixed precision, %s addend + %d x %s products:  %s' % (c.n, c.afmt, k, c.pfmt, expr))
        if len(c.calc_pairs) > k:
            out.append(' (the other %d product lane(s) are fed 0 x 0)' % (len(c.calc_pairs) - k))
    else:
        out.append(' Case %d: multiple precision, %s, %d lane(s):  A + B*C per lane' % (c.n, c.afmt, len(c.lanes)))
    out.append(bar)
    out.append(' FMA ports: mixmode_i=%d  pra_i=%s (%s)  prm_i=%s (%s)  ewa_i=%d  ewm_i=%d'
               % (c.mix, format(ai['cls'], '02b'), CLASS_NAME[ai['cls']], format(FORMATS[c.pfmt]['cls'], '02b'),
                  CLASS_NAME[FORMATS[c.pfmt]['cls']], ai['ew'], FORMATS[c.pfmt]['ew']))
    out.append('            a_i=0x%016X  b_i=0x%016X  c_i=0x%016X' % (c.a_bus, c.b_bus, c.c_bus))
    out.append('            dout_o[31:0] from the RTL = %s'
               % ('0x%08X' % got_bus if got_bus is not None else 'not simulated'))

    got_lanes = unpack_lanes_from_bus(got_bus, ai['cls']) if got_bus is not None else None
    all_ok = True
    for li, (a_bits, pairs) in enumerate(c.lanes):
        calc = c.calc_pairs if c.mix else pairs   # what the hardware actually adds
        if not c.mix and len(c.lanes) > 1:
            out.append('')
            out.append(' --- lane %d ---' % li)
        out.append('')
        out.append(' 1) Inputs as the hardware receives them   (sign | exponent | mantissa)')
        rows = [('A', a_bits, c.afmt, c.a_txt if c.mix else c.lane_txt[li][0],
                 c.a_note if c.mix else c.notes[li][0])]
        for i, (b, cc, f) in enumerate(pairs):
            tb, tc = (c.pair_txt[i] if c.mix else c.lane_txt[li][1:])
            nb, nc = (c.pair_notes[i] if c.mix else c.notes[li][1:])
            nm = ('B%d' % i, 'C%d' % i) if c.mix else ('B', 'C')
            rows += [(nm[0], b, f, tb, nb), (nm[1], cc, f, tc, nc)]
        for (nm, bits, f, typed, note) in rows:
            out.append('    %-3s= %-12s %-6s %-12s = %s' % (nm, value_text(bits, f), f, hexw(bits, f), fields(bits, f)))
            out.append('    %s  = %s' % (' ' * 15, sci_binary(bits, f)))
            if note:
                out.append('    %s  !! you typed %s: %s' % (' ' * 15, typed, note))

        spec = special_note(a_bits, c.afmt, pairs)
        out.append('')
        if spec:
            out.append(' 2) Special values (IEEE 754): %s' % spec)
            hand = fma_accumulate(a_bits, c.afmt, calc, c.afmt)
            out.append('    Result: %s = %s' % (hexw(hand, c.afmt), value_text(hand, c.afmt)))
        else:
            out.append(' 2) Exact math, nothing rounded yet:')
            total = signed(a_bits, c.afmt)
            for i, (b, cc, f) in enumerate(pairs):
                p = signed(b, f) * signed(cc, f)
                total += p
                nm = ('B%d*C%d' % (i, i)) if c.mix else 'B*C'
                out.append('    %-7s = %s x %s = %s' % (nm, value_text(b, f), value_text(cc, f), dec(p)))
            out.append('    %-7s = %s' % ('A + ' + ('sum' if c.mix else 'B*C'), dec(total)))
            out.append('')
            out.append(' 3) Round ONCE to %s (%d mantissa bits, round-to-nearest-even):' % (c.afmt, ai['m']))
            if total == 0:
                hand = fma_accumulate(a_bits, c.afmt, calc, c.afmt)
                out.append('    The exact sum is 0 -> %s (IEEE: -0 only if every term is -0)' % value_text(hand, c.afmt))
            else:
                hand = round_worksheet(total, c.afmt, out)
            gold = fma_accumulate(a_bits, c.afmt, calc, c.afmt)
            if gold != hand:
                out.append('    NOTE: worksheet %s differs from golden model %s' % (hexw(hand, c.afmt), hexw(gold, c.afmt)))
        out.append('')
        step = '3' if spec else '4'
        if got_lanes is None:
            out.append(' %s) RTL: not simulated' % step)
            all_ok = False
            continue
        g = got_lanes[li]
        ok = (g == hand)
        all_ok = all_ok and ok
        out.append(' %s) RTL output: %s = %s   ->  %s' % (step, hexw(g, c.afmt), value_text(g, c.afmt),
                   'MATCHES the hand calculation' if ok else 'DOES NOT MATCH (hand: %s)' % hexw(hand, c.afmt)))
    out.append('')
    return all_ok


# ------------------------------------------------------------------ main

def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    gui = waves = False
    case_tokens, files = [], []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--gui':
            gui = True
        elif a == '--waves':
            waves = True
        elif a == '--file':
            i += 1
            if i >= len(argv):
                raise UsageError('--file needs a file name')
            files.append(argv[i])
        else:
            case_tokens.append(a)
        i += 1
    raw = []
    if case_tokens:
        raw.append(case_tokens)
    for fn in files:
        for line in open(fn):
            line = line.split('#', 1)[0].strip()
            if line:
                raw.append(line.split())
    cases = [parse_case(t, n + 1) for n, t in enumerate(raw)]
    for c in cases:
        build(c)

    out_dir = os.path.join(TB_DIR, 'out')
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    vec = os.path.join(out_dir, 'try_fma_vectors.txt')
    with open(vec, 'w') as f:
        f.write('%d\n' % len(cases))
        for c in cases:
            f.write(c.line + '\n')

    print('Running %d case(s) through the RTL (fma_top) ...' % len(cases))
    cmd = [os.path.join(TB_DIR, 'run_sim.sh'), '--vectors=' + vec, '--no-report']
    if gui:
        cmd.append('--gui')
    elif waves:
        cmd.append('--waves')
    if gui:
        subprocess.call(cmd)
    else:
        subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    got = {}
    res = os.path.join(out_dir, 'sim_results.txt')
    if os.path.exists(res):
        for line in open(res):
            p = line.split()
            if len(p) == 4:
                got[int(p[0])] = int(p[1], 16)
    if not got:
        print('The simulation did not produce results -- see tb/out/sim.log')

    out = []
    ok = True
    for idx, c in enumerate(cases):
        ok = worksheet(c, got.get(idx), out) and ok
    out.append('Overall: %s' % ('every RTL output matches the hand calculation' if ok else 'MISMATCH -- see above'))
    text = '\n'.join(out)
    print(text)
    ws = os.path.join(out_dir, 'try_fma_worksheet.txt')
    with open(ws, 'w') as f:
        f.write(text + '\n')
    print('(saved to tb/out/try_fma_worksheet.txt; waveform: add --waves or --gui)')
    return 0 if ok else 1


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except UsageError as e:
        print('try_fma.py: %s\n(run  python3 tb/try_fma.py --help  for examples)' % e)
        sys.exit(2)
