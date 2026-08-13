// MPFMA-DS-001 8.3 - CSLA (Carry-Select Adder).
// Resolves the compressed sum/carry pair into an ordinary WW-bit two's-
// complement value. The upper half is computed twice (assuming the lower
// half's carry-out is 0 or 1) and selected once that carry actually
// resolves, avoiding a full-width ripple on the critical path.
`include "fma_defs.vh"

module stage3_csla (
    input  wire [`WW-1:0] sum_i,
    input  wire [`WW-1:0] carry_i,
    output wire [`WW-1:0] resolved_o
);
  localparam LO = `WW/2;
  localparam HI = `WW - LO;

  wire [LO:0]   lo_res;   // extra bit = carry-out
  wire [HI-1:0] hi_res0, hi_res1;

  assign lo_res  = {1'b0, sum_i[LO-1:0]} + {1'b0, carry_i[LO-1:0]};
  assign hi_res0 = sum_i[`WW-1:LO] + carry_i[`WW-1:LO];
  assign hi_res1 = sum_i[`WW-1:LO] + carry_i[`WW-1:LO] + 1'b1;

  assign resolved_o = lo_res[LO] ? {hi_res1, lo_res[LO-1:0]} : {hi_res0, lo_res[LO-1:0]};
endmodule
