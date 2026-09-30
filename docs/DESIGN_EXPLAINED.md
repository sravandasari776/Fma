# U_FMA Explained: What It Does, How It Works, How We Know It Works

This is the plain-English companion to the RTL. It assumes you know digital design basics, but not floating-point arithmetic. Every number here was produced by the actual RTL in simulation.

---

## 1. The one-paragraph version

U_FMA is a hardware unit that computes **A + B × C** on floating-point numbers, rounded **once**. It can do this in 7 number formats, from tiny 8-bit AI formats up to 32-bit single precision. It has two modes:

- **Multiple-precision mode.** Several *independent* small calculations run side by side: four 8-bit, two 16-bit, or one 32-bit.
- **Mixed-precision mode.** Several low-precision products are added into **one** higher-precision number: `A + B0×C0 + B1×C1 + B2×C2 + B3×C3`. This is the core operation of AI accelerators.

It is a **4-stage pipeline**. It accepts a new operation every clock, and each result comes out 3 clock edges later. It is written in plain Verilog-2005. It was verified against an independent exact-arithmetic model on 10,743 regression vectors (all bit-exact) plus 53,715 extra stress vectors (see §10).

---

## 2. What is an FMA, and why "fused"?

A normal computer does `A + B×C` in two steps: multiply, **round**, add, **round** again. A *fused* multiply-add keeps the product exact and rounds only once, at the very end. That is both more accurate and faster.

Here is a real example from the regression (single precision, SP), where it makes a huge difference:

```
B = C = 1 + 2^-23            (the smallest number above 1.0 in SP)
B×C   = 1 + 2^-22 + 2^-46    (exact)
A     = -(1 + 2^-22)         (= minus B×C rounded to SP)

Unfused:  round(B×C) + A = (1 + 2^-22) - (1 + 2^-22) = 0          <- the 2^-46 is lost
Fused:    A + B×C        = 2^-46 = 1.42e-14 exactly               <- U_FMA's answer (0x28800000)
```

Before this work, the RTL got this wrong (it returned 2⁻³⁶), because it cut the product to 24 bits. That was bug **B5** (§11).

---

## 3. Floating-point numbers in two minutes

A floating-point number has three fields: **sign** (S), **exponent** (E) and **mantissa** (M).

```
 value = (-1)^S  x  1.M  x  2^(E - bias)          normal numbers
 value = (-1)^S  x  0.M  x  2^(1 - bias)          E = 0: "subnormal" (tiny) numbers
 E = all ones:  M = 0 -> +/-Infinity,  M != 0 -> NaN ("not a number")
```

The leading "1." is not stored. It is called the **hidden bit**. `bias = 2^(ew-1) - 1`, where `ew` is the exponent width.

**Example.** HP `0x3E00` = `0 01111 1000000000`: S = 0, E = 15, M = .1 (binary), so the value is 1.1₂ × 2^(15−15) = **1.5**.

The 7 supported formats (paper Table I):

| Format | Bits | S, E, M | Bias | 1.0 is | Largest | Smallest (subnormal) | Used for |
|---|---:|---|---:|---|---|---|---|
| E4M3 | 8 | 1, 4, 3 | 7 | `0x38` | 240 | 0.00195 | AI weights/activations |
| E5M2 | 8 | 1, 5, 2 | 15 | `0x3C` | 57,344 | 1.5e-5 | AI gradients |
| HP (half) | 16 | 1, 5, 10 | 15 | `0x3C00` | 65,504 | 6.0e-8 | graphics, AI |
| DLFloat16 | 16 | 1, 6, 9 | 31 | `0x3E00` | 4.3e9 | 1.8e-12 | IBM AI format |
| BFloat16 | 16 | 1, 8, 7 | 127 | `0x3F80` | 3.4e38 | 9.2e-41 | AI training |
| TF32 | 19 | 1, 8, 10 | 127 | `0x1FC00` | 3.4e38 | 1.1e-41 | NVIDIA tensor cores |
| SP (single) | 32 | 1, 8, 23 | 127 | `0x3F800000` | 3.4e38 | 1.4e-45 | general purpose |

**Rounding.** A result almost never fits exactly in M bits, so it is rounded to the nearest representable number. When it lies *exactly* halfway between two of them, it goes to the one whose last bit is 0. This is called **round-to-nearest-even**. A difference of 1 in the last bit is called **1 ULP** (unit in the last place).

