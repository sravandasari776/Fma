// MPFMA-DS-001 6.2 - Bias Generator
// Computes the format-specific IEEE bias (2^(ew-1)-1) for a given
// exponent width, substituting Bias-1 when the operand is subnormal
// (sf=1), per the source spec.
`include "fma_defs.vh"

module stage1_bias_generator (
    input  wire [3:0] ew_i,   // active exponent width, 4..8
    input  wire       sf_i,   // subnormal flag for this operand
    output wire [7:0] bias_o  // effective bias used for exponent decode
);
  wire [7:0] bias_full;
  assign bias_full = (8'd1 << (ew_i - 4'd1)) - 8'd1;
  assign bias_o = sf_i ? (bias_full - 8'd1) : bias_full;
endmodule
