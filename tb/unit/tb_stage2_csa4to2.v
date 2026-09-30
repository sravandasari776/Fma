// tb_stage2_csa4to2.v -- unit test for stage2_csa4to2 (7.7).
// Compresses addend + 4 product terms + the negation correction (neg_count)
// into a sum/carry pair. Property checked:
//   sum_o + carry_o == a + p0 + p1 + p2 + p3 + neg_count   (mod 2^76)
// The directed cases are real FMA situations in the 76-bit frame
// (1.0 = bit MSBPOS = 71).
`include "fma_defs.vh"

module tb_stage2_csa4to2;
  parameter TB_NAME = "stage2_csa4to2";
  `include "tb_util.vh"

  reg  [`WW-1:0]        a_t;
  reg  [`NLANE*`WW-1:0] p_t;
  reg  [2:0]            negc;
  wire [`WW-1:0]        s, cy;
  stage2_csa4to2 dut (.a_term_i(a_t), .prod_term_i(p_t), .neg_count_i(negc), .sum_o(s), .carry_o(cy));

  localparam [`WW-1:0] ONE  = {{(`WW-1){1'b0}}, 1'b1} << `MSBPOS;      // 1.0
  localparam [`WW-1:0] HALF = {{(`WW-1){1'b0}}, 1'b1} << (`MSBPOS-1);  // 0.5
  localparam [`WW-1:0] MAXT = (ONE << 1) - 1;                           // 1.999...
  localparam [`WW-1:0] ALL1 = {`WW{1'b1}};

  reg [`WW-1:0] e_tot, g_tot;
  reg ok;
  integer i, f0;

  task check;
    begin
      #10;
      e_tot = a_t + p_t[0*`WW +: `WW] + p_t[1*`WW +: `WW] + p_t[2*`WW +: `WW] + p_t[3*`WW +: `WW] + negc;
      g_tot = s + cy;
      ok = (g_tot === e_tot);
      tally(ok);
    end
  endtask

  task directed;
    input [`WW-1:0] ta, t0, t1, t2, t3;
    input [2:0] tn;
    input [8*40-1:0] note;
    begin
      a_t = ta; p_t = {t3, t2, t1, t0}; negc = tn;
      check;
      $display("   %h %h %h %h %h %0d | %h | %h | %s  %0s", ta, t0, t1, t2, t3, tn, g_tot, e_tot, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage2_csa4to2  (MPFMA-DS-001 7.7 CSA 4:2)",
           "sum + carry == a_term + p0 + p1 + p2 + p3 + neg_count  (mod 2^76)");

    section("directed tests");
    $display("   (5 terms, 76-bit hex each) a_term p0 p1 p2 p3 n | sum+carry | expected | result");
    directed(ONE, ONE, 0, 0, 0, 0, "1.0 + 1.0 = 2.0");
    directed(ONE, ~HALF, 0, 0, 0, 1, "1.0 - 0.5 = 0.5 (inverted + 1)");
    directed(ONE, ONE, ONE, ONE, ONE, 0, "1 + 1+1+1+1 = 5.0 (mixed-precision dot)");
    directed(MAXT, MAXT, MAXT, MAXT, MAXT, 0, "5 x 1.999: worst case, sign bit stays 0");
    directed(0, ONE, ~ONE, 0, 0, 1, "1.0 - 1.0 = 0 (cancellation)");
    directed(ALL1, ALL1, ALL1, ALL1, ALL1, 5, "5 x (-1) + 5 wraps to 0");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      a_t  = {$random(seed), $random(seed), $random(seed)};
      p_t  = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed),
              $random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
      negc = $unsigned($random(seed)) % 6;
      check;
      if (!ok && n_fail - f0 <= 10) $display("   FAIL got=%h exp=%h", g_tot, e_tot);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
