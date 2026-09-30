// tb_csa32.v -- unit test for csa32 (generic 3:2 carry-save compressor).
// Checks: sum = a^b^c, carry = majority(a,b,c) << 1, and the property the
// rest of the design relies on: sum + carry == a + b + c (mod 2^W).
`include "fma_defs.vh"

module tb_csa32;
  parameter TB_NAME = "csa32";
  `include "tb_util.vh"

  // small 8-bit instance: easy to read in binary for the directed cases
  reg  [7:0]  a8, b8, c8;
  wire [7:0]  s8, cy8;
  csa32 #(8) dut8 (.a_i(a8), .b_i(b8), .c_i(c8), .sum_o(s8), .carry_o(cy8));

  // 48-bit instance: the width used inside the Booth multiplier
  reg  [47:0] a, b, c;
  wire [47:0] s, cy;
  csa32 #(48) dut48 (.a_i(a), .b_i(b), .c_i(c), .sum_o(s), .carry_o(cy));

  reg [7:0]  exp_s8, exp_c8, tot8;
  reg [47:0] exp_s, exp_c, tot;
  reg ok;
  integer i, f0;

  task directed8;
    input [7:0] ta, tb, tc;
    begin
      a8 = ta; b8 = tb; c8 = tc;
      #10;
      exp_s8 = ta ^ tb ^ tc;
      exp_c8 = ((ta & tb) | (tb & tc) | (ta & tc)) << 1;
      tot8   = ta + tb + tc;
      ok = (s8 === exp_s8) && (cy8 === exp_c8) && ((s8 + cy8) & 8'hFF) === tot8;
      tally(ok);
      $display("   %b %b %b | %b %b | %3d  %3d | %s",
               a8, b8, c8, s8, cy8, (s8 + cy8) & 8'hFF, tot8, pf(ok));
    end
  endtask

  initial begin
    banner("csa32  (generic 3:2 carry-save compressor, used by every CSA block)",
           "sum = a^b^c ; carry = maj(a,b,c)<<1 ; sum+carry == a+b+c (mod 2^W)");

    section("directed tests, W=8 (binary)");
    $display("   a        b        c        | sum      carry    | s+c  a+b+c | result");
    directed8(8'h00, 8'h00, 8'h00);
    directed8(8'h01, 8'h01, 8'h01);
    directed8(8'hFF, 8'h01, 8'h00);
    directed8(8'hAA, 8'h55, 8'hFF);
    directed8(8'h0F, 8'h0F, 8'h0F);
    directed8(8'h12, 8'h34, 8'h56);
    directed8(8'h80, 8'h80, 8'h80);

    section("random tests, W=48");
    f0 = n_fail;
    for (i = 0; i < 1000; i = i + 1) begin
      a = {$random(seed), $random(seed)};
      b = {$random(seed), $random(seed)};
      c = {$random(seed), $random(seed)};
      #10;
      exp_s = a ^ b ^ c;
      exp_c = ((a & b) | (b & c) | (a & c)) << 1;
      tot   = a + b + c;
      ok = (s === exp_s) && (cy === exp_c) && ((s + cy) === tot);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL a=%h b=%h c=%h sum=%h carry=%h (s+c=%h exp=%h)", a, b, c, s, cy, s + cy, tot);
    end
    random_done(1000, f0);

    summary;
  end
endmodule
