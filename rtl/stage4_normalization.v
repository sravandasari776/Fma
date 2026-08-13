// MPFMA-DS-001 9.1 - Normalization.
// Shifts the post-Complement magnitude by the amount computed by the
// LZAU (exp_adjust_i: positive = right shift/overflow, negative = left
// shift/cancellation) so its leading '1' returns to bit MSBPOS. A right
// shift can expose additional bits below the rounding window, which are
// OR'd into extra_sticky_o.
`include "fma_defs.vh"

module stage4_normalization (
    input  wire [`WW-1:0]          magnitude_i,
    input  wire signed [`EXPW-1:0] exp_adjust_i,
    output reg  [`WW-1:0]          normalized_o,
    output reg                     extra_sticky_o
);
  `include "fma_funcs.v"

  reg [`SHW-1:0] shamt;
  reg [`WW:0]    packed_result;

  always @* begin
    if (exp_adjust_i >= 0) begin
      shamt = exp_adjust_i[`SHW-1:0];
      packed_result  = shift_right_sticky(magnitude_i, shamt);
      normalized_o   = packed_result[`WW-1:0];
      extra_sticky_o = packed_result[`WW];
    end else begin
      shamt = (-exp_adjust_i);
      normalized_o   = magnitude_i << shamt;
      extra_sticky_o = 1'b0;
    end
  end
endmodule
