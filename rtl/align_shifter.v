// Generic reusable barrel right-shifter: places an SW-bit significand
// (SW=24 for the addend, SW=48 for a full product) into the WW-bit
// accumulation frame with its MSB (hidden bit) at MSBPOS, and right shifts
// it by the supplied amount. Shared by the Addend Alignment (7.2) and
// Multiplication Aligner (7.6) blocks, which are functionally identical
// hardware in this design (the source paper's separate 31-bit-aligner
// cascade for the addend vs. the dedicated product aligner are both barrel
// shifters over the same unified representation).
//
// Sticky jamming: frame bit 0 is reserved (no unshifted term ever reaches
// it, see fma_defs.vh). Every bit shifted out below bit 1 -- including a
// bit that lands exactly on bit 0 -- is OR-ed into aligned_o[0]. An inexact
// term T+R (0 < R < 1 unit of bit 1) is thus carried as "T + 1/2", which is
// strictly between the same two bit-1 grid points as the true value, and
// stays so after two's-complement negation in Invert/Swap. This keeps the
// sign of a truncated remainder correct all the way to Rounding (a plain
// unsigned sticky flag cannot: it says "something was lost" but not whether
// the lost amount must be added or subtracted).
//
// sticky_o is the plain OR of every bit shifted out (below bit 0 of the
// frame), kept as an alignment "inexact" indicator for Sticky Logic (8.2).
`include "fma_defs.vh"

module align_shifter #(
    parameter SW = `SIGW
) (
    input  wire [SW-1:0]    sig_i,
    input  wire [`SHW-1:0]  shift_i,
    output wire [`WW-1:0]   aligned_o,
    output wire             sticky_o
);
  // plain Verilog has no global function scope; this module needs its own
  // local copy of shift_right_sticky (and the shift_mask it calls).
  `include "fma_funcs.v"

  wire [`WW-1:0] placed;
  assign placed = {{(`WW-1-`MSBPOS){1'b0}}, sig_i, {(`MSBPOS+1-SW){1'b0}}}; // sig_i[SW-1] at bit MSBPOS

  wire [`WW:0] packed_result;
  assign packed_result = shift_right_sticky(placed, shift_i);
  assign sticky_o  = packed_result[`WW];
  assign aligned_o = {packed_result[`WW-1:1], packed_result[0] | packed_result[`WW]};
endmodule
