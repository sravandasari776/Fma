// tb_stage3_sticky_logic.v -- unit test for stage3_sticky_logic (8.2).
// sticky_o = OR of the addend sticky and the 4 product stickies.
// Exhaustive: all 32 input combinations.
`include "fma_defs.vh"

module tb_stage3_sticky_logic;
  parameter TB_NAME = "stage3_sticky_logic";
  `include "tb_util.vh"

  reg        a_st;
  reg  [3:0] p_st;
  wire       st;
  stage3_sticky_logic dut (.a_sticky_i(a_st), .prod_sticky_i(p_st), .sticky_o(st));

  reg e_st, ok;
  integer i;

  initial begin
    banner("stage3_sticky_logic  (MPFMA-DS-001 8.2 Sticky Logic)",
           "sticky = a_sticky | p_sticky[0] | p_sticky[1] | p_sticky[2] | p_sticky[3]");

    section("exhaustive tests (all 32 combinations)");
    $display("   a_st p_st[3:0] | sticky | exp | result");
    for (i = 0; i < 32; i = i + 1) begin
      {a_st, p_st} = i;
      #10;
      e_st = a_st | (|p_st);
      ok = (st === e_st);
      tally(ok);
      $display("   %b    %b      |   %b    |  %b  | %s", a_st, p_st, st, e_st, pf(ok));
    end

    summary;
  end
endmodule
