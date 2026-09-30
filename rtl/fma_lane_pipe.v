// fma_lane_pipe.v
// Self-contained realization of Stages 2-4 (MPFMA-DS-001 §7-9) for one
// accumulation: one addend plus up to four dot products (products beyond
// p_valid_i are ignored). fma_top instantiates NLANE=4 copies:
//   - Multiple-precision mode: each copy handles one independent lane's
//     own addend + its own single product (p_valid_i = {1,0,0,0}),
//     producing NLANE independent results.
//   - Mixed-precision mode: only copy 0 is used, fed the shared addend and
//     all active dot products; copies 1-3 are idle (see fma_top.v).
//
// Contains its own two internal pipeline registers (after Stage 2, after
// Stage 3); the Stage1->Stage2 boundary register lives in fma_top, giving
// the spec's three total pipeline registers across the four stages.
//
// Per-lane ports (p_*) are packed vectors, lane i of a W-bit field at
// bits [W*i +: W] -- see stage1_unified_extractor.v's header comment on
// why (icarus does not reliably pass unpacked-array ports across module
// boundaries).
`include "fma_defs.vh"

module fma_lane_pipe (
    input  wire clk_i,
    input  wire rst_n_i,

    input  wire                    a_sign_i,
    input  wire signed [`EXPW-1:0] a_exp_i,
    input  wire [`SIGW-1:0]        a_sig_i,
    input  wire                    a_zero_i,
    input  wire                    a_nan_i,
    input  wire                    a_inf_i,

    input  wire [`NLANE-1:0]       p_sign_i,
    input  wire [`NLANE*`EXPW-1:0] p_exp_i,
    input  wire [`NLANE*`PSIGW-1:0] p_sig_i, // exact 48-bit products
    input  wire [`NLANE-1:0]       p_zero_i,
    input  wire [`NLANE-1:0]       p_nan_i,
    input  wire [`NLANE-1:0]       p_inf_i,
    input  wire [`NLANE-1:0]       p_valid_i,

    input  wire [1:0]              cls_i,
    input  wire [3:0]              ew_i,

    output wire [31:0]             dout_o
);
  `include "fma_funcs.v"

  // ---------------- Stage 2: alignment ----------------
  wire signed [`EXPW-1:0] ref_exp_s2;
  wire [2:0]              label_sel_s2;
  stage1_comparator u_cmp (
      .prod_exp_i(p_exp_i), .lane_valid_i(p_valid_i), .prod_zero_i(p_zero_i),
      .a_exp_i(a_exp_i), .a_zero_i(a_zero_i),
      .exp_sel_o(ref_exp_s2), .label_sel_o(label_sel_s2)
  );

  wire [`NLANE*`PSIGW-1:0] p_sig_norm;
  wire [`NLANE*`EXPW-1:0] p_exp_norm;
  stage2_relative_normalizer u_relnorm (
      .sig_i(p_sig_i), .exp_i(p_exp_i), .sig_o(p_sig_norm), .exp_o(p_exp_norm)
  );

  wire [`SHW-1:0] shift_a_s2;
  stage2_align_amount_finalizer u_finalizer (
      .ref_exp_i(ref_exp_s2), .a_exp_i(a_exp_i), .shift_o(shift_a_s2)
  );
  wire [`WW-1:0] a_aligned_s2;
  wire           a_sticky_s2;
  stage2_addend_alignment u_addend_align (
      .sig_i(a_sig_i), .shift_i(shift_a_s2), .aligned_o(a_aligned_s2), .sticky_o(a_sticky_s2)
  );

  wire [`NLANE*`SHW-1:0] shift_p_s2;
  wire [`NLANE*`WW-1:0]  p_aligned_s2;
  wire [`NLANE-1:0]      p_sticky_s2;
  genvar L;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : PALIGN
      wire [`SHW-1:0] shift_lane;
      wire [`WW-1:0]  aligned_lane;
      wire            sticky_lane;
      wire signed [`EXPW-1:0] prod_exp_lane;
      wire [`PSIGW-1:0]       prod_sig_lane;
      assign prod_exp_lane = $signed(p_exp_norm[`EXPW*L +: `EXPW]);
      assign prod_sig_lane = p_sig_norm[`PSIGW*L +: `PSIGW];

      stage2_product_align_ctrl u_pctrl (
          .ref_exp_i(ref_exp_s2), .prod_exp_i(prod_exp_lane), .shift_o(shift_lane)
      );
      stage2_mult_aligner u_paligner (
          .sig_i(prod_sig_lane), .shift_i(shift_lane),
          .aligned_o(aligned_lane), .sticky_o(sticky_lane)
      );
      assign shift_p_s2[`SHW*L +: `SHW] = shift_lane;
      assign p_aligned_s2[`WW*L +: `WW] = aligned_lane;
      assign p_sticky_s2[L] = sticky_lane;
    end
  endgenerate

  wire [`WW-1:0]        a_term_s2;
  wire [`NLANE*`WW-1:0] p_term_s2;
  wire [2:0]            neg_count_s2;
  wire                  ref_sign_s2;
  stage2_invert_swap u_invswap (
      .a_aligned_i(a_aligned_s2), .a_sign_i(a_sign_i),
      .prod_aligned_i(p_aligned_s2), .prod_sign_i(p_sign_i), .lane_valid_i(p_valid_i),
      .label_sel_i(label_sel_s2),
      .a_term_o(a_term_s2), .prod_term_o(p_term_s2), .neg_count_o(neg_count_s2),
      .ref_sign_o(ref_sign_s2)
  );

  wire [`WW-1:0] sum_s2, carry_s2;
  stage2_csa4to2 u_csa42 (
      .a_term_i(a_term_s2), .prod_term_i(p_term_s2), .neg_count_i(neg_count_s2),
      .sum_o(sum_s2), .carry_o(carry_s2)
  );

  // Special-value detection (IEEE 754):
  //   NaN  if any operand is NaN, any product is Inf*0 (flagged by the
  //        Exponent & Alignment Controller), or +Inf and -Inf meet (Inf-Inf)
  //   Inf  otherwise if any term is infinite; its sign is that term's sign
  //   -0   (zero_sign) only if every term is a zero with sign 1
  reg is_nan_s2, is_inf_s2, inf_sign_s2, zero_sign_s2;
  reg pos_inf, neg_inf;
  integer i;
  always @* begin
    is_nan_s2    = a_nan_i;
    pos_inf      = a_inf_i & !a_sign_i;
    neg_inf      = a_inf_i &  a_sign_i;
    zero_sign_s2 = a_zero_i & a_sign_i;
    for (i = 0; i < `NLANE; i = i + 1) begin
      if (p_valid_i[i]) begin
        is_nan_s2    = is_nan_s2 | p_nan_i[i];
        pos_inf      = pos_inf | (p_inf_i[i] & !p_sign_i[i]);
        neg_inf      = neg_inf | (p_inf_i[i] &  p_sign_i[i]);
        zero_sign_s2 = zero_sign_s2 & p_zero_i[i] & p_sign_i[i];
      end
    end
    is_nan_s2   = is_nan_s2 | (pos_inf & neg_inf);
    is_inf_s2   = (pos_inf | neg_inf) & !is_nan_s2;
    inf_sign_s2 = neg_inf;
  end

  // ---- pipeline register: Stage2 -> Stage3 ----
  reg [`WW-1:0] sum_r3, carry_r3;
  reg signed [`EXPW-1:0] ref_exp_r3;
  reg a_sticky_r3;
  reg [`NLANE-1:0] p_sticky_r3;
  reg is_nan_r3, is_inf_r3, inf_sign_r3, zero_sign_r3;
  reg ref_sign_r3;
  reg [1:0] cls_r3;
  reg [3:0] ew_r3;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      sum_r3 <= 0; carry_r3 <= 0; ref_exp_r3 <= 0; a_sticky_r3 <= 1'b0;
      p_sticky_r3 <= 0;
      is_nan_r3 <= 1'b0; is_inf_r3 <= 1'b0; ref_sign_r3 <= 1'b0; cls_r3 <= `CLS_8; ew_r3 <= 0;
      inf_sign_r3 <= 1'b0; zero_sign_r3 <= 1'b0;
    end else begin
      sum_r3 <= sum_s2; carry_r3 <= carry_s2; ref_exp_r3 <= ref_exp_s2;
      a_sticky_r3 <= a_sticky_s2;
      p_sticky_r3 <= p_sticky_s2;
      is_nan_r3 <= is_nan_s2; is_inf_r3 <= is_inf_s2; ref_sign_r3 <= ref_sign_s2;
      inf_sign_r3 <= inf_sign_s2; zero_sign_r3 <= zero_sign_s2;
      cls_r3 <= cls_i; ew_r3 <= ew_i;
    end
  end

  // ---------------- Stage 3: addition and complementing ----------------
  wire [`WW-1:0] sum_s3, carry_s3;
  stage3_csa3to2 u_csa32 (
      .sum_i(sum_r3), .carry_i(carry_r3), .extra_i({`WW{1'b0}}), .sum_o(sum_s3), .carry_o(carry_s3)
  );
  wire sticky_s3;
  stage3_sticky_logic u_sticky (
      .a_sticky_i(a_sticky_r3), .prod_sticky_i(p_sticky_r3), .sticky_o(sticky_s3)
  );
  wire [`WW-1:0] resolved_s3;
  stage3_csla u_csla (.sum_i(sum_s3), .carry_i(carry_s3), .resolved_o(resolved_s3));

  wire sign_s3;
  wire [`WW-1:0] magnitude_s3;
  stage3_complement u_complement (
      .resolved_i(resolved_s3), .sign_o(sign_s3), .magnitude_o(magnitude_s3)
  );

  wire signed [`EXPW-1:0] exp_adjust_s3;
  wire is_zero_s3;
  stage3_lzau u_lzau (
      .magnitude_i(magnitude_s3), .exp_adjust_o(exp_adjust_s3), .is_zero_o(is_zero_s3)
  );

  // ---- pipeline register: Stage3 -> Stage4 ----
  reg [`WW-1:0] magnitude_r4;
  reg signed [`EXPW-1:0] exp_adjust_r4, ref_exp_r4;
  reg sign_r4, is_zero_r4, sticky_r4, is_nan_r4, is_inf_r4, inf_sign_r4, zero_sign_r4;
  reg ref_sign_r4;
  reg [1:0] cls_r4;
  reg [3:0] ew_r4;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      magnitude_r4 <= 0; exp_adjust_r4 <= 0; ref_exp_r4 <= 0;
      sign_r4 <= 1'b0; is_zero_r4 <= 1'b0; sticky_r4 <= 1'b0;
      is_nan_r4 <= 1'b0; is_inf_r4 <= 1'b0; ref_sign_r4 <= 1'b0; cls_r4 <= `CLS_8; ew_r4 <= 0;
      inf_sign_r4 <= 1'b0; zero_sign_r4 <= 1'b0;
    end else begin
      magnitude_r4 <= magnitude_s3; exp_adjust_r4 <= exp_adjust_s3; ref_exp_r4 <= ref_exp_r3;
      sign_r4 <= sign_s3; is_zero_r4 <= is_zero_s3; sticky_r4 <= sticky_s3;
      is_nan_r4 <= is_nan_r3; is_inf_r4 <= is_inf_r3; ref_sign_r4 <= ref_sign_r3;
      inf_sign_r4 <= inf_sign_r3; zero_sign_r4 <= zero_sign_r3;
      cls_r4 <= cls_r3; ew_r4 <= ew_r3;
    end
  end

  // ---------------- Stage 4: normalize/round/pack ----------------
  wire [`WW-1:0] normalized_s4;
  wire extra_sticky_s4;
  wire signed [`EXPW-1:0] norm_adjust_s4; // LZAU shift, limited at emin for subnormals
  stage4_normalization u_norm (
      .magnitude_i(magnitude_r4), .exp_adjust_i(exp_adjust_r4),
      .ref_exp_i(ref_exp_r4), .ew_i(ew_r4),
      .normalized_o(normalized_s4), .extra_sticky_o(extra_sticky_s4),
      .exp_adjust_o(norm_adjust_s4)
  );

  wire [`SIGW-1:0] rounded_sig_s4;
  wire rnd_ovf_s4;
  wire [31:0] m_s4;
  assign m_s4 = mant_width(cls_r4, ew_r4);
  stage4_rounding u_round (
      .normalized_i(normalized_s4), .sticky_upstream_i(sticky_r4), .sticky_norm_i(extra_sticky_s4),
      .m_i(m_s4), .rounded_sig_o(rounded_sig_s4), .rnd_ovf_o(rnd_ovf_s4)
  );

  wire signed [`EXPW-1:0] final_exp_s4;
  stage4_exp_adjuster u_expadj (
      .ref_exp_i(ref_exp_r4), .exp_adjust_i(norm_adjust_s4), .rnd_ovf_i(rnd_ovf_s4),
      .final_exp_o(final_exp_s4)
  );

  wire final_sign_s4;
  stage4_sign_detection u_signdet (
      .sign_incr_i(sign_r4), .ref_sign_i(ref_sign_r4),
      .is_zero_i(is_zero_r4), .zero_sign_i(zero_sign_r4),
      .is_nan_i(is_nan_r4), .is_inf_i(is_inf_r4), .inf_sign_i(inf_sign_r4),
      .sign_o(final_sign_s4)
  );

  stage4_output_finalize u_finalize (
      .sign_i(final_sign_s4), .exp_i(final_exp_s4), .sig_i(rounded_sig_s4),
      .is_zero_i(is_zero_r4), .is_nan_i(is_nan_r4), .is_inf_i(is_inf_r4),
      .cls_i(cls_r4), .ew_i(ew_r4), .packed_o(dout_o)
  );

endmodule
