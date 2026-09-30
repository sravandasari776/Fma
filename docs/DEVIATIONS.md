# Design Notes: Bugs Fixed, Deviations and Known Limitations

This file records:
- how this RTL differs from the source paper (Niknia et al., IEEE TCASAI 2025) and the spec (MPFMA-DS-001);
- every design bug that verification found, and how each was fixed;
- the limitations that remain.

Each deviation is also commented where it appears in the RTL.

**Current status.** 30/30 unit testbenches pass. The full regression passes 10,743 / 10,743 vectors bit-exactly against the independent golden model, on both Cadence Xcelium and Vivado xsim, both directly into `fma_top` and through the decimal I/O shell (§5). Across 5 extra random seeds (53,715 more vectors), 3 vectors differ. All three fall under the known limitation in §4.

---

## 1. Design bugs found by verification, and how they were fixed

The original code passed 909/925 vectors. Its unit tests all passed, because every block was correct *on its own*. The problems were in how the blocks worked together.

The 16 failing vectors were first blamed on a single cause (the "~1-ULP gap"). Decoding them showed **three separate bugs** (B1–B3). Targeted directed tests then found **five more (B4–B8)** that random vectors had never hit.

| # | Symptom | Root cause | Fix | Regression vector |
|---|---|---|---|---|
| B1 | 8 SP results 1 ULP too small | The exact 48-bit product was cut to 24 bits plus a sticky flag. That throws away the guard bit, which is needed to round an SP result correctly. | The full 48-bit product is carried into a 76-bit accumulator (see §2). | `DIR_BUG1_SP_product_guard` |
| B2 | 6 subnormal results 1 ULP too small (E4M3, E5M2, TF32, SP) | The result was rounded at *normal* precision, and Output Finalizing then shifted it into the subnormal range by **truncating**. That is double rounding. | Normalization stops the left shift at the format's minimum exponent (spec §9.1: "use the exponent instead of the LZA"). The value is then rounded **once**, at subnormal precision. Output Finalizing only packs it. | `DIR_BUG2_E5M2_subnormal_round` |
| B3 | 2 mixed-mode results 1 ULP too large (the result was negative) | Invert/Swap skipped the "+1" of the two's-complement negation for terms that had lost bits, so the sum became a *lower* bound. That is only correct when the final result is positive. For negative results, a "sticky" meaning "a bit more" actually means "a bit less". | **Sticky jamming**: the lost bits are ORed into frame bit 0, so a truncated term is carried as "truncated + ½". Every inverted term now gets its +1, and the sign of the lost part survives negation. | `DIR_BUG3_sticky_sign` |
| B4 | `1.75 + 4×(1.75×1.0)` in mixed HP/E4M3 gave **−7.25** instead of 8.75 | The 40-bit accumulator had only 2 headroom bits above the hidden bit. Adding 5 terms of up to ~2.0 each needs 3 bits (spec F09 says "3-bit overflow"). The sum overflowed into the sign bit. | The accumulator was widened to 76 bits (spec §7.2: `aligned[75:0]`). It now has 3 headroom bits and a separate sign bit. | `DIR_BUG4_headroom_pos/neg` |
| B5 | SP `−(1+2⁻²²) + (1+2⁻²³)²` gave 2⁻³⁶ instead of the exact 2⁻⁴⁶ | Same root cause as B1. With a truncated product, `A = −round(B·C)` cannot recover the product's rounding error, and returning that error exactly is the defining property of a *fused* multiply-add. | Same as B1: the product is kept exactly. | `DIR_BUG5_SP_exact_cancel` |
| B6 | A −Inf addend gave +Inf | For Inf results, the sign was taken from the (meaningless) datapath sum. | Sign Detection now takes an infinity's sign from the infinite operand. | `DIR_BUG6_neg_inf` |
| B7 | +Inf + (−Inf) gave Inf | There was no invalid-operation check. The golden model had the same bug, so the two agreed on a wrong answer. | RTL and golden model now both return NaN (IEEE 754). | `DIR_BUG7_inf_minus_inf` |
| B8 | −0 + (−0)·1 gave +0 | Zero results were always +0 (in the golden model too). | IEEE rule: the result is −0 only if every term is −0; a sum that cancels to zero is +0. | `DIR_BUG8_neg_zero` |