---

## 4. The two modes

```
 MULTIPLE-PRECISION (mixmode_i = 0)             MIXED-PRECISION (mixmode_i = 1)
 independent A+B*C per lane                     one wide A + a dot product of narrow B,C

 8-bit:  lane3  lane2  lane1  lane0             A (16/19/32-bit)
         A3+B3C3 A2+B2C2 A1+B1C1 A0+B0C0          + B0*C0 + B1*C1 + B2*C2 + B3*C3   (4 x 8-bit)
 16-bit:      lane1         lane0                 or  + B0*C0 + B1*C1               (2 x 16-bit)
            A1+B1*C1      A0+B0*C0              = ONE result, in A's format, rounded ONCE
 32/19-bit:        A + B*C
```

The supported mixed combinations (from the paper) are:
- a 16-bit addend (HP, DLFloat16, BFloat16) + 4 × 8-bit products (E4M3, E5M2): 6 combinations;
- a 32/19-bit addend (SP, TF32) + 4 × 8-bit products: 4 combinations;
- a 32/19-bit addend + 2 × 16-bit products: 6 combinations.

All **16 combinations** are tested.

---

## 5. The ports and how numbers are packed

| Port | Width | Meaning |
|---|---:|---|
| `clk_i`, `rst_n_i` | 1 | clock, active-low asynchronous reset |
| `a_i`, `b_i`, `c_i` | 64 | operands A, B, C (only the low 32 bits are used) |
| `mixmode_i` | 1 | 0 = multiple-precision, 1 = mixed-precision |
| `pra_i` / `prm_i` | 2 | format *class* of A / of B,C: `00`=8-bit, `01`=16-bit, `10`=SP, `11`=TF32 |
| `ewa_i` / `ewm_i` | 4 | exponent width of A / of B,C (4..8). With the class, this picks the exact format. |
| `dout_o` | 128 | result (low 32 bits used) |

The class and the exponent width together select the format: 8-bit/4 = E4M3, 8-bit/5 = E5M2, 16-bit/5 = HP, 16-bit/6 = DLFloat16, 16-bit/8 = BFloat16, SP/8 = SP, TF32/8 = TF32.

Lanes are packed into the low 32 bits: four bytes for 8-bit formats, two halfwords for 16-bit formats, the whole word for SP, or the low 19 bits for TF32. In mixed mode, A's lane 0 holds the single wide addend.

**Worked example** (E4M3, 4 independent lanes; this is a real test in `tb/unit/tb_fma_top_directed.v`):

```
             lane3   lane2   lane1   lane0
 a_i = 0x    00      38      00      38        A = 0,    1,    0,   1
 b_i = 0x    3c      b8      40      38        B = 1.5, -1,    2,   1
 c_i = 0x    40      38      40      38        C = 2,    1,    2,   1
 dout= 0x    44      00      48      40        =   3,    0,    4,   2      (A + B*C per lane)
```

---

## 6. Inside the pipeline

```
          STAGE 1                     STAGE 2                       STAGE 3                 STAGE 4
  unpack, multiply, find     align every term to the      add everything,          normalize, round,
  the biggest term           biggest one, fix signs       make it positive         pack the result
 +------------------+  R  +-----------------------+  R  +-------------------+  R  +---------------------+
 | Unified Extractor|  E  | Align Amount Finalizer|  E  | 3:2 CSA           |  E  | Normalization       |
 | Bias Generator   |  G  | Addend Alignment      |  G  | Sticky Logic      |  G  | Rounding            |--> dout_o
 | Unified LZC      |  1  | Product Align Ctrl    |  2  | CSLA (adder)      |  3  | Exponent Adjuster   |
 | Booth Multiplier |     | Multiplication Aligner|     | Complement        |     | Sign Detection      |
 | Exp&Align Ctrl   |     | Relative Normalizer   |     | LZAU              |     | Output Finalizing   |
 | Comparator       |     | Invert/Swap, CSA 4:2  |     | (Incrementor)     |     |                     |
 +------------------+     +-----------------------+     +-------------------+     +---------------------+
   rtl/fma_top.v           rtl/fma_lane_pipe.v (4 copies: one per lane in multiple mode, copy 0 in mixed)
```

The **3 pipeline registers** mean a result appears on `dout_o` 3 rising clock edges after its inputs, and a new operation can start every clock.

