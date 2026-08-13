// MPFMA-DS-001 7.1 - Align Amount Finalizer.
// Computes the addend's right-shift amount as (ref_exp - a_exp) and clamps
// any negative result to zero. ref_exp is the accumulation reference
// exponent for the current lane/mode: in multiple-precision mode each
// lane compares only its own addend against its own product; in
// mixed-precision mode every lane shares the single global winner
// (exp_sel from the Comparator, §6.6) as ref_exp.
`include "fma_defs.vh"

module stage2_align_amount_finalizer (
    input  wire signed [`EXPW-1:0] ref_exp_i,
    input  wire signed [`EXPW-1:0] a_exp_i,
    output wire [`SHW-1:0]         shift_o
);
  `include "fma_funcs.v"

  wire signed [`EXPW-1:0] diff;
  assign diff = ref_exp_i - a_exp_i;
  assign shift_o = clamp_shift(diff);
endmodule