Three bugs had already been found and fixed before this pass:
- **Comparator.** A zero term (placeholder exponent 0) could out-rank a small nonzero term. Zero terms are now excluded from the comparison.
- **Final sign.** The anchor's own sign was missing from the final sign. It is now threaded as `ref_sign` from Invert/Swap to Sign Detection.
- **Output packing.** Output Finalizing had its mantissa bit mapping reversed.

All 8 new bugs have a directed vector in `tb/vectors.txt` (label `DIR_BUG*`) and a hand-checkable case in `tb/unit/tb_fma_top_directed.v`. That way they cannot come back unnoticed.

### Why the random regression missed B4–B8

The original generator never produced NaN or Inf operands (B6, B7), never produced several large terms of the same sign (B4), and never produced `A ≈ −B·C` (B5). Also, the golden model itself was wrong for B7 and B8. The new generator (`tb/gen_vectors.py`) adds a category for each of these:

| Category | What it generates | Bugs it covers |
|---|---|---|
| `SPECIAL` | NaN/Inf/zero operands | B6–B8 |
| `HEADROOM` | Several large same-sign terms | B4 |
| `CANCEL` | `A = −round(B·C)` | B5 |
| `TIE` | Results exactly halfway between two neighbours | Round-to-nearest-even ties |
| `UNF` / `OVF` | Results at the bottom / top of the range | Subnormals and overflow |
| `ANCHOR` | Comparator permutations | Anchor selection |

---

## 2. Architectural deviations from the source paper

This implementation puts functional correctness and verifiability first. It is not a bit-for-bit replica of the paper's area-optimized micro-architecture.

- **Unified padded significand.** Every operand is unpacked into a common 24-bit significand with the hidden bit at bit 23, whatever its format. Narrower formats are zero-padded. One 24×24 Booth multiplier then serves every precision, without the paper's per-precision PPG segmentation (Fig. 6). This is exact, because zero-padding never changes a value, but it is not area-minimal.

- **76-bit accumulation frame with the exact product.** The accumulation frame is laid out as follows:

  | Bits | Contents |
  |---|---|
  | 75 | Sign |
  | 74–72 | Headroom for adding 5 terms |
  | 71..24 | Full 48-bit product (hidden bit at bit 71) |
  | 23..1 | Guard bits |
  | 0 | Sticky "jam" bit |

  The width matches the spec's `aligned[75:0]` (§7.2). Carrying the whole product is what makes single-precision FMA exact (fixes B1 and B5).

- **Sticky jamming instead of a separate sticky path.** Bits shifted out during alignment are ORed into frame bit 0 (`align_shifter.v`), so the *sign* of a lost remainder is carried through the signed addition (fixes B3). The paper's separate Sticky Logic block (§8.2) is kept. It still ORs the per-term "lost bits" flags into rounding. Whenever only one term lost bits, that flag is redundant with the jam bit.

