// MPFMA-DS-001 7.3 - Invert/Swap.
// Establishes one consistent sign polarity (that of the anchor selected by
// the Comparator, §6.6/label_sel) for every term about to enter the CSA
// compression tree. A term whose own sign disagrees with the anchor's is
// bitwise-inverted (1's complement -- no adder needed); the collective
// "+1 per inverted term" two's-complement correction is not applied here
// but is instead accumulated into neg_count_o and injected as one extra
// CSA input in stage2_csa4to2, which is mathematically equivalent to
// negating each term individually (see docs/DEVIATIONS.md) while sharing
// a single increment across all terms, in the spirit of the source
// paper's shared-increment Incrementor (§8.5).
//
// Rounding correctness for negated terms whose own alignment shift
// truncated nonzero bits (sticky_i=1): true two's-complement negation of
// a value with a dropped fractional remainder R in (0,1 ULP) is
// -(truncated)-1+((1-R)) -- not simply -(truncated) = ~truncated+1. Since
// R is unknown (only its non-zero-ness is), the +1 correction is skipped
// for exactly those terms; ~truncated (no +1) is then a guaranteed lower
// bound of the true negated value for every sign combination, which keeps
// the aggregate WW-bit sum a lower bound of the exact mathematical result
// whenever any term (positive or negated) had a nonzero truncated
// remainder -- i.e. it keeps the "sticky=1 means round up on a tie" rule
// valid regardless of which terms' truncation produced it.
//
// Per-lane ports are packed vectors (lane i at [WW*i +: WW] / bit i) --
// see stage1_unified_extractor.v's header comment.
`include "fma_defs.vh"

module stage2_invert_swap (
    input  wire [`WW-1:0]         a_aligned_i,
    input  wire                   a_sign_i,
    input  wire                   a_sticky_i,
    input  wire [`NLANE*`WW-1:0]  prod_aligned_i,
    input  wire [`NLANE-1:0]      prod_sign_i,
    input  wire [`NLANE-1:0]      lane_valid_i,
    input  wire [`NLANE-1:0]      prod_sticky_i,
    input  wire [2:0]             label_sel_i,
    output wire [`WW-1:0]         a_term_o,
    output wire [`NLANE*`WW-1:0]  prod_term_o,
    output wire [2:0]             neg_count_o,
    output wire                   ref_sign_o
);
  wire ref_sign;
  assign ref_sign = (label_sel_i == 3'd4) ? a_sign_i : prod_sign_i[label_sel_i];
  assign ref_sign_o = ref_sign;

  wire a_nz, a_inv;
  assign a_nz  = (a_aligned_i != 0);
  assign a_inv = a_nz && (a_sign_i != ref_sign);
  assign a_term_o = a_inv ? ~a_aligned_i : a_aligned_i;

  wire [`NLANE-1:0] p_inv;
  genvar L;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : PT
      wire nz;
      wire [`WW-1:0] lane_aligned;
      assign lane_aligned = prod_aligned_i[`WW*L +: `WW];
      assign nz = lane_valid_i[L] && (lane_aligned != 0);
      assign p_inv[L] = nz && (prod_sign_i[L] != ref_sign);
      assign prod_term_o[`WW*L +: `WW] = !lane_valid_i[L] ? {`WW{1'b0}} :
                               (p_inv[L] ? ~lane_aligned : lane_aligned);
    end
  endgenerate

  wire a_inv_exact;
  wire [`NLANE-1:0] p_inv_exact;
  assign a_inv_exact = a_inv && !a_sticky_i;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : PTC
      assign p_inv_exact[L] = p_inv[L] && !prod_sticky_i[L];
    end
  endgenerate

  assign neg_count_o = {2'b0, a_inv_exact} + {2'b0, p_inv_exact[0]} + {2'b0, p_inv_exact[1]} +
                        {2'b0, p_inv_exact[2]} + {2'b0, p_inv_exact[3]};
endmodule