**Internal number form.** Every operand is converted to one common form: a sign, a signed exponent, and a 24-bit significand with the hidden bit at bit 23. The 8-, 16- and 32-bit formats then all share the same hardware. Products are kept **exact** (48 bits). All the terms are added in a **76-bit accumulator** laid out like this:

```
 bit 75 | 74 73 72 | 71 ............................ 24 | 23 ....... 1 | 0
  sign  |  headroom |  a 48-bit product (hidden bit=71)  |  guard bits  | sticky "jam"
        |(5 terms   |  a 24-bit addend occupies 71..48   |              | (lost bits, see Invert/Swap)
        | can't overflow)
```

What each block does, in one line:

| Stage | Block (spec §) | File | What it does |
|---|---|---|---|
| 1 | Unified Extractor (6.1) | `stage1_unified_extractor.v` | Splits each operand into sign/exponent/significand and flags zero/Inf/NaN. |
| 1 | Bias Generator (6.2) | `stage1_bias_generator.v` | Gives the bias of each format (7, 15, 31, 127). |
| 1 | Unified LZC (6.4) | `stage1_unified_lzc.v` | Counts leading zeros so subnormal inputs can be normalized. |
| 1 | Booth Multiplier (6.3) | `stage1_booth_multiplier.v` | Multiplies B×C (radix-4 Booth, 24×24) and outputs a carry-save pair. |
| 1 | Exp & Align Controller (6.5) | `stage1_exp_align_controller.v` | Product exponent = eB + eC (+1). Keeps the exact 48-bit product. |
| 2 | Comparator (6.6) | `stage1_comparator.v` | Finds the largest term, the **anchor**, which every other term is aligned to. |
| 2 | Align Amount Finalizer (7.1) | `stage2_align_amount_finalizer.v` | Addend shift = anchor exponent − addend exponent. |
| 2 | Addend Alignment (7.2) | `stage2_addend_alignment.v` → `align_shifter.v` | Shifts the addend right into the 76-bit frame. |
| 2 | Product Align Ctrl (7.5) | `stage2_product_align_ctrl.v` | Same shift calculation for each product. |
| 2 | Multiplication Aligner (7.6) | `stage2_mult_aligner.v` → `align_shifter.v` | Shifts each product right into the frame. |
| 2 | Relative Normalizer (7.4) | `stage2_relative_normalizer.v` | Pass-through here, because products are already normalized. |
| 2 | Invert/Swap (7.3) | `stage2_invert_swap.v` | Terms whose sign differs from the anchor's are bit-inverted, and the +1s are counted. |
| 2 | CSA 4:2 (7.7) | `stage2_csa4to2.v` | Squeezes 5 terms + the +1 count into a sum/carry pair without carrying. |
| 3 | 3:2 CSA (8.1) | `stage3_csa3to2.v` | One more carry-save step. |
| 3 | Sticky Logic (8.2) | `stage3_sticky_logic.v` | Records "some bits were lost during alignment". |
| 3 | CSLA (8.3) | `stage3_csla.v` | Carry-select adder: sum + carry becomes one number. |
| 3 | Complement (8.6) + Incrementor (8.5) | `stage3_complement.v`, `incrementer.v` | If the sum is negative, makes it positive (~x + 1). |
| 3 | LZAU (8.4) | `stage3_lzau.v` | Finds where the leading 1 is, i.e. how far to shift to normalize. |
| 4 | Normalization (9.1) | `stage4_normalization.v` | Shifts the leading 1 back to bit 71, stopping at the minimum exponent for subnormal results. |
| 4 | Rounding (9.2) | `stage4_rounding.v` | Round-to-nearest-even to the output format's mantissa width. |
| 4 | Exponent Adjuster (9.3) | `stage4_exp_adjuster.v` | Final exponent = anchor exponent + normalize shift + rounding carry. |
| 4 | Sign Detection (9.4) | `stage4_sign_detection.v` | Final sign, including the IEEE rules for NaN, ±Inf and ±0. |
| 4 | Output Finalizing (9.5) | `stage4_output_finalize.v` | Packs sign/exponent/mantissa into the output format; handles overflow to Inf. |

---

## 7. One operation traced through the pipeline (real simulation values)

**Mixed precision, HP addend + 4 × E4M3 products:**

