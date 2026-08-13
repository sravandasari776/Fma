# Known Deviations and Limitations

This implementation targets functional correctness and verifiability over
bit-exact replication of the source paper's area-optimized micro-
architecture. Every deviation below is also noted as a comment at its
point of use in the RTL.

## Architectural deviations from the source paper

- **Unified padded significand.** Every operand is unpacked into a
  common 24-bit left-justified significand (hidden bit at bit 23),
  regardless of source format; narrower formats are simply zero-padded.
  This lets one 24-bit datapath (multiplier, adders, shifters) serve every
  precision without the paper's explicit per-precision segmentation
  (Fig. 6's PPG allocation, the 4/2/1-lane multiplexed exponent
  processors). It is mathematically exact — zero-padding a significand
  never changes its value — but is an area/power-vs-verification-effort
  trade-off, not a synthesis-minimal realization.

- **Addend Alignment / Multiplication Aligner** (`align_shifter.v`,
  §7.2/§7.6) use one generic barrel shifter instead of the paper's
  7-level cascaded 31-bit aligner network (Fig. 7) or a dedicated product
  aligner. Same function, different (simpler, less area-efficient)
  implementation.

- **Unified Relative Normalizer** (`stage2_relative_normalizer.v`, §7.4)
  is a structural pass-through in this design: because the extractor
  already fully, independently normalizes every operand (rather than
  deferring product normalization to a shared relative pass keyed off the
  anchor's LZC), there is nothing left for this block to do. Retained in
  the module hierarchy for structural fidelity to Fig. 3.

- **LZAU** (`stage3_lzau.v`, §8.4) computes leading-zero count directly
  on the post-Complement magnitude rather than anticipating it
  concurrently with the CSLA add (the paper's critical-path optimization
  per Schmookler & Nowka). Same result, computed one step later in the
  data-flow graph — immaterial for functional verification, relevant only
  to critical-path timing closure.

- **Comparator extended to include the addend** (`stage1_comparator.v`,
  §6.6): the paper's Comparator ranks only the (up to) 4 dot products,
  assuming the addend is always smaller. This implementation compares the
  addend too, so the design is correct even when the addend's magnitude
  dominates the accumulation (a case the paper's assumption would get
  wrong). It also excludes any exactly-zero term from the comparison
  (zero terms carry a placeholder exponent of 0 that must not out-rank a
  genuinely small nonzero term or a nonzero addend).

## A real functional bug found and fixed during verification

The Comparator originally picked the "anchor" term by exponent value
alone. Because the extractor gives an exactly-zero operand a placeholder
exponent of 0, a *zero* dot product could out-rank a nonzero addend or
product whose true exponent was very negative (e.g. a small subnormal
value), corrupting the entire alignment reference for that operation.
Fixed by excluding zero-valued terms from the comparison entirely (see
`stage1_comparator.v`).

Two more were found and fixed the same way: the final result sign was
missing the accumulation anchor's own sign (only the *relative*
overflow sign from Complement was used — fixed by threading `ref_sign`
from Invert/Swap through to Sign Detection); and the mantissa-to-output
bit mapping in Output Finalizing was reversed (and separately double-
counted the subnormal alignment shift) — both fixed in
`stage4_output_finalize.v`.

## Remaining known limitation: ~1-in-925 ULP-level rounding gap

909/925 (98.3%) of the verification suite passes bit-exactly against the
independent golden model (`tb/golden_model.py`). The remaining 16 vectors
differ from the correctly-rounded result by exactly 1 ULP in the last
mantissa bit — never in sign, exponent, or by more than 1 ULP.

Root cause: the unified internal significand is exactly SIGW=24 bits
(hidden + 23 mantissa) with no spare guard bits reserved beyond that.
This is sufficient headroom for every format's own mantissa width *except*
the full-width case (m = SIGW-1 = 23, i.e. SP as the mixed-precision
addend format) combined with a value that originated from the Booth
multiplier's true 48-bit product: rounding that product down to the
carried 24 bits leaves no internal guard bit to correctly round the last
kept bit — only a sticky (inexact) flag survives (`prod_sticky_o` in
`stage1_exp_align_controller.v`), which is enough to know the value is
inexact but not which way to round on a near-tie.

A fully correct fix requires carrying extra guard-bit headroom through the
product-specific alignment path (i.e. widening the per-lane significand
carried from the multiplier through alignment from 24 to ~26 bits, distinct
from the addend path, which does not need it). This is a scoped, mechanical
follow-up (touching `stage1_exp_align_controller.v`'s product-sig width,
`stage2_relative_normalizer.v`, and `stage2_mult_aligner.v`'s per-lane
instances) rather than a fundamental architecture change, but was not
completed in this pass.

## Simulator-driven RTL style choices (Icarus Verilog 12.0)

Unrelated to the design's function, but visible throughout the RTL style,
and worth recording so a future edit doesn't reintroduce a hang or silent
X-propagation:

- **No unpacked-array module ports.** `output reg [W-1:0] foo [N]`
  ports silently read back as X on the receiving side in this Icarus
  build, with no compile error. Every inter-module array (per-lane
  fields) is instead a packed vector (`wire/reg [N*W-1:0]`, lane `i` at
  `[W*i +: W]`). Confirmed via isolated minimal repros; internal
  (non-port) unpacked arrays, and unpacked arrays indexed down to a
  scalar before being passed to a scalar port, are both fine.
