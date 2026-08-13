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

`define WW     40  // Stage 2/3 accumulation working width
`define MSBPOS 36  // bit index of an unshifted term's hidden bit
`define SHW    6   // shift-amount control width (0..63, saturating)

`define CLS_8  2'b00
`define CLS_16 2'b01
`define CLS_32 2'b10
`define CLS_19 2'b11

`endif
