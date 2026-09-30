// tb_stage1_booth_multiplier.v -- unit test for stage1_booth_multiplier (6.3).
// Radix-4 Booth 24x24 multiplier with a carry-save output. The two outputs
// are NOT the product individually; their sum (mod 2^48) must equal
// sig_b * sig_c exactly.
`include "fma_defs.vh"

module tb_stage1_booth_multiplier;
  parameter TB_NAME = "stage1_booth_multiplier";
  `include "tb_util.vh"

  reg  [`SIGW-1:0] b, c;
  wire [47:0]      s, cy;
  stage1_booth_multiplier dut (.sig_b_i(b), .sig_c_i(c), .sum_o(s), .carry_o(cy));

  reg  [47:0] exp_p, got_p;
  reg ok;
  integer i, f0;

  task directed;
    input [`SIGW-1:0] tb_, tc_;
    input [8*30-1:0] note;
    begin
      b = tb_; c = tc_; #10;
      exp_p = b * c;
      got_p = s + cy;
      ok = (got_p === exp_p);
      tally(ok);
      $display("   %h x %h | %h + %h = %h | %h | %s  %0s", b, c, s, cy, got_p, exp_p, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage1_booth_multiplier  (MPFMA-DS-001 6.3 Unified Radix-4 Booth Multiplier)",
           "sum_o + carry_o (mod 2^48) == sig_b * sig_c   (24-bit unified significands)");

    section("directed tests (0x800000 = 1.0 in the unified significand format)");
    $display("   sig_b    sig_c   | sum_o          carry_o          sum+carry      | expected       | result");
    directed(24'h800000, 24'h800000, "1.0 x 1.0 = 1.0 (2^46)");
    directed(24'hC00000, 24'hC00000, "1.5 x 1.5 = 2.25");
    directed(24'h900000, 24'hA00000, "1.125 x 1.25 (E4M3-style)");
    directed(24'hFFFFFF, 24'hFFFFFF, "max x max");
    directed(24'h000000, 24'hABCDEF, "0 x anything = 0");
    directed(24'h000001, 24'h000001, "1 x 1 (LSBs)");
    directed(24'hAAAAAA, 24'h555555, "alternating Booth groups");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 3000; i = i + 1) begin
      b = $random(seed);
      c = $random(seed);
      if (i % 3 == 0) begin b[23] = 1'b1; c[23] = 1'b1; end // normalized operands
      #10;
      exp_p = b * c;
      got_p = s + cy;
      ok = (got_p === exp_p);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL b=%h c=%h got=%h exp=%h", b, c, got_p, exp_p);
    end
    random_done(3000, f0);

    summary;
  end
endmodule
