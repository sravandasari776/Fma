// MPFMA-DS-001 6.6 - Comparator.
// Selects the largest exponent among the (up to 4) dot-product exponents
// and the addend's exponent, active-lane-qualified. This is the "anchor"
// used to normalize/align every other term. label_sel encodes the winner:
// 0..3 = product lane i, 4 = the addend itself. The source paper's
// Comparator only ranks the 4 products (the addend is assumed smaller);
// this implementation extends the comparison to include the addend so
// the design is correct even when the addend's magnitude dominates the
// accumulation (see docs/DEVIATIONS.md).
//
// A term whose value is exactly zero carries a placeholder exponent of 0
// (from the extractor), which is not a real magnitude comparison point --
// without excluding zero terms here, a zero product could outrank a
// genuinely nonzero but very-small-magnitude (very negative true exponent)
// addend or product simply because 0 > a large negative number. zero_i/
// a_zero_i mask those terms out of the comparison entirely; if every term
// is zero the addend wins by default (harmless, since the final result is
// separately detected as exactly zero downstream).
//
// prod_exp_i/lane_valid_i/prod_zero_i are packed vectors (lane i at
// [EXPW*i +: EXPW] / bit i) -- see stage1_unified_extractor.v's header
// comment.
`include "fma_defs.vh"

module stage1_comparator (
    input  wire [`NLANE*`EXPW-1:0] prod_exp_i,
    input  wire [`NLANE-1:0]       lane_valid_i,
    input  wire [`NLANE-1:0]       prod_zero_i,
    input  wire signed [`EXPW-1:0] a_exp_i,
    input  wire                    a_zero_i,
    output reg  signed [`EXPW-1:0] exp_sel_o,
    output reg  [2:0]              label_sel_o
);
  localparam signed [`EXPW-1:0] NEG_INF = -(2**(`EXPW-1));

  integer i;
  reg signed [`EXPW-1:0] best;
  reg [2:0] best_label;

  always @* begin
    best       = a_zero_i ? NEG_INF : a_exp_i;
    best_label = 3'd4; // addend wins by default
    for (i = 0; i < `NLANE; i = i + 1) begin
      if (lane_valid_i[i] && !prod_zero_i[i] &&
          ($signed(prod_exp_i[`EXPW*i +: `EXPW]) > best)) begin
        best       = $signed(prod_exp_i[`EXPW*i +: `EXPW]);
        best_label = i[2:0];
      end
    end
    exp_sel_o   = (best == NEG_INF) ? a_exp_i : best;
    label_sel_o = best_label;
  end
endmodule
