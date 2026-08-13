# U_FMA — Configurable Mixed/Multiple-Precision Floating-Point FMA

RTL implementation of the configurable, fully-pipelined FMA unit described in:

- Niknia et al., *"A Configurable Floating-Point Fused Multiply-Add Design
  With Mixed Precision for AI Accelerators,"* IEEE Trans. Circuits Syst.
  Artif. Intell., vol. 2, no. 3, pp. 248–261, Sep. 2025.
- `docs/FMA_Design_Document.docx` (MPFMA-DS-001) — the reverse-specified
  block-level design spec derived from that paper's Fig. 3, used as the
  RTL contract for this implementation.

Both source documents are in `docs/`.

This is an independent project (no relation to any other design in this
repository).

## What's implemented

A 4-stage pipeline (3 pipeline registers) computing `A + B*C` for a
configurable set of 8 floating-point formats — E4M3, E5M2, HP (binary16),
DLFloat16, BFloat16, TF32, SP (binary32) — supporting:

- **Multiple-precision mode**: 4 independent 8-bit FMAs, 2 independent
  16-bit FMAs, or 1 32/19-bit FMA per cycle, fully pipelined.
- **Mixed-precision mode**: 1×(16-bit)+4×(8-bit), 1×(32-bit)+4×(8-bit), or
  1×(32-bit)+2×(16-bit) — a single higher-precision addend accumulating
  several lower-precision dot products in one rounding step.

Every named block from MPFMA-DS-001 §6–9 (Fig. 3) is implemented as its
own RTL module in `rtl/`, one file per block, with a header comment citing
the section it implements. `rtl/fma_top.v` and `rtl/fma_lane_pipe.v`
wire them into the full pipeline.

All RTL is plain Verilog (IEEE 1364-2001/2005) — no SystemVerilog. There
is no `package`/`import` mechanism in Verilog, so shared constants live in
`rtl/fma_defs.vh` (`` `define`` macros, `` `include``-d at the top of every
file) and shared combinational helpers live in `rtl/fma_funcs.v`. Verilog
functions are scoped to the module that declares them (unlike
SystemVerilog's compilation-unit functions), so `fma_funcs.v` is
`` `include``-d once *inside* the body of every module that calls one of
its helpers, giving that module its own local copy — see the comment at
the top of `fma_funcs.v`.

## Directory layout

```
rtl/            All RTL modules (plain Verilog, one block per file)
tb/             Self-checking testbench, Python golden model, vector generator
docs/           Source paper + design spec (reference material)
```

## Running the verification suite

```
cd tb
python3 gen_vectors.py     # regenerate vectors.txt from golden_model.py (deterministic seed)
./run_sim.sh               # compile + simulate with Icarus Verilog, report PASS/FAIL
```

`golden_model.py` is an independent reference (exact rational arithmetic
via Python `Fraction`, round-to-nearest-even at the target format's
precision) — it does not share any code path with the RTL. `vectors.txt`
holds 925 test cases: ~40 random vectors per format in multiple-precision
mode, ~40 random vectors per mixed-precision combination (all 16 combos),
plus directed edge cases (all-zero, subnormal operands, addend-dominates,
sign-cancellation).

**Current result: 909/925 (98.3%) pass exactly.** The remaining 16 differ
from the golden model by exactly 1 ULP in the last mantissa bit (never in
sign, exponent, or by more than 1 ULP) — see `docs/DEVIATIONS.md` for the
precision-limit that causes this.

## Generating Synopsys (VCS) waveforms

For waveform review the testbench can dump a VCD scoped to **just the
system's inputs and outputs** — the top-level ports of `fma_top`
(`clk_i`, `rst_n_i`, `a_i`/`b_i`/`c_i`, `mixmode_i`, `pra_i`/`prm_i`,
`ewa_i`/`ewm_i`, and `dout_o`) — with none of the internal pipeline
nets. The dump is gated by the `DUMP_WAVES` compile-time define, so the
normal Icarus self-check run above is unaffected.

On a machine with **Synopsys VCS** (and `dve` or `verdi` to view):

```
cd tb
./run_vcs.sh            # compile + simulate + dump fma_io.vcd
# ./run_vcs.sh --regen  # regenerate vectors.txt first (optional)
```

This runs the same self-checking testbench (you'll still see the
`PASS/FAIL` summary) and writes `tb/fma_io.vcd`. Open it with either
Synopsys viewer:

```
dve -vpd fma_io.vcd          # DVE
verdi -vcd fma_io.vcd &      # Verdi
```

Requirements on the VCS machine: `vcs` on `PATH` and a valid Synopsys
licence (`SNPSLMD_LICENSE_FILE` / `LM_LICENSE_FILE`). `run_vcs.sh`
compiles the same source list as `run_sim.sh` and passes
`-timescale=1ns/1ps` (the sources carry no `` `timescale`` directive of
their own).

> To capture the whole hierarchy instead of only the I/O boundary,
> change the `$dumpvars` call in `tb/tb_fma_top.v` (inside the
> `` `ifdef DUMP_WAVES`` block) to `$dumpvars(0, tb_fma_top);`.

## Packing convention

Since MPFMA-DS-001 explicitly delegates the `pra_i`/`prm_i` encoding and
input/output bit-packing to the RTL owner, this implementation defines:

- `pra_i`/`prm_i` (2 bits) select a **format class**: `00`=8-bit,
  `01`=16-bit, `10`=32-bit (SP), `11`=19-bit (TF32).
- `ewa_i`/`ewm_i` (4 bits) select the **exponent width** (4–8), which
  combined with the class picks the exact format (bias is always
  `2^(ew-1)-1`, which holds for all 8 supported formats):

  | class | ew | format     | class | ew | format    |
  |-------|----|------------|-------|----|-----------|
  | 8-bit | 4  | E4M3       | 16-bit| 8  | BFloat16  |
  | 8-bit | 5  | E5M2       | 32-bit| 8  | SP        |
  | 16-bit| 5  | HP         | 19-bit| 8  | TF32      |
  | 16-bit| 6  | DLFloat16  |       |    |           |

- `a_i`/`b_i`/`c_i` (64 bits each) pack up to 4 lane values into the low
  32 bits: byte lanes for the 8-bit class, halfword lanes for 16-bit, all
  32 bits for SP, low 19 bits for TF32.
- In mixed-precision mode, `a_i`'s lane 0 carries the single addend;
  `b_i`/`c_i` carry the lower-precision dot-product operands.
- `dout_o`'s low 32 bits carry the packed result, same convention.

See the header comment of `rtl/fma_top.v` for the authoritative version
of this convention.

## Known deviations from the source paper

This implementation is correctness-first, not area-optimal: several of
the paper's hardware-sharing micro-optimizations (segmented Booth PPG
allocation, the 7-level addend-aligner cascade, LZA running concurrently
with the CSLA) are replaced by functionally-equivalent generic structures
that are simpler to implement and verify but not synthesis-area-minimal.
Every such deviation is documented at its point of use and summarized in
`docs/DEVIATIONS.md`, along with the remaining ~1-ULP rounding precision
limit.
