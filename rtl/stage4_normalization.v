// MPFMA-DS-001 9.1 - Normalization.
// Shifts the post-Complement magnitude by the amount computed by the
// LZAU (exp_adjust_i: positive = right shift/overflow, negative = left
// shift/cancellation) so its leading '1' returns to bit MSBPOS. A right
// shift can expose additional bits below the rounding window, which are
// OR'd into extra_sticky_o.
//
// Subnormal results (the spec's "LZAU prediction not valid, use the
// exponent instead" path): the left shift is limited so the result's
// exponent never drops below the output format's minimum normal exponent
// emin = 1 - bias. If ref_exp_i + exp_adjust_i < emin, the value is shifted
// by (emin - ref_exp_i) instead -- which may even be a right shift -- and
// its leading '1' ends up below MSBPOS (hidden bit = 0). Rounding (9.2)
// then rounds it once, at the correct subnormal precision, and Output
// Finalizing (9.5) packs it with a zero exponent field. exp_adjust_o is
// the shift actually applied, for the Exponent Adjuster (9.3).
`include "fma_defs.vh"

module stage4_normalization (
    input  wire [`WW-1:0]          magnitude_i,
    input  wire signed [`EXPW-1:0] exp_adjust_i,
    input  wire signed [`EXPW-1:0] ref_exp_i,
    input  wire [3:0]              ew_i,
    output reg  [`WW-1:0]          normalized_o,
    output reg                     extra_sticky_o,
    output reg  signed [`EXPW-1:0] exp_adjust_o
);
  `include "fma_funcs.v"

  reg signed [`EXPW-1:0] emin;
  reg signed [`EXPW-1:0] adj;
  reg [`SHW-1:0] shamt;
  reg [`WW:0]    packed_result;

  always @* begin
    emin = 1 - bias_of(ew_i);
    if (ref_exp_i + exp_adjust_i < emin) adj = emin - ref_exp_i;
    else                                 adj = exp_adjust_i;
    exp_adjust_o = adj;

    if (adj >= 0) begin
      shamt = clamp_shift(adj); // saturates at 127 (>= WW: everything -> sticky)
      packed_result  = shift_right_sticky(magnitude_i, shamt);
      normalized_o   = packed_result[`WW-1:0];
      extra_sticky_o = packed_result[`WW];
    end else begin
      shamt = clamp_shift(-adj);
      normalized_o   = magnitude_i << shamt;
      extra_sticky_o = 1'b0;
    end
  end
endmodule
