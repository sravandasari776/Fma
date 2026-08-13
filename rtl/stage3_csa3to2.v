// MPFMA-DS-001 8.1 - 3-to-2 CSA.
// Further compresses the Stage-2 sum/carry pair ahead of the CSLA. In the
// source paper's pipeline this stage also folds in a "remaining term" left
// uncompressed at the end of Stage 2; this implementation fully compresses
// every term (addend, up to 4 products, negation correction) by the end
// of Stage 2 (stage2_csa4to2), so the third input here is tied to zero.
// The block is retained, wired for a nonzero third input, so the pipeline
// split point can be moved without touching neighboring stages.
`include "fma_defs.vh"

module stage3_csa3to2 (
    input  wire [`WW-1:0] sum_i,
    input  wire [`WW-1:0] carry_i,
    input  wire [`WW-1:0] extra_i,
    output wire [`WW-1:0] sum_o,
    output wire [`WW-1:0] carry_o
);
  csa32 #(`WW) u_csa (sum_i, carry_i, extra_i, sum_o, carry_o);
endmodule
