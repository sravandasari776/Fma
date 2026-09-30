// tb_stage2_relative_normalizer.v -- unit test for stage2_relative_normalizer (7.4).
// In this implementation the block is a structural pass-through (products
// are already normalized in Stage 1, see docs/DEVIATIONS.md), so the test
// checks, on the 4 x 48-bit exact product lanes,
// that every lane's significand and exponent come out unchanged.
`include "fma_defs.vh"

module tb_stage2_relative_normalizer;
  parameter TB_NAME = "stage2_relative_normalizer";
  `include "tb_util.vh"

  reg  [`NLANE*`PSIGW-1:0] sig_in;
  reg  [`NLANE*`EXPW-1:0] exp_in;
  wire [`NLANE*`PSIGW-1:0] sig_out;
  wire [`NLANE*`EXPW-1:0] exp_out;
  stage2_relative_normalizer dut (.sig_i(sig_in), .exp_i(exp_in), .sig_o(sig_out), .exp_o(exp_out));

  reg ok;
  integer i, f0;

  initial begin
    banner("stage2_relative_normalizer  (MPFMA-DS-001 7.4 Unified Relative Normalizer)",
           "pass-through in this design: sig_o == sig_i and exp_o == exp_i for all 4 lanes");

    section("directed tests");
    $display("   sig_i (4 lanes)           exp_i (4 lanes) | sig_o                     exp_o        | result");
    sig_in = {48'h800000000000, 48'hC00000000001, 48'hA00000000000, 48'hFFFFFFFFFFFF};
    exp_in = {12'sd0, 12'sd1, -12'sd5, 12'sd127};
    #10; ok = (sig_out === sig_in) && (exp_out === exp_in); tally(ok);
    $display("   %h  %h    | %h  %h | %s", sig_in, exp_in, sig_out, exp_out, pf(ok));
    sig_in = 0; exp_in = 0;
    #10; ok = (sig_out === sig_in) && (exp_out === exp_in); tally(ok);
    $display("   %h  %h    | %h  %h | %s", sig_in, exp_in, sig_out, exp_out, pf(ok));

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 500; i = i + 1) begin
      sig_in = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
      exp_in = {$random(seed), $random(seed)};
      #10;
      ok = (sig_out === sig_in) && (exp_out === exp_in);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL sig=%h exp=%h", sig_in, exp_in);
    end
    random_done(500, f0);

    summary;
  end
endmodule
