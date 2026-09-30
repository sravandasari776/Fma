// fmt_to_fp64.v
// Decimal I/O shell, output side (outside U_FMA -- see fma_fp64_top.v).
// Converts one lane of an FMA format (E4M3, E5M2, HP, DLFloat16, BFloat16,
// TF32 or SP, chosen by class + exponent width like fma_top's pra_i/ewa_i)
// into an IEEE 754 double. The conversion is EXACT: every value of all 7
// formats, subnormals included, is a normal double, so nothing is rounded.
//   normal    : exponent E = field - bias, mantissa bits moved to the top
//               of the double's 52-bit fraction
//   subnormal : a priority encoder finds the leading 1 at bit p of the
//               mantissa; E = emin - m + p, the bits below it become the
//               fraction (the double's hidden 1 is the leading 1)
//   +/-0, +/-Inf keep their sign; NaN -> the canonical quiet NaN
//   0x7FF8000000000000.
// Combinational. bits_i is right-justified (8, 16, 19 or 32 bits used).
`include "fma_defs.vh"

module fmt_to_fp64 (
    input  wire [31:0] bits_i,
    input  wire [1:0]  cls_i,
    input  wire [3:0]  ew_i,
    output reg  [63:0] d_o
);
  `include "fma_funcs.v"

  integer            m, bias, total, emin, p, k;
  reg                s;
  reg [7:0]          expf;
  reg [22:0]         mant;
  reg [31:0]         ones_e;
  reg signed [12:0]  E, Eb;
  reg [63:0]         fr;

  always @* begin
    m      = mant_width(cls_i, ew_i);
    bias   = bias_of(ew_i);
    total  = class_total_bits(cls_i);
    emin   = 1 - bias;
    ones_e = (32'h1 << ew_i) - 32'h1;

    s    = bits_i[total - 1];
    expf = (bits_i >> m) & ones_e;
    mant = bits_i & ((32'h1 << m) - 32'h1);
    p = 0; E = 0; Eb = 0; fr = 0;

    if (expf == ones_e[7:0]) begin
      d_o = (mant != 0) ? 64'h7FF8_0000_0000_0000 : {s, 11'h7FF, 52'd0};
    end else if (expf == 8'd0 && mant == 23'd0) begin
      d_o = {s, 63'd0};
    end else begin
      if (expf == 8'd0) begin
        // subnormal: normalize on the leading 1 (highest set bit wins)
        for (k = 0; k < 23; k = k + 1)
          if (mant[k]) p = k;
        E  = emin - m + p;
        fr = {41'd0, mant} << (52 - p);          // leading 1 lands on bit 52 (dropped)
      end else begin
        E  = expf - bias;
        fr = {41'd0, mant} << (52 - m);
      end
      Eb  = E + 13'sd1023;
      d_o = {s, Eb[10:0], fr[51:0]};
    end
  end
endmodule
