// tb_stage1_exp_align_controller.v -- unit test for stage1_exp_align_controller (6.5).
// Per lane: resolves the Booth carry-save pair (sum+carry = sig_b*sig_c),
// normalizes the full 48-bit product (leading 1 moved to bit 47, nothing
// dropped -- the product is carried exactly), and computes product
// exponent/sign and the zero/NaN/Inf flags.
//   exp  = exp_b + exp_c + (product >= 2.0 ? 1 : 0)
//   sig  = the exact 48-bit product, shifted left 1 if it was < 2.0
//   NaN if an input is NaN or Inf x 0 ; Inf if an input is Inf (and not NaN)
`include "fma_defs.vh"

module tb_stage1_exp_align_controller;
  parameter TB_NAME = "stage1_exp_align_controller";
  `include "tb_util.vh"

  reg  [`NLANE-1:0]       bs, cs, bz, cz, bn, cn, bi, ci;
  reg  [`NLANE*`EXPW-1:0] be, ce;
  reg  [`NLANE*48-1:0]    sm, cy;
  wire [`NLANE*`EXPW-1:0] pexp;
  wire [`NLANE*`PSIGW-1:0] psig;
  wire [`NLANE-1:0]       psign, pzero, pnan, pinf;

  stage1_exp_align_controller dut (
      .b_sign_i(bs), .c_sign_i(cs), .b_exp_i(be), .c_exp_i(ce),
      .b_zero_i(bz), .c_zero_i(cz), .b_nan_i(bn), .c_nan_i(cn),
      .b_inf_i(bi), .c_inf_i(ci), .sum_i(sm), .carry_i(cy),
      .prod_exp_o(pexp), .prod_sig_o(psig), .prod_sign_o(psign),
      .prod_zero_o(pzero), .prod_nan_o(pnan), .prod_inf_o(pinf)
  );

  // operands per lane (kept so the reference model can use the true product)
  reg [`SIGW-1:0] sb [0:3];
  reg [`SIGW-1:0] sc [0:3];

  reg  [47:0] prod, split;
  reg  signed [`EXPW-1:0] r_exp;
  reg  [`PSIGW-1:0] r_sig;
  reg  r_sign, r_zero, r_nan, r_inf, ok, lane_ok;
  integer i, L, f0;

  // load lane L's operands; the product is split into a random carry-save
  // pair (sum, carry) exactly like the Booth multiplier would hand it over
  task set_lane;
    input integer l;
    input [`SIGW-1:0] b_sig, c_sig;
    input signed [`EXPW-1:0] b_exp, c_exp;
    input b_sgn, c_sgn;
    input [2:0] b_flags, c_flags; // {inf, nan, zero}
    begin
      sb[l] = b_sig; sc[l] = c_sig;
      prod  = b_sig * c_sig;
      split = {$random(seed), $random(seed)};
      sm[48*l +: 48] = split;
      cy[48*l +: 48] = prod - split;
      be[`EXPW*l +: `EXPW] = b_exp; ce[`EXPW*l +: `EXPW] = c_exp;
      bs[l] = b_sgn; cs[l] = c_sgn;
      {bi[l], bn[l], bz[l]} = b_flags;
      {ci[l], cn[l], cz[l]} = c_flags;
    end
  endtask

  task ref_lane;
    input integer l;
    begin
      prod   = sb[l] * sc[l];
      r_sign = bs[l] ^ cs[l];
      r_zero = bz[l] | cz[l];
      r_nan  = bn[l] | cn[l] | (bi[l] & cz[l]) | (ci[l] & bz[l]);
      r_inf  = (bi[l] | ci[l]) & !r_nan;
      r_exp  = $signed(be[`EXPW*l +: `EXPW]) + $signed(ce[`EXPW*l +: `EXPW]) + (prod[47] ? 1 : 0);
      if (r_zero)        r_sig = 0;
      else if (prod[47]) r_sig = prod;
      else               r_sig = {prod[46:0], 1'b0};
    end
  endtask

  task check_lane;
    input integer l;
    begin
      ref_lane(l);
      lane_ok = ($signed(pexp[`EXPW*l +: `EXPW]) === r_exp) &&
                (psig[`PSIGW*l +: `PSIGW] === r_sig) && (psign[l] === r_sign) &&
                (pzero[l] === r_zero) && (pnan[l] === r_nan) && (pinf[l] === r_inf);
    end
  endtask

  task directed;
    input [8*40-1:0] note;
    begin
      #10;
      check_lane(0);
      ok = lane_ok;
      tally(ok);
      $display("   %h x %h  %4d %4d | %4d %h %b %b%b%b | %4d %h %b %b%b%b | %s  %0s",
               sb[0], sc[0], $signed(be[11:0]), $signed(ce[11:0]),
               $signed(pexp[11:0]), psig[47:0], psign[0], pzero[0], pnan[0], pinf[0],
               r_exp, r_sig, r_sign, r_zero, r_nan, r_inf, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage1_exp_align_controller  (MPFMA-DS-001 6.5 Exponent & Alignment Controller)",
           "product exp = eb+ec(+1 if product>=2), exact 48-bit normalized product, sign, zero/NaN/Inf");

    // lanes 1..3 get harmless values during the directed section
    for (L = 1; L < 4; L = L + 1) set_lane(L, 24'h800000, 24'h800000, 0, 0, 0, 0, 3'b000, 3'b000);

    section("directed tests (lane 0 shown; flags printed as zero,nan,inf)");
    $display("   sig_b    sig_c   eb   ec  | exp  sig(48b)     s z n i | exp  sig(48b)     s z n i | result");
    set_lane(0, 24'h800000, 24'h800000,  0,  0, 0, 0, 3'b000, 3'b000); directed("1.0 x 1.0 = 1.0");
    set_lane(0, 24'hC00000, 24'hC00000,  0,  0, 0, 0, 3'b000, 3'b000); directed("1.5 x 1.5 = 2.25 -> exp+1");
    set_lane(0, 24'h800000, 24'h800000,  3, -5, 0, 1, 3'b000, 3'b000); directed("8 x -(1/32) = -0.25");
    set_lane(0, 24'hFFFFFF, 24'hFFFFFF,  0,  0, 0, 0, 3'b000, 3'b000); directed("max x max: all 48 bits kept");
    set_lane(0, 24'h000000, 24'hC00000,  0,  2, 1, 0, 3'b001, 3'b000); directed("0 x 6 = 0 (zero flag)");
    set_lane(0, 24'h000000, 24'h000000,  0,  0, 0, 0, 3'b100, 3'b001); directed("Inf x 0 = NaN");
    set_lane(0, 24'h000000, 24'h800000,  0,  1, 0, 1, 3'b100, 3'b000); directed("Inf x -2 = -Inf");
    set_lane(0, 24'h000000, 24'h800000,  0,  1, 0, 0, 3'b010, 3'b000); directed("NaN x 2 = NaN");

    section("random tests (all 4 lanes checked every vector)");
    f0 = n_fail;
    for (i = 0; i < 1500; i = i + 1) begin
      for (L = 0; L < 4; L = L + 1)
        set_lane(L, 24'h800000 | $random(seed), 24'h800000 | $random(seed),
                 $random(seed) % 140, $random(seed) % 140, $random(seed), $random(seed),
                 (($random(seed) % 8) == 0) ? 3'b001 : 3'b000,
                 (($random(seed) % 8) == 0) ? 3'b001 : 3'b000);
      #10;
      ok = 1'b1;
      for (L = 0; L < 4; L = L + 1) begin
        check_lane(L);
        if (!lane_ok) ok = 1'b0;
        if (!lane_ok && n_fail - f0 < 10)
          $display("   FAIL lane %0d: b=%h c=%h got exp=%0d sig=%h exp exp=%0d sig=%h",
                   L, sb[L], sc[L], $signed(pexp[`EXPW*L +: `EXPW]), psig[`PSIGW*L +: `PSIGW],
                   r_exp, r_sig);
      end
      tally(ok);
    end
    random_done(1500, f0);

    summary;
  end
endmodule
