// MPFMA-DS-001 6.1 - Configurable Normal/Mixed-Precision Sign, Exponent and
// Mantissa Unified Extractor. Splits a_i/b_i/c_i into per-lane sign/exponent/
// significand fields, derives the subnormal flag, invokes the Bias
// Generator (6.2) and Unified LZC (6.4) to renormalize any subnormal
// operand, and produces the unified representation used by every later
// stage (24-bit left-justified significand, hidden bit at sig[23]).
//
// Ports are flattened, packed per-field vectors (lane i of a W-bit field
// occupies bits [W*i +: W]) rather than an array of a record type or even
// a per-field unpacked array: icarus's elaborator does not reliably carry
// a value across a module port declared as an unpacked array
// (`output reg [W-1:0] foo [N]`) -- the receiving side reads back X
// regardless of driver -- so every inter-module array in this design uses
// packed vectors instead (see docs/DEVIATIONS.md).
`include "fma_defs.vh"

module stage1_unified_extractor (
    input  wire [63:0]     a_i, b_i, c_i,
    input  wire [1:0]      pra_i, prm_i,
    input  wire [3:0]      ewa_i, ewm_i,

    output wire [`NLANE-1:0]      a_sign_o,
    output wire [`NLANE-1:0]      b_sign_o,
    output wire [`NLANE-1:0]      c_sign_o,
    output wire [`NLANE*`EXPW-1:0] a_exp_o,
    output wire [`NLANE*`EXPW-1:0] b_exp_o,
    output wire [`NLANE*`EXPW-1:0] c_exp_o,
    output wire [`NLANE*`SIGW-1:0] a_sig_o,
    output wire [`NLANE*`SIGW-1:0] b_sig_o,
    output wire [`NLANE*`SIGW-1:0] c_sig_o,
    output wire [`NLANE-1:0]      a_zero_o,
    output wire [`NLANE-1:0]      b_zero_o,
    output wire [`NLANE-1:0]      c_zero_o,
    output wire [`NLANE-1:0]      a_nan_o,
    output wire [`NLANE-1:0]      b_nan_o,
    output wire [`NLANE-1:0]      c_nan_o,
    output wire [`NLANE-1:0]      a_inf_o,
    output wire [`NLANE-1:0]      b_inf_o,
    output wire [`NLANE-1:0]      c_inf_o
);
  `include "fma_funcs.v"

  genvar L;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : LANES
      wire [31:0] slice_a, slice_b, slice_c;
      wire        sign_a, sign_b, sign_c;
      wire [7:0]  expf_full_a, expf_full_b, expf_full_c; // 8-bit window, MSB-aligned to the field
      wire [7:0]  expf_a, expf_b, expf_c;                // right-justified ew-bit value
      wire        sf_a, sf_b, sf_c;
      wire [7:0]  bias_a, bias_b, bias_c;
      reg  [`SIGW-1:0] raw_a, raw_b, raw_c;
      wire [4:0]  lzc_a, lzc_b, lzc_c;
      wire        az_a, az_b, az_c;
      wire        mant_nz_a, mant_nz_b, mant_nz_c;
      wire [31:0] m_a, m_b, m_c;
      integer     k;

      assign slice_a = lane_slice(a_i, pra_i, L);
      assign slice_b = lane_slice(b_i, prm_i, L);
      assign slice_c = lane_slice(c_i, prm_i, L);

      assign m_a = mant_width(pra_i, ewa_i);
      assign m_b = mant_width(prm_i, ewm_i);
      assign m_c = mant_width(prm_i, ewm_i);

      assign sign_a = slice_a[class_total_bits(pra_i)-1];
      assign sign_b = slice_b[class_total_bits(prm_i)-1];
      assign sign_c = slice_c[class_total_bits(prm_i)-1];

      // Grab an 8-bit window starting right below the sign bit (its MSB,
      // bit 7, is the field's true top exponent bit). A direct constant
      // part-select `[total-2 -: 8]` underflows below bit 0 for the 8-bit
      // class (only 7 bits exist below its sign bit), producing X, so
      // instead left-shift the whole 32-bit slice by a runtime amount so
      // the (total-1) exponent+mantissa bits become left-justified at the
      // top of the register (zero-filled from below -- never X) and then
      // take a constant top-8-bit window of that. A runtime right-shift
      // by (8-ew) then discards the low bits that belong to the mantissa
      // whenever ew<8, leaving a right-justified ew-bit value.
      wire [31:0] shifted_a, shifted_b, shifted_c;
      assign shifted_a = slice_a << (32 - (class_total_bits(pra_i) - 1));
      assign shifted_b = slice_b << (32 - (class_total_bits(prm_i) - 1));
      assign shifted_c = slice_c << (32 - (class_total_bits(prm_i) - 1));
      assign expf_full_a = shifted_a[31:24];
      assign expf_full_b = shifted_b[31:24];
      assign expf_full_c = shifted_c[31:24];
      assign expf_a = expf_full_a >> (8 - ewa_i);
      assign expf_b = expf_full_b >> (8 - ewm_i);
      assign expf_c = expf_full_c >> (8 - ewm_i);

      assign sf_a = (expf_a == 8'h0);
      assign sf_b = (expf_b == 8'h0);
      assign sf_c = (expf_c == 8'h0);

      stage1_bias_generator u_bias_a (.ew_i(ewa_i), .sf_i(sf_a), .bias_o(bias_a));
      stage1_bias_generator u_bias_b (.ew_i(ewm_i), .sf_i(sf_b), .bias_o(bias_b));
      stage1_bias_generator u_bias_c (.ew_i(ewm_i), .sf_i(sf_c), .bias_o(bias_c));

      // mantissa bits placed explicitly bit-by-bit (formats have differing M)
      always @* begin
        raw_a = 0;
        raw_a[`SIGW-1] = ~sf_a;
        for (k = 0; k < 23; k = k + 1)
          if (k < m_a) raw_a[`SIGW-2-k] = slice_a[m_a-1-k];
      end
      always @* begin
        raw_b = 0;
        raw_b[`SIGW-1] = ~sf_b;
        for (k = 0; k < 23; k = k + 1)
          if (k < m_b) raw_b[`SIGW-2-k] = slice_b[m_b-1-k];
      end
      always @* begin
        raw_c = 0;
        raw_c[`SIGW-1] = ~sf_c;
        for (k = 0; k < 23; k = k + 1)
          if (k < m_c) raw_c[`SIGW-2-k] = slice_c[m_c-1-k];
      end

      stage1_unified_lzc u_lzc_a (.sig_i(raw_a), .lzc_o(lzc_a), .az_o(az_a));
      stage1_unified_lzc u_lzc_b (.sig_i(raw_b), .lzc_o(lzc_b), .az_o(az_b));
      stage1_unified_lzc u_lzc_c (.sig_i(raw_c), .lzc_o(lzc_c), .az_o(az_c));

      wire all1_a, all1_b, all1_c;
      reg [7:0] ew_ones_a, ew_ones_b, ew_ones_c;
      always @* begin
        ew_ones_a = 0; for (k = 0; k < ewa_i; k = k + 1) ew_ones_a[k] = 1'b1;
        ew_ones_b = 0; for (k = 0; k < ewm_i; k = k + 1) ew_ones_b[k] = 1'b1;
        ew_ones_c = 0; for (k = 0; k < ewm_i; k = k + 1) ew_ones_c[k] = 1'b1;
      end
      assign all1_a = (expf_a == ew_ones_a);
      assign all1_b = (expf_b == ew_ones_b);
      assign all1_c = (expf_c == ew_ones_c);

      // "any mantissa bit set" without a variable-width part-select: OR
      // the raw (pre-hidden-bit) significand bits directly (raw_*[SIGW-1]
      // is forced to ~sf so it never contributes to this check for the
      // all-1s-exponent case, which is only meaningful when sf=0 anyway).
      assign mant_nz_a = |raw_a[`SIGW-2:0];
      assign mant_nz_b = |raw_b[`SIGW-2:0];
      assign mant_nz_c = |raw_c[`SIGW-2:0];

      reg signed [`EXPW-1:0] a_exp_lane, b_exp_lane, c_exp_lane;
      reg [`SIGW-1:0]        a_sig_lane, b_sig_lane, c_sig_lane;
      assign a_exp_o[`EXPW*L +: `EXPW] = a_exp_lane;
      assign b_exp_o[`EXPW*L +: `EXPW] = b_exp_lane;
      assign c_exp_o[`EXPW*L +: `EXPW] = c_exp_lane;
      assign a_sig_o[`SIGW*L +: `SIGW] = a_sig_lane;
      assign b_sig_o[`SIGW*L +: `SIGW] = b_sig_lane;
      assign c_sig_o[`SIGW*L +: `SIGW] = c_sig_lane;

      reg a_sign_r, a_nan_r, a_inf_r, a_zero_r;
      reg b_sign_r, b_nan_r, b_inf_r, b_zero_r;
      reg c_sign_r, c_nan_r, c_inf_r, c_zero_r;
      assign a_sign_o[L] = a_sign_r; assign a_nan_o[L] = a_nan_r;
      assign a_inf_o[L]  = a_inf_r;  assign a_zero_o[L] = a_zero_r;
      assign b_sign_o[L] = b_sign_r; assign b_nan_o[L] = b_nan_r;
      assign b_inf_o[L]  = b_inf_r;  assign b_zero_o[L] = b_zero_r;
      assign c_sign_o[L] = c_sign_r; assign c_nan_o[L] = c_nan_r;
      assign c_inf_o[L]  = c_inf_r;  assign c_zero_o[L] = c_zero_r;

      always @* begin
        a_sign_r = sign_a;
        a_nan_r  = all1_a && mant_nz_a;
        a_inf_r  = all1_a && !a_nan_r;
        if (all1_a) begin
          a_zero_r = 1'b0; a_exp_lane = 0; a_sig_lane = 0;
        end else if (sf_a && az_a) begin
          a_zero_r = 1'b1; a_exp_lane = 0; a_sig_lane = 0;
        end else if (sf_a) begin
          a_zero_r = 1'b0;
          a_sig_lane = raw_a << lzc_a;
          a_exp_lane = -($signed({4'b0,bias_a})) - $signed({7'b0,lzc_a});
        end else begin
          a_zero_r = 1'b0;
          a_sig_lane = raw_a;
          a_exp_lane = $signed({4'b0, expf_a}) - $signed({4'b0, bias_a});
        end
      end

      always @* begin
        b_sign_r = sign_b;
        b_nan_r  = all1_b && mant_nz_b;
        b_inf_r  = all1_b && !b_nan_r;
        if (all1_b) begin
          b_zero_r = 1'b0; b_exp_lane = 0; b_sig_lane = 0;
        end else if (sf_b && az_b) begin
          b_zero_r = 1'b1; b_exp_lane = 0; b_sig_lane = 0;
        end else if (sf_b) begin
          b_zero_r = 1'b0;
          b_sig_lane = raw_b << lzc_b;
          b_exp_lane = -($signed({4'b0,bias_b})) - $signed({7'b0,lzc_b});
        end else begin
          b_zero_r = 1'b0;
          b_sig_lane = raw_b;
          b_exp_lane = $signed({4'b0, expf_b}) - $signed({4'b0, bias_b});
        end
      end

      always @* begin
        c_sign_r = sign_c;
        c_nan_r  = all1_c && mant_nz_c;
        c_inf_r  = all1_c && !c_nan_r;
        if (all1_c) begin
          c_zero_r = 1'b0; c_exp_lane = 0; c_sig_lane = 0;
        end else if (sf_c && az_c) begin
          c_zero_r = 1'b1; c_exp_lane = 0; c_sig_lane = 0;
        end else if (sf_c) begin
          c_zero_r = 1'b0;
          c_sig_lane = raw_c << lzc_c;
          c_exp_lane = -($signed({4'b0,bias_c})) - $signed({7'b0,lzc_c});
        end else begin
          c_zero_r = 1'b0;
          c_sig_lane = raw_c;
          c_exp_lane = $signed({4'b0, expf_c}) - $signed({4'b0, bias_c});
        end
      end
    end
  endgenerate
endmodule
