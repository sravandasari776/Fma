// tb_stage3_csa3to2.v -- unit test for stage3_csa3to2 (8.1).
// 40-bit 3:2 compressor in front of the CSLA:
//   sum_o + carry_o == sum_i + carry_i + extra_i   (mod 2^40)
// (in the pipeline extra_i is tied to 0; both cases are tested here)
`include "fma_defs.vh"

module tb_stage3_csa3to2;
  parameter TB_NAME = "stage3_csa3to2";
  `include "tb_util.vh"

  reg  [`WW-1:0] si, ci, xi;
  wire [`WW-1:0] so, co;
  stage3_csa3to2 dut (.sum_i(si), .carry_i(ci), .extra_i(xi), .sum_o(so), .carry_o(co));

  reg [`WW-1:0] e_tot, g_tot;
  reg ok;
  integer i, f0;

  task check;
    begin
      #10;
      e_tot = si + ci + xi;
      g_tot = so + co;
      ok = (g_tot === e_tot) && (so === (si ^ ci ^ xi));
      tally(ok);
    end
  endtask

  task directed;
    input [`WW-1:0] ts, tc, tx;
    input [8*40-1:0] note;
    begin
      si = ts; ci = tc; xi = tx;
      check;
      $display("   %h %h %h | %h %h | %h | %h | %s  %0s", si, ci, xi, so, co, g_tot, e_tot, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage3_csa3to2  (MPFMA-DS-001 8.1 3-to-2 CSA)",
           "sum_o + carry_o == sum_i + carry_i + extra_i (mod 2^40); extra_i = 0 in the pipeline");

    section("directed tests");
    $display("   sum_i      carry_i    extra_i    | sum_o      carry_o    | so+co      | expected   | result");
    directed(40'h10_0000_0000, 40'h10_0000_0000, 0, "1.0 + 1.0 (extra = 0)");
    directed(40'h0F_FFFF_FFFF, 40'h00_0000_0001, 0, "long carry chain");
    directed(40'h12_3456_789A, 40'h01_1111_1111, 40'h00_0F0F_0F0F, "non-zero extra input");
    directed(~40'h0, 40'h1, 0, "-1 + 1 = 0");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      si = {$random(seed), $random(seed)};
      ci = {$random(seed), $random(seed)};
      xi = (i % 2) ? 0 : {$random(seed), $random(seed)};
      check;
      if (!ok && n_fail - f0 <= 10) $display("   FAIL s=%h c=%h x=%h got=%h exp=%h", si, ci, xi, g_tot, e_tot);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
