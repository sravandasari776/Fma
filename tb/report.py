#!/usr/bin/env python3
"""Human-readable verification report for U_FMA.

Reads
  tb/vectors.txt              the test vectors + golden expected results
  tb/out/sim_results.txt      what the RTL produced (written by tb_fma_top.v)
  tb/unit/out/logs/*.log      per-block unit-test transcripts (run_unit.sh)
and prints a summary to the terminal and writes a Markdown report
(docs/VERIFICATION_REPORT.md for the full regression).

Every result is decoded from hex into ordinary decimal numbers, so a line
such as "HP: 1.5 + 2 x 3 = 7.5" can be read without knowing the bit layout.

Usage: python3 tb/report.py [--vectors FILE] [--results FILE] [--md FILE]
"""
import argparse
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import (  # noqa: E402
    FORMATS, LANES_OF_CLS, unpack, unpack_lanes_from_bus, exact_value, is_rounding_tie,
)

TB_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TB_DIR)

FMT_OF = {(0, 4): 'E4M3', (0, 5): 'E5M2', (1, 5): 'HP', (1, 6): 'DLFloat16',
          (1, 8): 'BFloat16', (2, 8): 'SP', (3, 8): 'TF32'}
FMT_ORDER = ['E4M3', 'E5M2', 'HP', 'DLFloat16', 'BFloat16', 'TF32', 'SP']

CATEGORY_TEXT = OrderedDict([
    ('MUL', 'Random A+B*C per lane (half with A close to B*C -> cancellation)'),
    ('MIX', 'Random A + sum(Bi*Ci) dot products (half clustered)'),
    ('SPECIAL', 'NaN / +-Inf / +-0 / largest / smallest operands'),
    ('SPECIALMIX', 'NaN / +-Inf / +-0 / extremes in mixed mode'),
    ('CANCEL', 'A = -round(B*C): result is the product\'s rounding error'),
    ('CANCELMIX', 'A = -round(sum of products): massive cancellation'),
    ('TIE', 'Exact result exactly halfway between two neighbours (ties-to-even)'),
    ('OVF', 'Operands near the top of the range (overflow to Inf)'),
    ('UNF', 'Operands near the bottom (subnormal / zero results)'),
    ('HEADROOM', 'Addend + all products maximal, same sign (accumulator overflow)'),
    ('ANCHOR', 'Each product lane the largest in turn, tied exponents, addend largest'),
    ('DIR', 'Hand-written directed cases, incl. one per bug fixed'),
])

# design bugs found during verification (docs/DEVIATIONS.md has the details)
BUGS = [
    ('B1', 'SP products cut to 24 bits: guard bit lost, 1 ULP low',
     'stage1_exp_align_controller.v, fma_top.v, fma_lane_pipe.v', 'DIR_BUG1_SP_product_guard'),
    ('B2', 'Subnormal results truncated instead of rounded (double rounding)',
     'stage4_normalization.v, stage4_output_finalize.v', 'DIR_BUG2_E5M2_subnormal_round'),
    ('B3', 'Sign of a lost (sticky) remainder wrong for negated terms: 1 ULP high',
     'align_shifter.v, stage2_invert_swap.v', 'DIR_BUG3_sticky_sign'),
    ('B4', 'Accumulator overflow: 1.75 + 4 x 1.75 gave -7.25 instead of 8.75',
     'fma_defs.vh (76-bit frame, 3 headroom bits)', 'DIR_BUG4_headroom_pos'),
    ('B5', 'Exact FMA cancellation broken: -(1+2^-22) + (1+2^-23)^2 gave 2^-36, not 2^-46',
     'stage1_exp_align_controller.v (exact 48-bit product)', 'DIR_BUG5_SP_exact_cancel'),
    ('B6', '-Inf addend produced +Inf',
     'fma_lane_pipe.v, stage4_sign_detection.v', 'DIR_BUG6_neg_inf'),
    ('B7', 'Inf + (-Inf) produced Inf instead of NaN',
     'fma_lane_pipe.v', 'DIR_BUG7_inf_minus_inf'),
    ('B8', '-0 + (-0)*x produced +0 instead of -0',
     'fma_lane_pipe.v, stage4_sign_detection.v', 'DIR_BUG8_neg_zero'),
]


