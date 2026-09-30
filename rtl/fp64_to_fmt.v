// fp64_to_fmt.v
// Decimal I/O shell, input side (outside U_FMA -- see fma_fp64_top.v).
// Converts one IEEE 754 double (the binary form a typed decimal number
// takes) into one lane of the selected FMA format -- E4M3, E5M2, HP,
// DLFloat16, BFloat16, TF32 or SP, chosen by class + exponent width exactly
// like fma_top's pra_i/ewa_i -- rounding to nearest-even, once:
//   - keep the hidden 1 + m mantissa bits of the double's significand,
//   - guard = the next bit, sticky = OR of everything below it,
//   - round up if guard && (sticky || last kept bit), i.e. ties to even,
//   - a carry out of the top renormalizes (exponent + 1),
//   - above the format's largest exponent -> +/-Inf (IEEE overflow),
//   - below its smallest normal exponent the significand is first shifted
//     right (subnormal) and then rounded the same way.
// NaN -> the canonical positive NaN (exponent all ones, mantissa ...001),
// the same one the FMA core produces; +/-Inf -> +/-Inf; a double that is
// zero or subnormal (< 2^-1022, far below every supported format) -> +/-0.
// inexact_o = 1 when the stored value differs from the double.
//
// Combinational. The result is right-justified in bits_o (8, 16, 19 or 32
// bits used). Only variable shifts / masks are used, no variable-width
// part-selects (docs/DEVIATIONS.md, RTL style notes).
`include "fma_defs.vh"

module fp64_to_fmt (
    input  wire [63:0] d_i,
    input  wire [1:0]  cls_i,
    input  wire [3:0]  ew_i,
    output reg  [31:0] bits_o,
    output reg         inexact_o
);
  `include "fma_funcs.v"

  integer            m, bias, total, emin, emax, sh;
  reg                s;
  reg [10:0]         e64;
  reg [51:0]         f;
  reg signed [12:0]  E;
  reg [63:0]         X, Y;
  reg                sticky_sh, guard, sticky, up;
  reg [24:0]         kept;
  reg [7:0]          expf;
  reg [22:0]         mant;
  reg [31:0]         ones_e;

  always @* begin
    m      = mant_width(cls_i, ew_i);
    bias   = bias_of(ew_i);
    total  = class_total_bits(cls_i);
    emin   = 1 - bias;
    emax   = bias;
    ones_e = (32'h1 << ew_i) - 32'h1;

    s   = d_i[63];
    e64 = d_i[62:52];
    f   = d_i[51:0];

    E = 0; sh = 0; X = 0; Y = 0;
    sticky_sh = 1'b0; guard = 1'b0; sticky = 1'b0; up = 1'b0;
    kept = 0; expf = 0; mant = 0; inexact_o = 1'b0;

    if (e64 == 11'h7FF) begin
      // Inf or NaN
      expf = ones_e[7:0];
      if (f != 0) begin
        s    = 1'b0;
        mant = 23'd1;
      end
    end else if (e64 == 11'h000) begin
      // zero, or a double subnormal: below every format's range -> signed zero
      inexact_o = (f != 0);
    end else begin
      E  = $signed({2'b00, e64}) - 13'sd1023;
      X  = {1'b1, f, 11'b0};                     // hidden 1 at bit 63
      sh = (E < emin) ? (emin - E) : 0;          // subnormal: denormalize first
      if (sh >= 64) begin
        Y         = 64'd0;
        sticky_sh = 1'b1;
      end else begin
        Y         = X >> sh;
        sticky_sh = |(X & ((64'd1 << sh) - 64'd1));
      end

      kept   = Y >> (63 - m);                    // hidden bit + m mantissa bits
      guard  = Y[62 - m];
      sticky = sticky_sh | (|(Y & ((64'd1 << (62 - m)) - 64'd1)));
      up     = guard & (sticky | kept[0]);
      inexact_o = guard | sticky;
      kept   = kept + up;

      if (sh == 0) begin
        if (kept[m + 1]) begin                   // 1.11..1 + 1 = 10.00..0
          kept = kept >> 1;
          E    = E + 13'sd1;
        end
        if (E > emax) begin                      // overflow -> infinity
          expf      = ones_e[7:0];
          mant      = 23'd0;
          inexact_o = 1'b1;
        end else begin
          expf = E + bias;
          mant = kept & ((25'd1 << m) - 25'd1);
        end
      end else begin
        // subnormal range: rounding may carry into the hidden bit, which
        // makes it the smallest normal number (exponent field 1)
        expf = kept[m] ? 8'd1 : 8'd0;
        mant = kept & ((25'd1 << m) - 25'd1);
      end
    end

    bits_o = ({31'd0, s} << (total - 1)) | ({24'd0, expf} << m) | {9'd0, mant};
  end
endmodule
