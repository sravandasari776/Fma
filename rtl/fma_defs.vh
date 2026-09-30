// fma_defs.vh
// Shared constants for the U_FMA design, plain-Verilog (IEEE 1364-2001)
// version. SystemVerilog packages/typedefs don't exist in Verilog, so
// these are `define macros, textually included (via `include, backtick-
// referenced as e.g. `SIGW) at the top of every module file, before the
// `module` keyword -- the standard portable way to share constants
// (including ones used inside port-width expressions) across Verilog
// files with no package/import mechanism available.
//
// fmt_class_e (SystemVerilog enum) becomes a plain 2-bit code:
//   `CLS_8  = 8-bit class  (E4M3, E5M2)                    -- 4 lanes
//   `CLS_16 = 16-bit class (HP, DLFloat16, BFloat16)        -- 2 lanes
//   `CLS_32 = 32-bit class (SP)                             -- 1 lane
//   `CLS_19 = 19-bit class (TF32, packed in low 19 bits)    -- 1 lane
`ifndef FMA_DEFS_VH
`define FMA_DEFS_VH

`define SIGW   24  // unified significand width (hidden bit + 23)
`define EXPW   12  // signed internal exponent width
`define NLANE  4   // max parallel lanes (8-bit class)

`define PSIGW  48  // full product significand width (SIGW*2, exact product)

// Stage 2/3 accumulation frame (MPFMA-DS-001 7.2: "aligned[75:0]"):
//   bit  75      : two's-complement sign
//   bits 74..72  : 3 overflow headroom bits (5 terms: addend + 4 products,
//                  each < 2^(MSBPOS+1), sum < 2^(MSBPOS+4)) -- spec F09
//   bits 71..24  : an unshifted 48-bit product (hidden bit at MSBPOS)
//   bits 71..48  : an unshifted 24-bit addend  (hidden bit at MSBPOS)
//   bits 23..1   : guard bits below the product's LSB
//   bit  0       : sticky "jam" bit -- set when a right-shifted term lost
//                  nonzero bits off the bottom (see align_shifter.v)
`define WW     76  // Stage 2/3 accumulation working width
`define MSBPOS 71  // bit index of an unshifted term's hidden bit
`define SHW    7   // shift-amount control width (0..127, saturating)

`define CLS_8  2'b00
`define CLS_16 2'b01
`define CLS_32 2'b10
`define CLS_19 2'b11

`endif