```
A = 1.0 (HP 0x3C00)
B = [2.0, -1.0, 1.5, 0.25]   C = [3.0, 0.5, 1.0, 1.0]      (E4M3)
A + B0C0 + B1C1 + B2C2 + B3C3 = 1 + 6 - 0.5 + 1.5 + 0.25 = 8.25   -> HP 0x4820
```

Inputs: `mixmode_i=1, pra_i=01 (16-bit), ewa_i=5 (HP), prm_i=00 (8-bit), ewm_i=4 (E4M3), a_i=0x3C00, b_i=0x283CB840, c_i=0x38383044`.

### Stage 1: unpack and multiply

| Term | sign | exponent | significand | means |
|---|---|---:|---|---|
| A | + | 0 | `800000` (1.0) | 1.0 × 2⁰ = 1 |
| B0×C0 | + | 2 | `c00000000000` (1.5) | 1.5 × 2² = **6** ← largest |
| B1×C1 | − | −1 | `800000000000` (1.0) | −1.0 × 2⁻¹ = −0.5 |
| B2×C2 | + | 0 | `c00000000000` (1.5) | 1.5 × 2⁰ = 1.5 |
| B3×C3 | + | −2 | `800000000000` (1.0) | 1.0 × 2⁻² = 0.25 |

### Stage 2: align everything to the anchor and fix signs

- **Anchor.** The Comparator picks product lane 0 (label 0), with `ref_exp = 2` and positive sign.
- **Shifts.** Each term is shifted right by (2 − its exponent): the addend by 2, and the products by 0, 3, 2 and 4.
- **Frame layout.** In the 76-bit frame (19 hex digits), bit 71 is worth 2^ref_exp = 4.
- **Negation.** Lane 1 is negative while the anchor is positive, so it is **bit-inverted**, and `neg_count = 1` supplies its +1 later.

```
a_term  = 0200000000000000000     1.0   (bit 69)
p0_term = 0c00000000000000000     6.0   (bits 71,70)
p1_term = fefffffffffffffffff    -0.5   (~0100..., +1 comes from neg_count)
p2_term = 0300000000000000000     1.5
p3_term = 0080000000000000000     0.25
CSA 4:2 -> sum = ce7fffffffffffffffc, carry = 4200000000000000004   (not yet added up)
```

### Stage 3: add and make positive

```
sum + carry = 1080000000000000000  = bit 72 + bit 67 = 8 + 0.25 = 8.25     sign = + (no complement)
LZAU: leading 1 at bit 72 = one above bit 71 -> exp_adjust = +1
```

### Stage 4: normalize, round, pack

```
normalize: shift right 1 -> 0840000000000000000  (1.0000100000 binary, leading 1 at bit 71)
round to HP (10 mantissa bits): exact, nothing to round; rounded significand = 840000
exponent: 2 (anchor) + 1 (normalize) + 0 (no rounding carry) = 3
pack HP:  sign 0 | exponent 3+15 = 18 = 10010 | mantissa 0000100000  ->  0x4820 = 8.25
```

The same trace can be seen in the waveform (§9).

---

## 8. Decimal in, decimal out: the I/O shell

The FMA itself (U_FMA, `fma_top`) takes **binary-encoded** operands, as the spec requires (MPFMA-DS-001 §4.3: no format conversion inside the unit). So that a user never has to hand-encode hex, the design has an optional hardware **I/O shell** *around* it, `rtl/fma_fp64_top.v`. Operands go in and results come out as IEEE 754 **doubles** (64-bit), which is the binary form any typed decimal number takes.

```
 you type "0.1"
     |  (simulator / CPU / driver reads the text)      <- the only step that is not hardware
     v
 IEEE double 0x3FB999999999999A
     |  fp64_to_fmt  (RTL, x12)   round to nearest-even into the chosen format   -> register
     v
 HP 0x2E66 (= 0.0999755859375) on a_i/b_i/c_i
     |  fma_top      (RTL, U_FMA, unchanged)          4 stages, 3 registers
     v
 dout_o = HP 0x3C66
     |  fmt_to_fp64  (RTL, x4)    exact widening back to a double                -> register
     v
 double 0x3FF1980000000000  ->  printed as 1.099609375
```

