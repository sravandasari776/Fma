// tb_stage3_csla.v -- unit test for stage3_csla (8.3 Carry-Select Adder).
// resolved_o == sum_i + carry_i (mod 2^76). The adder is split at bit 38:
// the upper half is pre-computed for carry-in 0 and 1 and selected by the
// lower half's carry-out, so the directed cases target that boundary.
`include "fma_defs.vh"

module tb_stage3_csla;
  parameter TB_NAME = "stage3_csla";
  `include "tb_util.vh"

  reg  [`WW-1:0] s, c;
  wire [`WW-1:0] r;
  stage3_csla dut (.sum_i(s), .carry_i(c), .resolved_o(r));

  localparam [`WW-1:0] ONE  = {{(`WW-1){1'b0}}, 1'b1} << `MSBPOS;   // 1.0 (bit 71)
  localparam [`WW-1:0] ALL1 = {`WW{1'b1}};                          // -1 LSB
  localparam [`WW-1:0] LOW  = ALL1 >> (`WW - `WW/2);               // low half all ones
  reg [`WW-1:0] e_r;
  reg ok;
  integer i, f0;

  task directed;
    input [`WW-1:0] ts, tc;
    input [8*44-1:0] note;
    begin
      s = ts; c = tc; #10;
      e_r = ts + tc;
      ok = (r === e_r);
      tally(ok);
      $display("   %h + %h | %h | %h | %s  %0s", s, c, r, e_r, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage3_csla  (MPFMA-DS-001 8.3 Carry-Select Adder)",
           "resolved = sum + carry (mod 2^76); upper 38 bits selected by the lower half's carry-out");

    section("directed tests");
    $display("   sum_i (76b) + carry_i (76b) | resolved | expected | result");
    directed(0, 0, "0 + 0");
    directed(LOW, 1, "carry out of the low half (select hi+1)");
    directed(LOW >> 1, 1, "no carry out of the low half");
    directed(ONE, ONE, "1.0 + 1.0 = 2.0");
    directed(ALL1, 1, "-1 + 1 = 0 (wraps)");
    directed(~ONE + 1, ONE >> 1, "-1.0 + 0.5: negative stays two's complement");
    directed(ALL1, ALL1, "-1 + -1 = -2");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 3000; i = i + 1) begin
      s = {$random(seed), $random(seed), $random(seed)};
      c = {$random(seed), $random(seed), $random(seed)};
      #10;
      e_r = s + c;
      ok = (r === e_r);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL s=%h c=%h got=%h exp=%h", s, c, r, e_r);
    end
    random_done(3000, f0);

    summary;
  end
endmodule
