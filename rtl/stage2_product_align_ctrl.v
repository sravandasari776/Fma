// MPFMA-DS-001 7.5 - Product Alignment Ctrl.
// Per-lane shift amount to bring a dot product's own exponent up to the
// shared reference exponent (ref_exp - prod_exp[lane]), clamped at zero.
// In multiple-precision mode this only fires when the lane's own addend
// exceeds its own product's magnitude (ref_exp == a_exp); the source
// paper bypasses this block entirely in multiple-precision mode because
// it assumes the product always dominates. This implementation keeps it
// active in both modes for full correctness (see docs/DEVIATIONS.md).
`include "fma_defs.vh"

module stage2_product_align_ctrl (
    input  wire signed [`EXPW-1:0] ref_exp_i,
    input  wire signed [`EXPW-1:0] prod_exp_i,
    output wire [`SHW-1:0]         shift_o
);
  `include "fma_funcs.v"

  wire signed [`EXPW-1:0] diff;
  assign diff = ref_exp_i - prod_exp_i;
  assign shift_o = clamp_shift(diff);
endmodule