- **One step is not hardware:** turning the typed characters into a double. Hardware never sees text: a processor, driver or (here) the simulator does that step, exactly as when any program reads "0.1". Everything after the double is RTL.
- **The input side rounds once, to nearest-even.** Overflow gives ±Inf, tiny values become subnormals or ±0, and NaN/Inf/−0 pass through. A number the format cannot hold, such as 0.1, is shown as "stored as 0.0999755859375 (rounded to fit the format)".
- **The output side is exact.** Every value of all 7 formats fits in a double.
- **Latency through the shell is 5 clock edges** (1 + 3 + 1). It still takes one operation per clock.
- **Double-rounding caveat.** A typed decimal is rounded twice: first to a double, then to the format. That can differ from a direct decimal→format rounding only if the typed number lies within about 2⁻⁵³ (relative) of a rounding midpoint of the format without being exactly on it. That does not happen for numbers people type in practice.

**Run it:**
```
tb/run_fma.sh SP 1.5 2 3                              # 1.5 + 2 x 3 = 7.5
tb/run_fma.sh HP 1 2 3   0.5 -4 0.25                  # two HP lanes: 7 and -0.5
tb/run_fma.sh HP+E4M3 1  2 3  -1 0.5  1.5 1  0.25 1   # mixed: 1 + 6 - 0.5 + 1.5 + 0.25 = 8.25
```
The printout shows:
- each number as typed, as a double, and as the format bits the RTL made (with its stored value);
- the operation moving through the pipeline clock edge by clock edge;
- the result in decimal, with its format bits and double.

**How the shell was verified:**
- **`tb/unit/tb_fp64_to_fmt.v`:** 24 hand-known conversions (0.1 → HP `2E66`, 65520 → HP +Inf, ties, NaN, −0, …) plus 7,000 random doubles, checked against an independent real-arithmetic model.
- **`tb/unit/tb_fmt_to_fp64.v`:** every encoding of E4M3, E5M2, HP, DLFloat16, BFloat16 and TF32 (721,408 values) plus 20,000 SP values, each checked for an exact double *and* a lossless round trip through both converters.
- **`tb/tb_fma_fp64_top.v`:** all 10,743 regression vectors pushed through the whole shell as doubles, 10,743 / 10,743 pass (Xcelium and xsim).


---

## 9. How to run it and read the output

```
tb/run_fma.sh SP 1.5 2 3         # YOUR numbers, typed in decimal, through the RTL (§8)
./run_all.sh                     # everything: unit tests + both system regressions + report (~3 min)
tb/run_sim.sh                    # just the system regression + report (~10 s)
tb/run_sim.sh --shell            # the same vectors through the decimal I/O shell
tb/run_sim.sh --demo --gui       # 40 hand-picked operations, then SimVision with decoded signals
tb/unit/run_unit.sh stage4_rounding   # one block's unit test; readable log in tb/unit/out/logs/
tb/run_stress.sh 1 2 3           # extra random seeds (beyond the committed regression)
```

- **Console / `docs/VERIFICATION_REPORT.md`.** Pass/fail tables by format, mode and test kind, and the spec's F01–F13 sign-off checklist. It also shows decoded worked examples, for example:
  ```
  [MIX_HP_E4M3] Mixed HP + 4 x E4M3
     -0.734375 + (28 x 0.4375) + (-1.875 x -1.75) + (-1.5 x 0.4375) + (-18 x 0.28125)
        exact = 9.078125  -> correctly rounded 0x488a = 9.078125  |  RTL: 0x488a = 9.078125  PASS
  ```
  That reads as "A + products = exact value → what a correct FMA must return → what our hardware returned".
- **Unit-test logs** (`tb/unit/out/logs/<block>.log`). Every block's log has a banner saying what the block should do, then a table of hand-picked cases (inputs | got | expected | PASS | what the case means), then a random-test count, then a `SUMMARY` line.
- **Waveforms.** The testbench adds "view" signals that show numbers as **decimals**, not hex:
  - `view_in_label`, `view_in_A0..3`, `view_in_B0..3`, `view_in_C0..3`: the operation being *applied* this clock;
  - `view_out_label`, `view_out_got0..3`, `view_out_exp0..3`: the result *coming out* this clock (3 edges later) next to the expected value;
  - `view_mismatch`: goes to 1 if they differ (it stays 0);
  - also `pass_count` / `fail_count`.

  Infinity shows as ±1e308. NaN shows as 0 with `view_out_nan = 1`.

---

## 10. How we know it works

Verification has three layers, all self-checking. Nobody has to eyeball waveforms to decide pass/fail.