- **Subnormal results via exponent-limited normalization** (§9.1's "Flag → use Exp_ABC" path). If the true exponent would fall below the format's minimum, the normalization shift is limited, and the value is then rounded once at subnormal precision (fixes B2).

- **Addend Alignment / Multiplication Aligner** (`align_shifter.v`, §7.2/§7.6). One generic barrel shifter replaces the paper's 7-level cascaded 31-bit aligner network (Fig. 7) and the separate product aligner. It performs the same function in a simpler structure that uses more area.

- **Unified Relative Normalizer** (`stage2_relative_normalizer.v`, §7.4) is a structural pass-through. The extractor already normalizes every operand fully, so this block has nothing left to do. It is kept so the hierarchy matches Fig. 3.

- **LZAU** (`stage3_lzau.v`, §8.4) counts leading zeros on the magnitude after Complement. The paper instead *anticipates* the count in parallel with the CSLA add (Schmookler & Nowka). The result is the same; the paper's version is only a critical-path timing optimization.

- **Comparator includes the addend** (`stage1_comparator.v`, §6.6). The paper ranks only the dot products and assumes the addend is smaller. This implementation also compares the addend, so results stay correct when the addend dominates.

- **Product Alignment Ctrl is active in both modes** (§7.5). The paper bypasses it in multiple-precision mode, but here it is needed when a lane's own addend is larger than its own product.

- **The +1 of each two's-complement negation is shared.** It is injected once, as a small count `neg_count` in the CSA tree (`stage2_csa4to2.v`), rather than added per term. This follows the spirit of the paper's shared Incrementor (§8.5).

---

## 3. Special values and number conventions

- **IEEE 754 special-value rules** are followed by both the RTL and the golden model:
  - **NaN.** The result is NaN when any operand is NaN, a product is Inf×0, or +Inf meets −Inf. The output is a canonical positive NaN: exponent all ones, mantissa `…001`.
  - **Infinity.** The result carries the sign of the infinite term.
  - **Zero.** The result is −0 only if every term is −0. A nonzero result that rounds down to zero keeps its sign.
- **FP8 encodings are IEEE-style.** In E4M3 and E5M2, an all-ones exponent means Inf/NaN, as in the paper's Table I (e.g. E4M3 max = 240). This is *not* the OCP FP8 convention, where E4M3 has no infinities and a maximum of 448.
- **Rounding** is round-to-nearest-even only. There are no other rounding modes and no exception flags (inexact, overflow, …) on the ports.
- **Exponent width 7** is accepted by the hardware (`ewa_i`/`ewm_i` = 4..8), but no supported format uses it, so it is not tested.

---

## 4. Known limitation: fixed-width accumulator in mixed-precision mode

In mixed-precision mode, the unit adds an addend and up to 4 products **in one fixed 76-bit frame**, aligned to the largest term. A term more than about 70 binary orders of magnitude smaller than the largest one falls entirely below the frame. Only its jam bit (the fact that it is nonzero, and its sign) survives.

This matters only when that tiny term decides the answer:

- **Tie + two tiny terms of opposite sign.** The in-frame terms land *exactly* on a rounding tie, and two or more tiny terms of opposite signs fall below the frame. Their jam bits cancel, so the tie is resolved to even. Depending on which tiny term is bigger, that can be 1 ULP off.
- **Exact cancellation exposes a tiny term.** The in-frame terms cancel *exactly* (for example `+x·y` and `−x·y`), and the only thing left is a tiny term below the frame. The true answer is that tiny term, but the RTL only has its jam bit, so the result is wrong.

The stress test (`tb/run_stress.sh`, 5 extra seeds, 53,715 vectors) found 3 such cases. All are in mixed mode, which needs a 16-bit class product format with an 8-bit exponent (BFloat16), or an addend far below the products. Decoded:

```
[MIX_TF32_BFloat16] TF32 + 2 x BFloat16
   -1.587619e-13 + (-2.989043e-31 x -7.986852e+15) + (-7.046431e+08 x -2.968773e+19)
      exact = 2.091925e+28  -> correctly rounded 0x37439 = 2.090958e+28  |  RTL: 0x3743a  (1 ULP, tie case)
[MIX_TF32_BFloat16] TF32 + 2 x BFloat16
   -2.3936e-36 + (8.081524e-39 x 0.03417969) + (9.458745e-11 x 8.368475e+29)
      exact = 7.915527e+19  -> correctly rounded 0x3044a  |  RTL: 0x3044b  (1 ULP, tie case)
[SPECIALMIX_BFloat16_E5M2] BFloat16 + 4 x E5M2
   -9.18355e-41 + (-57344 x 3.05e-05) + (0.0078125 x -0) + (-57344 x -0) + (57344 x 3.05e-05)
      exact = -9.18355e-41 (the addend: the products cancel exactly)  |  RTL: -4.24e-22  (cancellation case)
```

**Why this is inherent.** An exact answer for every input would need an accumulator as wide as the whole exponent range of the formats: over 500 bits for BFloat16 products. The paper's design has the same fixed-width (76-bit) accumulator, so it has the same property. This is the usual trade-off in dot-product hardware.

**Multiple-precision mode is not affected.** A plain `A + B×C` never has two terms below the frame. The classic FMA analysis shows that a single jammed term always rounds correctly, and the 53,715-vector stress test found no mismatches in multiple-precision mode.

**Possible fixes (not done):**
- A wider accumulator, which lowers the probability but does not remove it.
- A small second accumulator for the below-frame terms, which removes the tie case.
- A bypass that returns the addend when the products cancel exactly and only the addend fell below the frame.

---

## 5. Timing and interface notes

- **4 stages, 3 pipeline registers.** Stage 1 → register (`fma_top`) → Stage 2 → register → Stage 3 → register (both inside `fma_lane_pipe`) → Stage 4, which drives `dout_o` combinationally. A result appears on `dout_o` 3 rising clock edges after its inputs are applied, i.e. during the 4th clock cycle. The unit accepts one new operation every clock.
- **No handshake.** There is no valid/ready (none is drawn in the paper's Fig. 3). The mode, format and exponent width are sampled every cycle with the data, so consecutive operations may use different modes and formats (spec F13). The regression switches mode or format between almost every pair of consecutive vectors.
- **`dout_o` width.** `dout_o` is 128 bits wide, but only `[31:0]` is used: 4×8, 2×16, 1×32 or 1×19 result bits.
- **Decimal I/O shell (an addition, not in the paper).** `rtl/fma_fp64_top.v` wraps the unchanged `fma_top` with two converters:
  - `fp64_to_fmt`: IEEE double → format, round-to-nearest-even;
  - `fmt_to_fp64`: format → double, exact.

  Users can then give and read ordinary decimal numbers (`tb/run_fma.sh`).
  - It sits **outside** U_FMA, so U_FMA still takes binary-encoded operands as spec §4.3 requires.
  - Its latency is 5 clock edges (input register + 3 + output register).
  - The text → double step is done by the simulator (or a CPU/driver in a real system), not by hardware.
  - Typed decimals are rounded twice (text → double → format). This can differ from a direct text → format rounding only for a decimal within ~2⁻⁵³ (relative) of one of the format's rounding midpoints.
  - See `docs/DESIGN_EXPLAINED.md` §8.

---

## 6. Simulator-driven RTL style choices (Icarus Verilog 12.0)

These choices do not affect the design's function. They show up throughout the RTL style, and are recorded so that a future edit does not reintroduce a hang or silent X-propagation:

- **No unpacked-array module ports.** In this Icarus build, `output reg [W-1:0] foo [N]` ports silently read back as X on the receiving side, with no compile error. Every inter-module array (per-lane fields) is instead a packed vector (`wire/reg [N*W-1:0]`, lane `i` at `[W*i +: W]`).
- **No `task` called from `always @*`** inside a module that is instantiated several times in a `generate` loop with per-instance part-select port connections. This combination hangs the simulator. `shift_right_sticky` and `round_nearest_even` (`fma_funcs.v`) are therefore `function`s that return a packed `{flag, value}`.
- **No variable-width part-selects or variable-count replication.** These are not legal Verilog. The code uses variable-*base*, constant-*width* selects (`sig[base +: WIDTH]`) or explicit bit-by-bit `for` loops instead.

## 7. Plain Verilog (IEEE 1364-2005): no SystemVerilog

Every `.v` file compiles as plain Verilog-2005. This has been checked with Cadence Xcelium and Vivado `xvlog`/`xelab` (no errors, no warnings). The consequences for the RTL style:

- **No `package`/`import`.** Shared constants (`SIGW`, `PSIGW`, `WW`, `MSBPOS`, `SHW`, `EXPW`, `NLANE`, the `CLS_*` class codes) are `` `define`` macros in `rtl/fma_defs.vh`, which has an include guard.
- **No compilation-unit functions.** A Verilog `function` is visible only inside its own module. So `rtl/fma_funcs.v` deliberately has *no* include guard: it is `` `include``-d once *inside the body* of every module that needs a helper.
- **No `logic`, `typedef`, `struct`, `always_comb`/`always_ff`, `'0`/`'1`, `signed'()` casts, or `int`/`string`.** The replacements are:
  - explicit `wire`/`reg`;
  - 2-bit class codes;
  - `always @*` / `always @(posedge clk_i or negedge rst_n_i)`;
  - explicit widths;
  - `$signed()`;
  - `integer` / byte-vector labels.
- **Shift results are self-determined width.** Booth partial products are sign-extended to the full working width *before* shifting (`stage1_booth_multiplier.v`).
