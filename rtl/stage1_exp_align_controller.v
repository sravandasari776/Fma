// MPFMA-DS-001 6.5 - Exponent & Alignment Controller.
// Resolves each lane's raw Booth (sum,carry) product into its true,
// normalized product exponent/sign (the carry-save pair is only fully
// resolved here for exponent tracking; the sum/carry pair itself is
// carried forward untouched to Stage 2 for the real datapath add).
// Because the extractor (6.1) already renormalizes every operand into the
// unified 24-bit hidden-bit-at-MSB form, sig_b*sig_c always lands in
// [2^46, 2^48), so only a single-bit (0/+1) exponent correction is ever
// needed post-multiply -- this replaces the source paper's pre-multiply
// LZC-sum prediction with an equivalent post-multiply resolution.
//
// The full 48-bit product is kept (normalized so its leading '1' is at
// bit 47), never truncated: the accumulation frame is wide enough to hold
// it exactly (fma_defs.vh), so the product needs no sticky of its own and
// A + B*C is rounded exactly once, as a true fused multiply-add requires.
// (An earlier revision cut the product to 24 bits + a sticky flag; that
// lost the guard bit of SP products and broke exact cancellation such as
// A = -round(B*C) -- see docs/DEVIATIONS.md.)
//
// All per-lane ports are packed vectors (lane i of a W-bit field at bits
// [W*i +: W]) -- see stage1_unified_extractor.v's header comment.
`include "fma_defs.vh"

module stage1_exp_align_controller (
    input  wire [`NLANE-1:0]        b_sign_i, c_sign_i,
    input  wire [`NLANE*`EXPW-1:0]  b_exp_i,  c_exp_i,
    input  wire [`NLANE-1:0]        b_zero_i, c_zero_i,
    input  wire [`NLANE-1:0]        b_nan_i,  c_nan_i,
    input  wire [`NLANE-1:0]        b_inf_i,  c_inf_i,
    input  wire [`NLANE*48-1:0]     sum_i,
    input  wire [`NLANE*48-1:0]     carry_i,
    output wire [`NLANE*`EXPW-1:0]  prod_exp_o,
    output wire [`NLANE*`PSIGW-1:0] prod_sig_o,
    output wire [`NLANE-1:0]        prod_sign_o,
    output wire [`NLANE-1:0]        prod_zero_o,
    output wire [`NLANE-1:0]        prod_nan_o,
    output wire [`NLANE-1:0]        prod_inf_o
);
  genvar L;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : EP
      wire [48:0] resolved;
      wire        msb47;
      reg  signed [`EXPW-1:0] prod_exp_lane;
      reg  [`PSIGW-1:0]       prod_sig_lane;
      assign resolved = {1'b0, sum_i[48*L +: 48]} + {1'b0, carry_i[48*L +: 48]};
      assign msb47 = resolved[47];
      assign prod_exp_o[`EXPW*L +: `EXPW] = prod_exp_lane;
      assign prod_sig_o[`PSIGW*L +: `PSIGW] = prod_sig_lane;

      reg prod_sign_r, prod_zero_r, prod_nan_r, prod_inf_r;
      assign prod_sign_o[L]   = prod_sign_r;
      assign prod_zero_o[L]   = prod_zero_r;
      assign prod_nan_o[L]    = prod_nan_r;
      assign prod_inf_o[L]    = prod_inf_r;

      always @* begin
        prod_sign_r = b_sign_i[L] ^ c_sign_i[L];
        prod_zero_r = b_zero_i[L] | c_zero_i[L];
        prod_nan_r  = b_nan_i[L] | c_nan_i[L] |
                        (b_inf_i[L] && c_zero_i[L]) ||
                        (c_inf_i[L] && b_zero_i[L]);
        prod_inf_r  = (b_inf_i[L] | c_inf_i[L]) && !prod_nan_r;
        prod_exp_lane  = $signed(b_exp_i[`EXPW*L +: `EXPW]) + $signed(c_exp_i[`EXPW*L +: `EXPW]) +
                          (msb47 ? 12'sd1 : 12'sd0);
        // exact product, leading '1' moved to bit 47 (no bits dropped)
        prod_sig_lane  = prod_zero_r ? 0 : (msb47 ? resolved[47:0] : {resolved[46:0], 1'b0});
      end
    end
  endgenerate
endmodule