1. **An independent golden model** (`tb/golden_model.py`). It decodes the operands into exact fractions (Python `Fraction`), computes `A + ΣBᵢCᵢ` with **no rounding at all**, then rounds once to the output format. It shares no code with the RTL. It also applies the IEEE rules for NaN, ±Inf and ±0.
2. **Unit tests** (`tb/unit/`, 30 testbenches, ~795,000 checks, most of them the exhaustive converter tests). Each RTL block is driven on its own and checked against a small reference model written inside its testbench. This localizes a problem to one block.
3. **The system regression** (`tb/tb_fma_top.v`, 10,743 vectors = 17,139 individual FMA results). Vectors are streamed **back-to-back, one per clock**, with the mode and format switching almost every cycle. `dout_o` is compared bit-for-bit with the golden answer. The vector categories are:

   | Category | What it tests |
   |---|---|
   | `MUL` / `MIX` | Random values; half of them set up so that A nearly cancels B×C |
   | `SPECIAL` | NaN, ±Inf, ±0, max and min operands |
   | `CANCEL` | A = −round(B×C), the defining FMA case |
   | `TIE` | Results exactly halfway, which tests round-to-even |
   | `OVF` / `UNF` | Top and bottom of the range |
   | `HEADROOM` | Five maximal terms of the same sign |
   | `ANCHOR` | Every lane as the largest term, and tied exponents |
   | `DIR_BUG*` | One vector per bug found |

**Cross-checks:**
- The regression gives the same 10,743/10,743 on **two different simulators**, Cadence Xcelium and Vivado xsim.
- `tb/run_stress.sh` ran 5 more random seeds (53,715 vectors). All but 3 matched. Those 3 are the documented mixed-precision limitation (`docs/DEVIATIONS.md` §4), which any fixed-width accumulator has.

---

## 11. Bugs found by this verification

Before this work, the regression passed 909/925 and every unit test passed, because each block worked *alone*. System-level testing found **8 bugs**, all now fixed, each with its own regression vector:

| # | What went wrong | Example |
|---|---|---|
| B1 | SP products were cut to 24 bits, so SP results came out 1 ULP low | `0 + 0x1139e399 × 0xaee23e77` |
| B2 | Subnormal results were truncated instead of rounded | E5M2 `−0 + (−0.875)(−2⁻¹⁶)` gave 0 instead of 2⁻¹⁶ |
| B3 | Sign of lost low bits was wrong for negative results (1 ULP high) | mixed BF16 + E5M2 |
| B4 | **Accumulator overflow** | `1.75 + 4 × 1.75` gave **−7.25** instead of 8.75 |
| B5 | Exact FMA cancellation broken | the §2 example gave 2⁻³⁶ instead of 2⁻⁴⁶ |
| B6 | −Inf became +Inf | `−Inf + 1×1` |
| B7 | Inf − Inf gave Inf instead of NaN | `+Inf + (−Inf)×1` |
| B8 | −0 + (−0) gave +0 | `−0 + (−0)×1` |

Root causes and fixes are in `docs/DEVIATIONS.md`.

---

## 12. Glossary

| Term | Meaning |
|---|---|
| **ULP** | Unit in the last place: the gap between two neighbouring representable numbers. "1 ULP off" means the last bit is wrong. |
| **Hidden bit** | The leading "1." of a normal number. It is not stored, and it is restored inside the unit. |
| **Subnormal** | A number smaller than the smallest normal one (exponent field 0, no hidden 1). |
| **Guard / round / sticky** | The bits just below the kept ones: the first one, the second one, and the OR of all the rest. Together they decide rounding. |
| **Round-to-nearest-even (RNE)** | Round to the closest representable number; on an exact tie, pick the one ending in 0. |
| **Anchor** | The largest term. Every other term is shifted right to line up with it. |
| **Binade** | A factor-of-2 range of values (e.g. [1, 2)). "70 binades smaller" means about 2⁷⁰ times smaller. |
| **CSA (carry-save adder)** | Adds 3 numbers into 2 without propagating carries, which makes it fast. The final carry-propagate add happens once, in the CSLA. |
| **CSLA** | Carry-select adder. It computes the upper half for both possible carry-ins and picks the right one. |
| **LZC / LZA** | Leading-zero count / anticipation: how far to shift to put the leading 1 back in place. |
| **Booth multiplier** | A multiplier that recodes one operand in radix-4 so that there are half as many partial products. |
