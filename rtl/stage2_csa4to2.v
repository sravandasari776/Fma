// MPFMA-DS-001 7.7 - CSA 4:2 (Stage 2).
// Compresses the aligned addend, the (up to 4) aligned/inverted dot
// products, and the collective two's-complement correction term
// (neg_count_i, from Invert/Swap) into a sum/carry pair, deferring full
// carry propagation to Stage 3. This generalizes the paper's 4:2
// compressor (addend + up to 4 products) with one extra input carrying
// the shared negation correction described in stage2_invert_swap.v.
`include "fma_defs.vh"

module stage2_csa4to2 (
    input  wire [`WW-1:0]        a_term_i,
    input  wire [`NLANE*`WW-1:0] prod_term_i,
    input  wire [2:0]            neg_count_i,
    output wire [`WW-1:0]        sum_o,
    output wire [`WW-1:0]        carry_o
);
  wire [`WW-1:0] corr;
  assign corr = {{(`WW-3){1'b0}}, neg_count_i};

  wire [`WW-1:0] p0, p1, p2, p3;
  assign p0 = prod_term_i[`WW*0 +: `WW];
  assign p1 = prod_term_i[`WW*1 +: `WW];
  assign p2 = prod_term_i[`WW*2 +: `WW];
  assign p3 = prod_term_i[`WW*3 +: `WW];

  wire [`WW-1:0] s0, c0, s1, c1, s2, c2;
  csa32 #(`WW) g0 (a_term_i, p0, p1, s0, c0);
  csa32 #(`WW) g1 (p2,       p3, corr, s1, c1);
  csa32 #(`WW) g2 (s0, c0, s1,                                    s2, c2);
  csa32 #(`WW) g3 (s2, c2, c1,                                    sum_o, carry_o);
endmodule
