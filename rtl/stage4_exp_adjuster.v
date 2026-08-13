// MPFMA-DS-001 9.3 - Exponent Adjuster.
// Combines the reference exponent, the LZAU-driven normalization shift,
// and any rounding carry-out into the final true (unbiased) exponent.
`include "fma_defs.vh"

module stage4_exp_adjuster (
    input  wire signed [`EXPW-1:0] ref_exp_i,
    input  wire signed [`EXPW-1:0] exp_adjust_i,
    input  wire                    rnd_ovf_i,
    output wire signed [`EXPW-1:0] final_exp_o
);
  assign final_exp_o = ref_exp_i + exp_adjust_i + (rnd_ovf_i ? 12'sd1 : 12'sd0);
endmodule
