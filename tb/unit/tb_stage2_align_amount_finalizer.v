// tb_stage2_align_amount_finalizer.v -- unit test for stage2_align_amount_finalizer (7.1).
// shift = ref_exp - a_exp, clamped to 0 when negative and saturated at 63.
`include "fma_defs.vh"

module tb_stage2_align_amount_finalizer;
  parameter TB_NAME = "stage2_align_amount_finalizer";
  `include "tb_util.vh"

  reg  signed [`EXPW-1:0] ref_e, a_e;
  wire [`SHW-1:0]         sh;
  stage2_align_amount_finalizer dut (.ref_exp_i(ref_e), .a_exp_i(a_e), .shift_o(sh));

  integer d, exp_sh, i, f0;
  reg ok;

  task ref_model;
    begin
      d = ref_e - a_e;
      exp_sh = (d < 0) ? 0 : (d > 63) ? 63 : d;
    end
  endtask

  task directed;
    input signed [`EXPW-1:0] r, a;
    input [8*36-1:0] note;
    begin
      ref_e = r; a_e = a; #10;
      ref_model;
      ok = (sh === exp_sh);
      tally(ok);
      $display("   %5d  %5d | %5d | %2d  | %2d  | %s  %0s", ref_e, a_e, d, sh, exp_sh, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage2_align_amount_finalizer  (MPFMA-DS-001 7.1 Align Amount Finalizer)",
           "addend shift = ref_exp - a_exp ; clamp < 0 to 0 ; saturate > 63 to 63");

    section("directed tests");
    $display("   ref_e  a_exp | diff  | got | exp | result");
    directed(  5,    5, "addend is the reference: no shift");
    directed( 10,    3, "addend 7 binades smaller");
    directed(  3,   10, "addend larger -> clamp to 0");
    directed(100, -100, "huge gap -> saturate to 63");
    directed(-10,  -30, "negative exponents");
    directed( 63,    0, "exactly 63");
    directed( 64,    0, "64 -> saturate");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 1000; i = i + 1) begin
      ref_e = $random(seed) % 300;
      a_e   = $random(seed) % 300;
      #10;
      ref_model;
      ok = (sh === exp_sh);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL ref=%0d a=%0d got=%0d exp=%0d", ref_e, a_e, sh, exp_sh);
    end
    random_done(1000, f0);

    summary;
  end
endmodule