# ---------------------------------------------------------------- decoding

def num(v):
    """Short decimal text for a Fraction / float."""
    if v == 0:
        return '0'
    f = float(v)
    if f == int(f) and abs(f) < 1e7:
        return '%d' % f
    return '%.7g' % f


def val_text(bits, fmt):
    """Decoded value of one encoded operand/result, e.g. '-2.5', '+Inf', 'NaN', '-0'."""
    v = unpack(bits, fmt)
    if v.kind == 'nan':
        return 'NaN'
    if v.kind == 'inf':
        return '-Inf' if v.sign else '+Inf'
    if v.kind == 'zero':
        return '-0' if v.sign else '0'
    s = num(v.mag)
    sub = ((bits >> FORMATS[fmt]['m']) & ((1 << FORMATS[fmt]['ew']) - 1)) == 0
    return ('-' if v.sign else '') + s + (' (subnormal)' if sub else '')


def hexw(bits, fmt):
    return '0x%0*x' % ((FORMATS[fmt]['total'] + 3) // 4, bits)


class Vec(object):
    def __init__(self, idx, line):
        f = line.split()
        self.idx = idx
        self.mix, self.pra, self.prm, self.ewa, self.ewm = [int(x) for x in f[:5]]
        self.a, self.b, self.c = [int(x, 16) for x in f[5:8]]
        self.exp = int(f[8], 16)
        self.label = f[9]
        self.cat = self.label.split('_')[0]
        self.afmt = FMT_OF[(self.pra, self.ewa)]
        self.pfmt = FMT_OF[(self.prm, self.ewm)]
        self.got = None
        self.passed = None

    def n_lanes(self):
        return 1 if self.mix else LANES_OF_CLS[FORMATS[self.afmt]['cls']]

    def mode_text(self):
        if self.mix:
            n = LANES_OF_CLS[FORMATS[self.pfmt]['cls']]
            return 'Mixed    %s + %d x %s' % (self.afmt, n, self.pfmt)
        return 'Multiple %s (%d lane%s)' % (self.afmt, self.n_lanes(), 's' if self.n_lanes() > 1 else '')

    def lane_ops(self):
        """(pairs, a_bits, a_fmt, out_fmt) for each result lane."""
        ops = []
        if self.mix:
            np_ = LANES_OF_CLS[FORMATS[self.pfmt]['cls']]
            bl = unpack_lanes_from_bus(self.b, FORMATS[self.pfmt]['cls'])
            cl = unpack_lanes_from_bus(self.c, FORMATS[self.pfmt]['cls'])
            a0 = unpack_lanes_from_bus(self.a, FORMATS[self.afmt]['cls'])[0]
            ops.append(([(bl[i], cl[i], self.pfmt) for i in range(np_)], a0))
        else:
            cls = FORMATS[self.afmt]['cls']
            al, bl, cl = [unpack_lanes_from_bus(x, cls) for x in (self.a, self.b, self.c)]
            for i in range(self.n_lanes()):
                ops.append(([(bl[i], cl[i], self.afmt)], al[i]))
        return ops

    def has_subnormal_operand(self):
        def sub(bits, fmt):
            info = FORMATS[fmt]
            return ((bits >> info['m']) & ((1 << info['ew']) - 1)) == 0 and (bits & ((1 << info['m']) - 1)) != 0
        for pairs, a in self.lane_ops():
            if sub(a, self.afmt):
                return True
            for (b, c, f) in pairs:
                if sub(b, f) or sub(c, f):
                    return True
        return False

    def is_tie(self):
        for pairs, a in self.lane_ops():
            if is_rounding_tie(exact_value(a, self.afmt, pairs), self.afmt):
                return True
        return False

    def readability(self, lane=0):
        """Lower is easier to read: every operand a plain normal number of
        moderate size, no zero/subnormal/special operands, a normal result."""
        pairs, a = self.lane_ops()[lane]
        vals = [(a, self.afmt)] + [(b, f) for (b, c, f) in pairs] + [(c, f) for (b, c, f) in pairs]
        score = 0
        for bits, fmt in vals:
            v = unpack(bits, fmt)
            info = FORMATS[fmt]
            sub = ((bits >> info['m']) & ((1 << info['ew']) - 1)) == 0
            if v.kind != 'normal' or sub:
                score += 10
            elif not (1e-2 <= float(v.mag) <= 1e3):
                score += 3
            elif float(v.mag) * 64 != int(float(v.mag) * 64):
                score += 1          # prefer short fractions like 1.5, 0.375
        e = unpack(unpack_lanes_from_bus(self.exp, FORMATS[self.afmt]['cls'])[lane], self.afmt)
        if e.kind != 'normal':
            score += 10
        return score

    def explain(self, lane=0):
        """One line: 'A + B*C = exact -> expected (hex) | RTL got (hex) PASS'."""
        pairs, a = self.lane_ops()[lane]
        of = self.afmt
        terms = ' + '.join('(%s x %s)' % (val_text(b, f), val_text(c, f)) for (b, c, f) in pairs)
        ex = exact_value(a, of, pairs)
        exact = num(ex) if ex is not None else 'special'
        cls = FORMATS[of]['cls']
        e_l = unpack_lanes_from_bus(self.exp, cls)[lane]
        g_l = unpack_lanes_from_bus(self.got, cls)[lane] if self.got is not None else None
        ok = (g_l == e_l)
        rtl = ('%s = %s' % (hexw(g_l, of), val_text(g_l, of))) if g_l is not None else 'not simulated'
        return ('%s + %s\n      exact = %s  -> correctly rounded %s = %s  |  RTL: %s  %s'
                % (val_text(a, of), terms, exact, hexw(e_l, of), val_text(e_l, of), rtl,
                   'PASS' if ok else 'FAIL'))


# ---------------------------------------------------------------- loading

def load_vectors(path):
    with open(path) as f:
        lines = f.read().split('\n')
    n = int(lines[0])
    return [Vec(i, lines[1 + i]) for i in range(n)]


def load_results(path, vecs):
    if not os.path.exists(path):
        return False
    for line in open(path):
        p = line.split()
        if len(p) != 4:
            continue
        i = int(p[0])
        if i < len(vecs):
            vecs[i].got = int(p[1], 16)
            vecs[i].passed = (p[3] == 'P')
    return True


def load_unit_logs(log_dir):
    rows = []
    if not os.path.isdir(log_dir):
        return rows
    for fn in sorted(os.listdir(log_dir)):
        if not fn.endswith('.log'):
            continue
        txt = open(os.path.join(log_dir, fn), errors='replace').read()
        m = re.findall(r'SUMMARY (\S+) : (\d+) checks \| (\d+) PASS \| (\d+) FAIL \| (BLOCK \w+)', txt)
        title = re.findall(r'UNIT TEST : (.*)', txt)
        if m:
            name, checks, p, f, res = m[-1]
            rows.append((name, int(checks), int(p), int(f), res, title[0].strip() if title else ''))
        else:
            rows.append((fn[:-4], 0, 0, 0, 'DID NOT RUN', ''))
    return rows


# ---------------------------------------------------------------- analysis

def tally(vs):
    n = len(vs)
    p = sum(1 for v in vs if v.passed)
    ops = sum(v.n_lanes() for v in vs)
    return n, p, n - p, ops


def status(vs, unit_ok=True):
    if not vs:
        return 'n/a'
    n, p, f, _ = tally(vs)
    return 'PASS' if (f == 0 and unit_ok) else 'FAIL'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vectors', default=os.path.join(TB_DIR, 'vectors.txt'))
    ap.add_argument('--results', default=os.path.join(TB_DIR, 'out', 'sim_results.txt'))
    ap.add_argument('--unit-logs', default=os.path.join(TB_DIR, 'unit', 'out', 'logs'))
    ap.add_argument('--all-examples', action='store_true', help='print every worked example on the terminal')
    ap.add_argument('--md', default=None, help='Markdown output (default: docs/VERIFICATION_REPORT.md '
                                                'for the full regression, tb/out/report_<name>.md otherwise)')
    args = ap.parse_args()

    full = os.path.abspath(args.vectors) == os.path.join(TB_DIR, 'vectors.txt')
    md_path = args.md or (os.path.join(ROOT, 'docs', 'VERIFICATION_REPORT.md') if full else
                          os.path.join(TB_DIR, 'out', 'report_%s.md' %
                                       os.path.splitext(os.path.basename(args.vectors))[0]))

    vecs = load_vectors(args.vectors)
    if not load_results(args.results, vecs):
        print('No simulation results found (%s) -- run tb/run_sim.sh first.' % args.results)
        return 1
    missing = [v for v in vecs if v.passed is None]
    for v in missing:
        v.passed = False
    units = load_unit_logs(args.unit_logs)
    by_label = {v.label: v for v in vecs}

    out = []      # terminal text
    md = []       # markdown text

    n, p, f, ops = tally(vecs)
    u_blocks = len(units)
    u_pass = sum(1 for u in units if u[3] == 0 and u[4] == 'BLOCK PASSED')
    u_checks = sum(u[1] for u in units)
    unit_ok = (u_blocks > 0 and u_pass == u_blocks)

    # ---------------- headline
    out.append('=' * 78)
    out.append(' U_FMA VERIFICATION REPORT')
    out.append('=' * 78)
    md.append('# U_FMA Verification Report')
    md.append('')
    md.append('Generated by `tb/report.py` from `%s` and the simulator\'s per-vector results. '
              'Every expected value comes from `tb/golden_model.py`, an independent model that '
              'computes `A + B*C` with exact fractions and rounds once (round-to-nearest-even).'
              % os.path.relpath(args.vectors, ROOT))
    md.append('')
    md.append('## Headline')
    md.append('')
    line_u = ('Unit tests  (%d testbenches, one per RTL block):   %d / %d pass  (%s checks)'
              % (u_blocks, u_pass, u_blocks, '{:,}'.format(u_checks))) if units else \
        'Unit tests: not run (tb/unit/run_unit.sh)'
    line_s = ('System test (whole FMA vs golden model):          %s / %s vectors pass  (%s individual FMA results)'
              % ('{:,}'.format(p), '{:,}'.format(n), '{:,}'.format(ops)))
    # the same vectors through the decimal I/O shell (tb/run_sim.sh --shell)
    shell = None
    shell_res = os.path.join(TB_DIR, 'out', 'sim_results_fp64.txt')
    if full and os.path.exists(shell_res):
        rows = [l.split() for l in open(shell_res) if len(l.split()) == 4]
        shell = (sum(1 for r in rows if r[3] == 'P'), len(rows))
    out.append(' ' + line_u)
    out.append(' ' + line_s)
    if shell:
        out.append(' Decimal I/O shell (same vectors in/out as doubles):  %s / %s vectors pass'
                   % ('{:,}'.format(shell[0]), '{:,}'.format(n)))
    shell_ok = (shell is None) or (shell[0] == n)
    verdict = 'ALL PASS' if (f == 0 and (unit_ok or not units) and shell_ok) else 'FAILURES PRESENT'
    out.append(' Overall: %s' % verdict)
    md.append('| What | Result |')
    md.append('|---|---|')
    if units:
        md.append('| Unit tests: %d testbenches, one per RTL block | **%d / %d pass** (%s checks) |'
                  % (u_blocks, u_pass, u_blocks, '{:,}'.format(u_checks)))
    md.append('| System test: whole FMA vs golden model | **%s / %s vectors pass** (%s individual FMA results) |'
              % ('{:,}'.format(p), '{:,}'.format(n), '{:,}'.format(ops)))
    if shell:
        md.append('| Same vectors through the decimal I/O shell (`fma_fp64_top`: operands in and results out '
                  'as IEEE doubles) | **%s / %s vectors pass** |' % ('{:,}'.format(shell[0]), '{:,}'.format(n)))
    md.append('| Overall | **%s** |' % verdict)

    # ---------------- by format / mode
    groups = OrderedDict()
    for fm in FMT_ORDER:
        groups['Multiple ' + fm] = [v for v in vecs if not v.mix and v.afmt == fm]
    combos = []
    for v in vecs:
        if v.mix and (v.afmt, v.pfmt) not in combos:
            combos.append((v.afmt, v.pfmt))
    order = {'HP': 0, 'DLFloat16': 1, 'BFloat16': 2, 'SP': 3, 'TF32': 4}
    combos.sort(key=lambda c: (order.get(c[0], 9), FMT_ORDER.index(c[1])))
    for (af, pf) in combos:
        groups['Mixed ' + af + '+' + pf] = [v for v in vecs if v.mix and v.afmt == af and v.pfmt == pf]

    out.append('')
    out.append(' System test by mode and format')
    out.append(' ' + '-' * 76)
    out.append(' %-44s %8s %9s %7s %6s' % ('Mode / format', 'Vectors', 'FMA ops', 'Pass', 'Fail'))
    md.append('')
    md.append('## System test by mode and format')
    md.append('')
    md.append('*Multiple-precision* = independent `A+B*C` per lane (4 lanes for 8-bit, 2 for 16-bit, 1 for SP/TF32). '
              '*Mixed-precision* = one wide addend plus 4 (8-bit) or 2 (16-bit) products, rounded once.')
    md.append('')
    md.append('| Mode / format | Vectors | FMA results | Pass | Fail |')
    md.append('|---|---:|---:|---:|---:|')
    for name, vs in groups.items():
        if not vs:
            continue
        gn, gp, gf, gops = tally(vs)
        if name.startswith('Multiple'):
            fm = name.split()[1]
            nl = LANES_OF_CLS[FORMATS[fm]['cls']]
            label = 'Multiple-precision  %s  (%d lane%s)' % (fm, nl, 's' if nl > 1 else '')
        else:
            af, pf = name.split()[1].split('+')
            label = 'Mixed-precision     %s + %d x %s' % (af, LANES_OF_CLS[FORMATS[pf]['cls']], pf)
        out.append(' %-44s %8d %9d %7d %6d' % (label, gn, gops, gp, gf))
        md.append('| %s | %d | %d | %d | %d |' % (' '.join(label.split()), gn, gops, gp, gf))
    out.append(' ' + '-' * 76)
    out.append(' %-44s %8d %9d %7d %6d' % ('TOTAL', n, ops, p, f))
    md.append('| **TOTAL** | **%d** | **%d** | **%d** | **%d** |' % (n, ops, p, f))

    # ---------------- by category
    out.append('')
    out.append(' System test by kind of test')
    out.append(' ' + '-' * 76)
    md.append('')
    md.append('## System test by kind of test')
    md.append('')
    md.append('| Category | What it exercises | Vectors | Pass | Fail |')
    md.append('|---|---|---:|---:|---:|')
    for cat, text in CATEGORY_TEXT.items():
        vs = [v for v in vecs if v.cat == cat]
        if not vs:
            continue
        cn, cp, cf, _ = tally(vs)
        out.append(' %-11s %-50s %5d %5d %4d' % (cat, text[:50], cn, cp, cf))
        md.append('| `%s` | %s | %d | %d | %d |' % (cat, text, cn, cp, cf))

    # ---------------- spec sign-off
    def sel(pred):
        return [v for v in vecs if pred(v)]
    eight = ('E4M3', 'E5M2')
    sixteen = ('HP', 'DLFloat16', 'BFloat16')
    wide = ('SP', 'TF32')
    unit_status = {u[0]: (u[3] == 0 and u[4] == 'BLOCK PASSED') for u in units}

    def u(*names):
        return all(unit_status.get(x, False) for x in names) if units else True

    pairs_changed = sum(1 for i in range(1, len(vecs)) if
                        (vecs[i].mix, vecs[i].pra, vecs[i].prm, vecs[i].ewa, vecs[i].ewm) !=
                        (vecs[i - 1].mix, vecs[i - 1].pra, vecs[i - 1].prm, vecs[i - 1].ewa, vecs[i - 1].ewm))
    subn = sel(lambda v: v.has_subnormal_operand())
    ties = sel(lambda v: v.cat in ('TIE', 'MUL', 'MIX', 'CANCEL', 'DIR') and v.is_tie())
    ews = sorted(set(v.ewa for v in vecs) | set(v.ewm for v in vecs))

    spec = [
        ('F01', 'A+B*C correct for every format vs a software golden model',
         sel(lambda v: not v.mix), u(), 'all 7 formats, %d vectors' % len(sel(lambda v: not v.mix))),
        ('F02', '4 parallel 8-bit lanes, independent',
         sel(lambda v: not v.mix and v.afmt in eight), u(), 'E4M3/E5M2, every lane checked'),
        ('F03', '2 parallel 16-bit lanes, independent',
         sel(lambda v: not v.mix and v.afmt in sixteen), u(), 'HP/DLFloat16/BFloat16'),
        ('F04', 'Mixed 1 x 16-bit + 4 x 8-bit (incl. subnormal operands)',
         sel(lambda v: v.mix and v.afmt in sixteen), u(), '6 combinations'),
        ('F05', 'Mixed 1 x 32/19-bit + 4 x 8-bit (incl. tied exponents)',
         sel(lambda v: v.mix and v.afmt in wide and v.pfmt in eight), u(), '4 combinations'),
        ('F06', 'Mixed 1 x 32/19-bit + 2 x 16-bit',
         sel(lambda v: v.mix and v.afmt in wide and v.pfmt in sixteen), u(), '6 combinations'),
        ('F07', 'Comparator: anchor/label for every permutation, ties',
         sel(lambda v: v.cat == 'ANCHOR'), u('stage1_comparator'), 'ANCHOR vectors + comparator unit test'),
        ('F08', 'Subnormal inputs (LZC, relative normalizer)',
         subn, u('stage1_unified_extractor', 'stage1_unified_lzc'), 'vectors with a subnormal operand'),
        ('F09', 'Worst-case overflow of addend + 4 products',
         sel(lambda v: v.cat == 'HEADROOM' or v.label.startswith('DIR_BUG4')), u('stage2_csa4to2'),
         'HEADROOM vectors + CSA unit test'),
        ('F10', 'Round-to-nearest-even incl. ties and rounding carry',
         ties, u('stage4_rounding'), 'vectors whose exact result is a tie + rounding unit test'),
        ('F11', 'Exponent widths ewa/ewm = %s' % ', '.join(str(e) for e in ews),
         vecs, u(), '7 is not used by any supported format'),
        ('F12', 'Back-to-back, 1 op per clock, fixed latency',
         vecs, u('fma_lane_pipe', 'fma_top_directed'), 'every vector issued back-to-back'),
        ('F13', 'Mode/format switching every cycle, no leakage',
         vecs, u(), '%d of %d consecutive vectors change mode/format' % (pairs_changed, len(vecs) - 1)),
    ]
    out.append('')
    out.append(' Spec sign-off checklist (MPFMA-DS-001 section 13.1)')
    out.append(' ' + '-' * 76)
    md.append('')
    md.append('## Spec sign-off checklist (MPFMA-DS-001 section 13.1)')
    md.append('')
    md.append('| ID | Requirement | Evidence | Vectors | Status |')
    md.append('|---|---|---|---:|---|')
    for sid, req, vs, uok, ev in spec:
        st = status(vs, uok)
        out.append(' %s  %-52s %6d  %s' % (sid, req[:52], len(vs), st))
        md.append('| %s | %s | %s | %d | **%s** |' % (sid, req, ev, len(vs), st))
    md.append('')
    md.append('Not covered here: synthesis area/timing sign-off (out of scope for this verification pass).')

    # ---------------- bugs found
    out.append('')
    out.append(' Design bugs found and fixed (details: docs/DEVIATIONS.md)')
    out.append(' ' + '-' * 76)
    md.append('')
    md.append('## Design bugs found and fixed')
    md.append('')
    md.append('Before this work the original 925-vector regression passed 909/925 and the unit tests '
              'did not catch these (each block was correct on its own). Each bug now has its own '
              'regression vector:')
    md.append('')
    md.append('| # | Bug | Fixed in | Regression vector | Now |')
    md.append('|---|---|---|---|---|')
    for bid, text, where, lab in BUGS:
        v = by_label.get(lab)
        st = ('PASS' if v.passed else 'FAIL') if v else 'not in this vector set'
        out.append(' %s  %-62s %s' % (bid, text[:62], st))
        md.append('| %s | %s | `%s` | `%s` | **%s** |' % (bid, text, where, lab, st))

    # ---------------- decoded examples
    out.append('')
    out.append(' Worked examples, decoded (all %s in the Markdown report)' % ('shown' if args.all_examples else 'of them'))
    out.append(' ' + '-' * 76)
    md.append('')
    md.append('## Worked examples, decoded')
    md.append('')
    md.append('One easy-to-read vector per mode/format (lane 0), then every directed case: the operands as '
              'decimal numbers, the exact mathematical answer, the correctly rounded answer the golden '
              'model expects, and what the RTL produced. `(a x b)` is one product B_i*C_i.')
    md.append('')
    shown = []
    for name, vs in groups.items():
        cand = [v for v in vs if v.cat in ('MUL', 'MIX')]
        if cand:
            shown.append(min(cand[:400], key=lambda v: v.readability(0)))
    shown += [v for v in vecs if v.cat == 'DIR']
    console_pick = {'Multiple E4M3', 'Multiple HP', 'Multiple SP', 'Mixed HP+E4M3', 'Mixed SP+HP'}
    md.append('```')
    for v in shown:
        head = '[%s] %s' % (v.label, v.mode_text())
        body = v.explain(0)
        key = ('Mixed %s+%s' % (v.afmt, v.pfmt)) if v.mix else ('Multiple %s' % v.afmt)
        if args.all_examples or (v.cat != 'DIR' and key in console_pick) or v.label.startswith('DIR_BUG4'):
            out.append(' ' + head)
            out.append('   ' + body)
        md.append(head)
        md.append('   ' + body)
        md.append('')
    md.append('```')

    # ---------------- failures
    fails = [v for v in vecs if not v.passed]
    out.append('')
    md.append('')
    md.append('## Mismatches')
    md.append('')
    if not fails:
        out.append(' Mismatches: none.')
        md.append('None: every vector matched the golden model bit for bit.')
    else:
        out.append(' Mismatches (first 20 of %d), decoded:' % len(fails))
        md.append('%d vector%s did not match (first 50 shown, decoded):' % (len(fails), '' if len(fails) == 1 else 's'))
        md.append('')
        md.append('```')
        for v in fails[:50]:
            if v.got is None:
                t = '[%d %s] no result from the simulator' % (v.idx, v.label)
                lines = [t]
            else:
                cls = FORMATS[v.afmt]['cls']
                lanes = [i for i in range(v.n_lanes()) if
                         unpack_lanes_from_bus(v.exp, cls)[i] != unpack_lanes_from_bus(v.got, cls)[i]]
                lines = ['[%d %s] %s, lane %d:' % (v.idx, v.label, v.mode_text(), i) for i in lanes[:1]]
                lines += ['   ' + v.explain(lanes[0])] if lanes else []
            if len(out) < 10000 and fails.index(v) < 20:
                out.extend(' ' + l for l in lines)
            md.extend(lines)
        md.append('```')

    # ---------------- unit tests
    if units and not args.all_examples:
        bad = [x for x in units if not (x[3] == 0 and x[4] == 'BLOCK PASSED')]
        out.append('')
        out.append(' Unit tests: %d / %d blocks pass%s  (per-block table in the Markdown report)'
                   % (u_pass, u_blocks, '' if not bad else '  -- FAILING: ' + ', '.join(x[0] for x in bad)))
    if units:
        if args.all_examples:
            out.append('')
            out.append(' Unit tests (tb/unit/run_unit.sh), one testbench per RTL block')
            out.append(' ' + '-' * 76)
        md.append('')
        md.append('## Unit tests: one testbench per RTL block')
        md.append('')
        md.append('Each block is driven on its own and checked against a small reference model written '
                  'inside its testbench; readable transcripts are in `tb/unit/out/logs/<block>.log`.')
        md.append('')
        md.append('| Block | What the test checks | Checks | Pass | Fail | Result |')
        md.append('|---|---|---:|---:|---:|---|')
        for name, c, pp, ff, res, title in units:
            if args.all_examples:
                out.append(' %-34s %7d %7d %5d   %s' % (name, c, pp, ff, res))
            md.append('| `%s` | %s | %d | %d | %d | **%s** |' % (name, title.replace('|', '/'), c, pp, ff, res))

    out.append('')
    out.append(' Markdown report written to: %s' % os.path.relpath(md_path, os.getcwd()))
    out.append('=' * 78)
    print('\n'.join(out))
    d = os.path.dirname(md_path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(md_path, 'w') as fh:
        fh.write('\n'.join(md) + '\n')
    return 0 if verdict == 'ALL PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
