// tb_incrementer.v -- unit test for incrementer (MPFMA-DS-001 8.5).
// sum_o = a_i + 1 (mod 2^W). Used by Complement to negate (~x + 1).
`include "fma_defs.vh"

module tb_incrementer;
  parameter TB_NAME = "incrementer";
  `include "tb_util.vh"

  reg  [7:0]      a8;
  wire [7:0]      s8;
  reg  [`WW-1:0]  a;
  wire [`WW-1:0]  s;
  incrementer #(8)   dut8  (.a_i(a8), .sum_o(s8));
  incrementer #(`WW) dut40 (.a_i(a),  .sum_o(s));

  reg [`WW-1:0] exp_s;
  reg ok;
  integer i, f0;

  task directed8;
    input [7:0] ta;
    input [7:0] te;
    input [8*30-1:0] note;
    begin
      a8 = ta; #10;
      ok = (s8 === te);
      tally(ok);
      $display("   %h (%3d) | %h (%3d) | %h | %s  %0s", a8, a8, s8, s8, te, pf(ok), note);
    end
  endtask

  initial begin
    banner("incrementer  (MPFMA-DS-001 8.5 Incrementor)",
           "sum = a + 1 (wraps to 0 on all-ones); Complement uses ~x + 1 to negate");

    section("directed tests, W=8");
    $display("   a         | sum       | exp | result");
    directed8(8'h00, 8'h01, "0 + 1");
    directed8(8'h0F, 8'h10, "carry ripples 4 bits");
    directed8(8'h7F, 8'h80, "carry into MSB");
    directed8(8'hFE, 8'hFF, "");
    directed8(8'hFF, 8'h00, "all ones wraps to 0");

    section("directed tests, W=40 (the width Complement uses)");
    a = 40'h00_0000_0000; #10; exp_s = 40'h00_0000_0001; ok = (s === exp_s); tally(ok);
    $display("   a=%h  sum=%h  exp=%h  %s", a, s, exp_s, pf(ok));
    a = 40'h00_FFFF_FFFF; #10; exp_s = 40'h01_0000_0000; ok = (s === exp_s); tally(ok);
    $display("   a=%h  sum=%h  exp=%h  %s", a, s, exp_s, pf(ok));
    a = 40'hFF_FFFF_FFFF; #10; exp_s = 40'h00_0000_0000; ok = (s === exp_s); tally(ok);
    $display("   a=%h  sum=%h  exp=%h  %s", a, s, exp_s, pf(ok));

    section("random tests, W=40");
    f0 = n_fail;
    for (i = 0; i < 1000; i = i + 1) begin
      a = {$random(seed), $random(seed)};
      #10;
      exp_s = a + 1;
      ok = (s === exp_s);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL a=%h got=%h exp=%h", a, s, exp_s);
    end
    random_done(1000, f0);

    summary;
  end
endmodule
