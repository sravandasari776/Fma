// MPFMA-DS-001 8.6 - Complement.
// Applies final sign correction to the CSLA's resolved two's-complement
// value: if its sign bit is set, negate via 1's-complement + Incrementor
// (8.5) to obtain a true sign-magnitude pair for Stage 4.
`include "fma_defs.vh"

module stage3_complement (
    input  wire [`WW-1:0] resolved_i,
    output wire           sign_o,
    output wire [`WW-1:0] magnitude_o
);
  wire [`WW-1:0] inv;
  wire [`WW-1:0] negated;

  assign sign_o = resolved_i[`WW-1];
  assign inv = ~resolved_i;
  incrementer #(`WW) u_inc (.a_i(inv), .sum_o(negated));

  assign magnitude_o = sign_o ? negated : resolved_i;
endmodule
