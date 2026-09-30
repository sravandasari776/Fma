// MPFMA-DS-001 9.4 - Sign Detection.
// stage2_invert_swap normalizes every term to be relative to one anchor
// polarity (ref_sign_i, the sign of the winning/largest term selected by
// the Comparator) before compression; the Stage-3 Complement block's
// sign_incr_i therefore only reports whether the *relative* (all-positive-
// convention) sum came out net-negative (e.g. a same-or-larger negative
// term won the accumulation despite not being the exponent anchor) -- it
// does not by itself carry the anchor's own sign. The true final sign is
// their XOR: S_MM/S_A/Sign_Incr combined, per MPFMA-DS-001's textual
// description of this block.
//
// Special results (IEEE 754 rules):
//   NaN            -> sign 0 (canonical quiet NaN)
//   +/-Infinity    -> the sign of the infinite operand/product (inf_sign_i)
//   exact zero     -> zero_sign_i: -0 only if every term was -0 (e.g.
//                     -0 + (-0)*(+x)); a sum that cancels to zero is +0
// A nonzero result that later rounds to zero keeps its computed sign.
module stage4_sign_detection (
    input  wire sign_incr_i,
    input  wire ref_sign_i,
    input  wire is_zero_i,
    input  wire zero_sign_i,
    input  wire is_nan_i,
    input  wire is_inf_i,
    input  wire inf_sign_i,
    output wire sign_o
);
  assign sign_o = is_nan_i  ? 1'b0 :
                  is_inf_i  ? inf_sign_i :
                  is_zero_i ? zero_sign_i :
                              (sign_incr_i ^ ref_sign_i);
endmodule
