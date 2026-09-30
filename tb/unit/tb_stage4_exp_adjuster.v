// tb_stage4_exp_adjuster.v -- unit test for stage4_exp_adjuster (9.3).
// final_exp = ref_exp + exp_adjust (from LZAU) + 1 if rounding overflowed.
`include "fma_defs.vh"

module tb_stage4_exp_adjuster;
  parameter TB_NAME = "stage4_exp_adjuster";
  `include "tb_util.vh"

  reg  signed [`EXPW-1:0] ref_e, adj;
  reg                     rov;
  wire signed [`EXPW-1:0] fe;
  stage4_exp_adjuster dut (.ref_exp_i(ref_e), .exp_adjust_i(adj), .rnd_ovf_i(rov), .final_exp_o(fe));

  reg signed [`EXPW-1:0] e_fe;
  reg ok;
  integer i, f0;

  task directed;
    input signed [`EXPW-1:0] tr, ta;
    input to;
    input [8*44-1:0] note;
    begin
      ref_e = tr; adj = ta; rov = to; #10;
      e_fe = tr + ta + to;
      ok = (fe === e_fe);
      tally(ok);
      $display("   %5d %5d  %b | %5d | %5d | %s  %0s", ref_e, adj, rov, fe, e_fe, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_exp_adjuster  (MPFMA-DS-001 9.3 Exponent Adjuster)",
           "final_exp = ref_exp + exp_adjust + (rnd_ovf ? 1 : 0)");

    section("directed tests");
    $display("   ref   adj  ovf | got   | exp   | result");
    directed(  0,  0, 0, "1.0 + 0 -> exponent unchanged");
    directed(  0,  1, 0, "1.0 + 1.0 = 2.0 -> +1");
    directed(  5, -6, 0, "cancellation: 5 - 6");
    directed( 15,  0, 1, "rounding carried out -> +1");
    directed(-126, -10, 0, "into subnormal range");
    directed(127,  3, 1, "overflow direction");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 1000; i = i + 1) begin
      ref_e = $random(seed) % 300;
      adj   = $random(seed) % 40;
      rov   = $random(seed);
      #10;
      e_fe = ref_e + adj + rov;
      ok = (fe === e_fe);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL ref=%0d adj=%0d ovf=%b got=%0d exp=%0d", ref_e, adj, rov, fe, e_fe);
    end
    random_done(1000, f0);

    summary;
  end
endmodule
