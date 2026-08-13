// Generic reusable barrel right-shifter: places a 24-bit unified
// significand into the WW-bit accumulation frame at MSBPOS and right
// shifts by the supplied amount, producing the sticky OR of every bit
// shifted below bit 0. Shared by the Addend Alignment (7.2) and
// Multiplication Aligner (7.6) blocks, which are functionally identical
// hardware in this design (the source paper's separate 31-bit-aligner
// cascade for the addend vs. the dedicated product aligner are both barrel
// shifters over the same unified representation).
`include "fma_defs.vh"

module align_shifter (
    input  wire [`SIGW-1:0] sig_i,
    input  wire [`SHW-1:0]  shift_i,
    output wire [`WW-1:0]   aligned_o,
    output wire             sticky_o
);
  // plain Verilog has no global function scope; this module needs its own
  // local copy of shift_right_sticky (and the shift_mask it calls).
  `include "fma_funcs.v"

  wire [`WW-1:0] placed;
  assign placed = {3'b0, sig_i, 13'b0}; // sig_i[23] lands at bit MSBPOS (36)

  wire [`WW:0] packed_result;
  assign packed_result = shift_right_sticky(placed, shift_i);
  assign aligned_o = packed_result[`WW-1:0];
  assign sticky_o  = packed_result[`WW];
endmodule
