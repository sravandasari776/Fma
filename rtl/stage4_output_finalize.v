// MPFMA-DS-001 9.5 - Output Finalizing.
// Packs the final sign, true exponent and rounded 24-bit significand into
// the target format's S/E/M bit pattern (class + exponent width select
// the exact format per fma_defs.vh's format table). Handles overflow-to-
// infinity and subnormal/zero results.
//
// Subnormals need no shifting here: Normalization (9.1) already stopped
// the value at the minimum exponent and Rounding (9.2) already rounded it
// at subnormal precision, so a result whose hidden bit sig_i[SIGW-1] is 0
// is simply packed with a zero exponent field (and a subnormal that
// rounded up into the hidden bit becomes the smallest normal number,
// exponent field 1, automatically). (An earlier revision rounded at
// normal precision and then truncated here, which is double rounding --
// see docs/DEVIATIONS.md.)
//
// The sign is fully resolved upstream by Sign Detection (9.4), including
// NaN (always +), infinities and signed zero.
`include "fma_defs.vh"

module stage4_output_finalize (
    input  wire                    sign_i,
    input  wire signed [`EXPW-1:0] exp_i,
    input  wire [`SIGW-1:0]        sig_i,
    input  wire                    is_zero_i,
    input  wire                    is_nan_i,
    input  wire                    is_inf_i,
    input  wire [1:0]              cls_i,
    input  wire [3:0]              ew_i,
    output reg  [31:0]             packed_o
);
  `include "fma_funcs.v"

  integer m;
  integer bias;
  integer total;
  integer k;
  reg signed [`EXPW-1:0] exp_field;
  reg [22:0] mant_out;
  reg [7:0]  exp_out;

  always @* begin
    m     = mant_width(cls_i, ew_i);
    bias  = bias_of(ew_i);
    total = class_total_bits(cls_i);
    mant_out = 0;
    exp_out  = 0;

    if (is_nan_i) begin
      for (k = 0; k < ew_i; k = k + 1) exp_out[k] = 1'b1;
      mant_out[0] = 1'b1; // quiet-ish, nonzero mantissa
    end else if (is_inf_i || (exp_i + bias) >= ((1 << ew_i) - 1)) begin
      for (k = 0; k < ew_i; k = k + 1) exp_out[k] = 1'b1;
      mant_out = 0;
    end else if (is_zero_i) begin
      exp_out = 0;
      mant_out = 0;
    end else begin
      exp_field = exp_i + bias;
      // hidden bit clear => subnormal (or rounded to zero): exponent field 0
      exp_out = sig_i[`SIGW-1] ? exp_field[7:0] : 8'h0;
      // stored mantissa bit k (k=0 is the field's LSB) maps to sig_i bit
      // (SIGW-1-m+k): sig_i[SIGW-1] is the hidden bit, sig_i[SIGW-2] is
      // the mantissa's MSB (adjacent to the binary point), ... down to
      // sig_i[SIGW-1-m] being the field's LSB when m bits are kept.
      for (k = 0; k < m; k = k + 1) mant_out[k] = sig_i[`SIGW-1-m+k];
    end
  end

  // exponent field width varies (ew_i bits); write it precisely.
  always @* begin
    packed_o = 0;
    packed_o[total-1] = sign_i;
    for (k = 0; k < 8; k = k + 1)
      if (k < ew_i) packed_o[total-2-k] = exp_out[ew_i-1-k];
    if (m > 0)
      for (k = 0; k < m; k = k + 1) packed_o[k] = mant_out[k];
  end
endmodule