- **No `task` called from `always @*` inside a module that is
  instantiated multiple times in a `generate` loop with per-instance
  part-select port actuals** — this combination hangs the simulator
  (infinite loop, confirmed via isolated repro). `shift_right_sticky` and
  `round_nearest_even` (`fma_funcs.v`) are `function`s returning a packed
  `{flag, value}` concatenation instead of `task`s with `output` ports,
  specifically to avoid this.
- Variable-*width* part-selects (`sig[msb:lsb]` with a non-constant width)
  and variable-count replication (`{count{bit}}` with non-constant count)
  are not legal Verilog and are avoided throughout in favor of
  variable-*base*, constant-*width* selects (`sig[base +: WIDTH]`) or
  explicit bit-by-bit `for` loops.

## Plain Verilog (IEEE 1364-2001/2005): no SystemVerilog

This design is written in plain Verilog, not SystemVerilog — every `.v`
file compiles under `iverilog -g2005`. The main consequences for the RTL
style, since this codebase started life as an SV description of the same
architecture and was mechanically translated block-by-block:

- **No `package`/`import`.** Verilog has no package mechanism at all.
  Shared constants (`SIGW`, `EXPW`, `NLANE`, the `CLS_*` format-class
  codes, etc. — previously `fma_pkg.sv`) are `` `define`` macros in
  `rtl/fma_defs.vh`, `` `include``-d at the top of every file that needs
  them; its own `` `ifndef``/`` `define``/`` `endif`` guard makes repeated
  inclusion across many files in one compilation safe.
- **No compilation-unit-scope functions.** In SystemVerilog, a `function`
  declared outside any module (global/compilation-unit scope) is callable
  from *every* module with no import — that is how the original SV
  version's `fma_funcs.sv` worked. Plain Verilog has no such scope: a
  `function` is visible only inside the module that contains it. So
  `rtl/fma_funcs.v` is deliberately *not* guarded against multiple
  inclusion — it is `` `include``-d once *inside the body* of every module
  that calls one of its helpers (right after that module's port list),
  giving that module its own private local copy of the full helper set.
  Re-including the same function text into several different modules
  within one compilation is the intended use.
- **No `logic`.** Every signal is explicitly `wire` (continuously/
  instance-output driven) or `reg` (driven from an `always` block),
  chosen per the signal's actual driver — `logic`'s automatic net/variable
  inference does not exist in Verilog.
- **No `typedef enum`/`struct`.** `fmt_class_e` becomes a plain 2-bit
  code (`` `CLS_8``/`` `CLS_16``/`` `CLS_32``/`` `CLS_19``, defined in
  `fma_defs.vh`); the packed `fp_num_t` record type was never
  instantiated as a signal in this design (only its constituent
  sign/exp/sig/flags fields are), so it has no plain-Verilog equivalent
  to carry over.
- **No `always_comb`/`always_ff`.** These become `always @*` and
  `always @(posedge clk_i or negedge rst_n_i)` respectively — functionally
  equivalent for this design's fully combinational-sensitivity-list and
  single-clock-domain style.
- **No unsized fill patterns (`'0`/`'1`).** Replaced with an explicit `0`
  (Verilog zero-extends a bare `0` literal to the assignment's target
  width) or `{WIDTH{1'b1}}` for all-ones.
- **No `signed'(...)` size-casts.** Replaced with `$signed(...)` where a
  genuine reinterpretation/extension was needed, or dropped entirely
  where the surrounding code only relied on two's-complement bit-pattern
  equivalence (e.g. negating an unsigned literal into a `reg signed`).
- **No inline `for (int k = ...)` loop-variable declarations.** Verilog
  requires `integer k;` (or `genvar k;` inside a `generate`) declared
  separately in the enclosing scope, then used as an ordinary `for (k = 0;
  ...; k = k + 1)`.
- **Shift-operator width semantics differ from SystemVerilog's implicit
  size-casts.** A Verilog `<<`/`<<<` result is *self-determined width*
  (the width of the left operand only) — it is **not** automatically
  widened to match the assignment target the way a SystemVerilog
  `WIDTH'($signed(x)) <<< n` expression is. `stage1_booth_multiplier.v`'s
  Booth partial products must therefore be manually sign-extended to the
  full working width *before* shifting (see that file's `pp_ext`/
  `pp_wide` comment) — omitting this would silently misalign/truncate the
  partial-product tree rather than produce a compile error.
- **`string`/`int` have no equivalent.** The testbench's vector-label
  scratch field (`tb_fma_top.v`, only ever passed to `$fscanf`'s `%s` and
  never otherwise used) is a plain byte-vector `reg [8*32-1:0]`, the
  classic pre-SV-string Verilog idiom. `int` becomes `integer` throughout
  (a 32-bit signed variable type, close enough for every use in this
  design — none needs `int`'s guaranteed exactly-32-bit wraparound
  behavior).

This conversion is syntax-only: no functional/algorithmic logic changed
relative to the prior SystemVerilog version, and the verification suite
confirms it — the plain-Verilog build passes the identical 909/925
(98.3%) vectors, with the same 16 residual ~1-ULP mismatches described
above.
