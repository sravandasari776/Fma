// fma_top.v
// U_FMA top level per MPFMA-DS-001 §2-5. Implements the configurable
// mixed/multiple-precision Floating-Point Fused Multiply-Add pipeline of
// Fig. 3 (Niknia et al., IEEE TCASAI vol.2 no.3 2025): four stages, three
// pipeline registers (the first here; the remaining two live inside each
// fma_lane_pipe instance -- see that file for the Stage2/3/4 boundary
// registers).
//
// Packing convention (an RTL-owner decision the source spec explicitly
// delegates, §10.2/10.3 of MPFMA-DS-001; documented in docs/README.md):
//   pra_i/prm_i select a format CLASS (8-/16-/32-/19-bit); ewa_i/ewm_i
//   (4..8) select the exponent width, which combined with the class
//   determines the exact format (E4M3/E5M2/HP/DLFloat16/BFloat16/SP/TF32).
//   a_i/b_i/c_i pack NLANE independent same-class values into the low 32
//   bits (byte lanes for the 8-bit class, halfword lanes for 16-bit, the
//   whole 32 bits for the 32-bit class, the low 19 bits for TF32).
//   Multiple-precision mode (mixmode_i=0): pra_i==prm_i, each lane is an
//   independent A+B*C; dout_o packs the lane_count(prm_i) independent
//   results into its low 32 bits with the same convention.
//   Mixed-precision mode (mixmode_i=1): a_i/c_i's slot 0 carries the
//   single higher-precision addend (class/width from pra_i/ewa_i);
//   b_i/c_i carry lane_count(prm_i) lower-precision dot-product operands;
//   dout_o's low 32 bits carry the single accumulated result in the
//   addend's format.
//
// Every per-lane internal bus is a packed vector (lane i of a W-bit field
// at bits [W*i +: W]), never an unpacked array crossing a module port --
// see stage1_unified_extractor.v's header comment for why.
`include "fma_defs.vh"

module fma_top (
    input  wire          clk_i,
    input  wire          rst_n_i,

    input  wire [63:0]   a_i, b_i, c_i,
    input  wire          mixmode_i,
    input  wire [1:0]    pra_i, prm_i,
    input  wire [3:0]    ewa_i, ewm_i,

    output wire [127:0]  dout_o
);
  `include "fma_funcs.v"

  // ---------------- Stage 1 ----------------
  wire [`NLANE-1:0]      a_sign_flat, b_sign_flat, c_sign_flat;
  wire [`NLANE*`EXPW-1:0] a_exp_flat,  b_exp_flat,  c_exp_flat;
  wire [`NLANE*`SIGW-1:0] a_sig_flat,  b_sig_flat,  c_sig_flat;
  wire [`NLANE-1:0]      a_zero_flat, b_zero_flat, c_zero_flat;
  wire [`NLANE-1:0]      a_nan_flat,  b_nan_flat,  c_nan_flat;
  wire [`NLANE-1:0]      a_inf_flat,  b_inf_flat,  c_inf_flat;

  stage1_unified_extractor u_extract (
      .a_i(a_i), .b_i(b_i), .c_i(c_i),
      .pra_i(pra_i), .prm_i(prm_i), .ewa_i(ewa_i), .ewm_i(ewm_i),
      .a_sign_o(a_sign_flat), .b_sign_o(b_sign_flat), .c_sign_o(c_sign_flat),
      .a_exp_o(a_exp_flat),   .b_exp_o(b_exp_flat),   .c_exp_o(c_exp_flat),
      .a_sig_o(a_sig_flat),   .b_sig_o(b_sig_flat),   .c_sig_o(c_sig_flat),
      .a_zero_o(a_zero_flat), .b_zero_o(b_zero_flat), .c_zero_o(c_zero_flat),
      .a_nan_o(a_nan_flat),   .b_nan_o(b_nan_flat),   .c_nan_o(c_nan_flat),
      .a_inf_o(a_inf_flat),   .b_inf_o(b_inf_flat),   .c_inf_o(c_inf_flat)
  );

  wire [`NLANE*48-1:0] mult_sum, mult_carry;
  genvar G;
  generate
    for (G = 0; G < `NLANE; G = G + 1) begin : MUL
      wire [47:0] sum_lane, carry_lane;
      stage1_booth_multiplier u_mult (
          .sig_b_i(b_sig_flat[`SIGW*G +: `SIGW]), .sig_c_i(c_sig_flat[`SIGW*G +: `SIGW]),
          .sum_o(sum_lane), .carry_o(carry_lane)
      );
      assign mult_sum[48*G +: 48]   = sum_lane;
      assign mult_carry[48*G +: 48] = carry_lane;
    end
  endgenerate

  wire [`NLANE*`EXPW-1:0] prod_exp;
  wire [`NLANE*`SIGW-1:0] prod_sig;
  wire [`NLANE-1:0]      prod_sign, prod_zero, prod_nan, prod_inf, prod_sticky;
  stage1_exp_align_controller u_expalign (
      .b_sign_i(b_sign_flat), .c_sign_i(c_sign_flat),
      .b_exp_i(b_exp_flat),   .c_exp_i(c_exp_flat),
      .b_zero_i(b_zero_flat), .c_zero_i(c_zero_flat),
      .b_nan_i(b_nan_flat),   .c_nan_i(c_nan_flat),
      .b_inf_i(b_inf_flat),   .c_inf_i(c_inf_flat),
      .sum_i(mult_sum), .carry_i(mult_carry),
      .prod_exp_o(prod_exp), .prod_sig_o(prod_sig), .prod_sign_o(prod_sign),
      .prod_zero_o(prod_zero), .prod_nan_o(prod_nan), .prod_inf_o(prod_inf),
      .prod_sticky_o(prod_sticky)
  );

  reg [`NLANE-1:0] lane_valid_comb;
  integer lc;
  integer i_lv;
  always @* begin
    lc = lane_count(prm_i);
    for (i_lv = 0; i_lv < `NLANE; i_lv = i_lv + 1) lane_valid_comb[i_lv] = (i_lv < lc);
  end

  // ---- pipeline register: Stage1 -> Stage2 ----
  reg [`NLANE-1:0]      a_sign_r2;
  reg [`NLANE*`EXPW-1:0] a_exp_r2;
  reg [`NLANE*`SIGW-1:0] a_sig_r2;
  reg [`NLANE-1:0]      a_zero_r2, a_nan_r2, a_inf_r2;
  reg [`NLANE*`EXPW-1:0] prod_exp_r2;
  reg [`NLANE*`SIGW-1:0] prod_sig_r2;
  reg [`NLANE-1:0] prod_sign_r2, prod_zero_r2, prod_nan_r2, prod_inf_r2, prod_sticky_r2;
  reg [`NLANE-1:0] lane_valid_r2;
  reg mixmode_r2;
  reg [1:0] pra_r2, prm_r2;
  reg [3:0] ewa_r2, ewm_r2;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      a_sign_r2 <= 0; a_exp_r2 <= 0; a_sig_r2 <= 0;
      a_zero_r2 <= 0; a_nan_r2 <= 0; a_inf_r2 <= 0;
      prod_exp_r2 <= 0; prod_sig_r2 <= 0;
      prod_sign_r2 <= 0; prod_zero_r2 <= 0; prod_nan_r2 <= 0; prod_inf_r2 <= 0;
      prod_sticky_r2 <= 0;
      lane_valid_r2 <= 0;
      mixmode_r2 <= 1'b0; pra_r2 <= `CLS_8; prm_r2 <= `CLS_8; ewa_r2 <= 0; ewm_r2 <= 0;
    end else begin
      a_sign_r2 <= a_sign_flat; a_exp_r2 <= a_exp_flat; a_sig_r2 <= a_sig_flat;
      a_zero_r2 <= a_zero_flat; a_nan_r2 <= a_nan_flat; a_inf_r2 <= a_inf_flat;
      prod_exp_r2 <= prod_exp; prod_sig_r2 <= prod_sig;
      prod_sign_r2 <= prod_sign; prod_zero_r2 <= prod_zero;
      prod_nan_r2 <= prod_nan; prod_inf_r2 <= prod_inf;
      prod_sticky_r2 <= prod_sticky;
      lane_valid_r2 <= lane_valid_comb;
      mixmode_r2 <= mixmode_i; pra_r2 <= pra_i; prm_r2 <= prm_i; ewa_r2 <= ewa_i; ewm_r2 <= ewm_i;
    end
  end

  // ---------------- per-lane Stage2-4 pipes ----------------
  // Input selection is computed per generate-instance from the packed
  // Stage-1 registers above; each fma_lane_pipe copy gets its own packed
  // per-lane product bus built locally (no shared 2-D array).
  wire [31:0] lp_dout [0:`NLANE-1];

  generate
    for (G = 0; G < `NLANE; G = G + 1) begin : LANEPIPE
      reg                     g_a_sign;
      reg  signed [`EXPW-1:0] g_a_exp;
      reg  [`SIGW-1:0]        g_a_sig;
      reg                     g_a_zero, g_a_nan, g_a_inf;
      reg  [`NLANE-1:0]       g_p_sign;
      reg  [`NLANE*`EXPW-1:0] g_p_exp;
      reg  [`NLANE*`SIGW-1:0] g_p_sig;
      reg  [`NLANE-1:0]       g_p_zero, g_p_nan, g_p_inf, g_p_mulsticky;
      reg  [`NLANE-1:0]       g_p_valid;
      reg  [1:0]              g_cls;
      reg  [3:0]              g_ew;

      always @* begin
        if (mixmode_r2) begin
          // every copy gets the same shared-addend + all-products view;
          // only copy 0's result is actually used (see final output mux).
          g_a_sign = a_sign_r2[0];
          g_a_exp  = $signed(a_exp_r2[`EXPW*0 +: `EXPW]);
          g_a_sig  = a_sig_r2[`SIGW*0 +: `SIGW];
          g_a_zero = a_zero_r2[0]; g_a_nan = a_nan_r2[0]; g_a_inf = a_inf_r2[0];
          g_p_sign = prod_sign_r2; g_p_exp = prod_exp_r2; g_p_sig = prod_sig_r2;
          g_p_zero = prod_zero_r2; g_p_nan = prod_nan_r2; g_p_inf = prod_inf_r2;
          g_p_mulsticky = prod_sticky_r2;
          g_p_valid = lane_valid_r2;
          g_cls = pra_r2; g_ew = ewa_r2;
        end else begin
          // this copy is its own independent A + B*C
          g_a_sign = a_sign_r2[G];
          g_a_exp  = $signed(a_exp_r2[`EXPW*G +: `EXPW]);
          g_a_sig  = a_sig_r2[`SIGW*G +: `SIGW];
          g_a_zero = a_zero_r2[G]; g_a_nan = a_nan_r2[G]; g_a_inf = a_inf_r2[G];
          g_p_sign = 0; g_p_exp = 0; g_p_sig = 0;
          g_p_zero = {`NLANE{1'b1}}; g_p_nan = 0; g_p_inf = 0; g_p_mulsticky = 0;
          g_p_valid = 0;
          g_p_sign[0] = prod_sign_r2[G];
          g_p_exp[`EXPW*0 +: `EXPW] = prod_exp_r2[`EXPW*G +: `EXPW];
          g_p_sig[`SIGW*0 +: `SIGW] = prod_sig_r2[`SIGW*G +: `SIGW];
          g_p_zero[0] = prod_zero_r2[G];
          g_p_nan[0]  = prod_nan_r2[G];
          g_p_inf[0]  = prod_inf_r2[G];
          g_p_mulsticky[0] = prod_sticky_r2[G];
          g_p_valid[0] = lane_valid_r2[G];
          g_cls = prm_r2; g_ew = ewm_r2;
        end
      end

      fma_lane_pipe u_pipe (
          .clk_i(clk_i), .rst_n_i(rst_n_i),
          .a_sign_i(g_a_sign), .a_exp_i(g_a_exp), .a_sig_i(g_a_sig),
          .a_zero_i(g_a_zero), .a_nan_i(g_a_nan), .a_inf_i(g_a_inf),
          .p_sign_i(g_p_sign), .p_exp_i(g_p_exp), .p_sig_i(g_p_sig),
          .p_zero_i(g_p_zero), .p_nan_i(g_p_nan), .p_inf_i(g_p_inf),
          .p_mulsticky_i(g_p_mulsticky),
          .p_valid_i(g_p_valid),
          .cls_i(g_cls), .ew_i(g_ew),
          .dout_o(lp_dout[G])
      );
    end
  endgenerate

  // ---------------- output-select shadow delay ----------------
  // lp_dout reflects an operation issued two more cycles ago than
  // mixmode_r2/prm_r2 (fma_lane_pipe's own two internal registers), so the
  // mode/class used to interpret lp_dout must be delayed by the same two
  // cycles -- these registers carry no datapath value, only the
  // control/format tag needed to decode lp_dout correctly.
  reg mixmode_r3, mixmode_r4;
  reg [1:0] prm_r3, prm_r4;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      mixmode_r3 <= 1'b0; mixmode_r4 <= 1'b0; prm_r3 <= `CLS_8; prm_r4 <= `CLS_8;
    end else begin
      mixmode_r3 <= mixmode_r2; mixmode_r4 <= mixmode_r3;
      prm_r3 <= prm_r2; prm_r4 <= prm_r3;
    end
  end

  // ---------------- output assembly ----------------
  // inverse of lane_slice(): reassemble independent per-lane results back
  // into one 32-bit field per prm_r4's packing convention.
  reg [31:0] packed32;
  integer i_pk;
  always @* begin
    if (mixmode_r4) begin
      packed32 = lp_dout[0];
    end else begin
      packed32 = 0;
      case (prm_r4)
        `CLS_8:  for (i_pk = 0; i_pk < 4; i_pk = i_pk + 1) packed32[8*i_pk +: 8]   = lp_dout[i_pk][7:0];
        `CLS_16: for (i_pk = 0; i_pk < 2; i_pk = i_pk + 1) packed32[16*i_pk +: 16] = lp_dout[i_pk][15:0];
        `CLS_32: packed32 = lp_dout[0];
        `CLS_19: packed32[18:0] = lp_dout[0][18:0];
        default: packed32 = lp_dout[0];
      endcase
    end
  end
  assign dout_o = {96'b0, packed32};

endmodule
