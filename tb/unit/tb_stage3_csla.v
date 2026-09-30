// tb_stage3_csla.v -- unit test for stage3_csla (8.3 Carry-Select Adder).
// resolved_o == sum_i + carry_i (mod 2^40). The adder is split at bit 20:
// the upper half is pre-computed for carry-in 0 and 1 and selected by the
// lower half's carry-out, so the directed cases target that boundary.
`include "fma_defs.vh"

module tb_stage3_csla;
  parameter TB_NAME = "stage3_csla";
  `include "tb_util.vh"

  reg  [`WW-1:0] s, c;
  wire [`WW-1:0] r;
  stage3_csla dut (.sum_i(s), .carry_i(c), .resolved_o(r));

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
           "resolved = sum + carry (mod 2^40); upper 20 bits selected by the lower half's carry-out");

    section("directed tests");
    $display("   sum_i        carry_i    | resolved   | expected   | result");
    directed(40'h00_0000_0000, 40'h00_0000_0000, "0 + 0");
    directed(40'h00_000F_FFFF, 40'h00_0000_0001, "carry out of the low half (select hi+1)");
    directed(40'h00_0007_FFFF, 40'h00_0000_0001, "no carry out of the low half");
    directed(40'h10_0000_0000, 40'h10_0000_0000, "1.0 + 1.0 = 2.0");
    directed(40'hFF_FFFF_FFFF, 40'h00_0000_0001, "-1 + 1 = 0 (wraps)");
    directed(40'hF0_0000_0000, 40'h08_0000_0000, "negative result stays two's complement");
    directed(40'hFF_FFFF_FFFF, 40'hFF_FFFF_FFFF, "-1 + -1 = -2");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 3000; i = i + 1) begin
      s = {$random(seed), $random(seed)};
      c = {$random(seed), $random(seed)};
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
