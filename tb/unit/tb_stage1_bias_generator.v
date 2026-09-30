// tb_stage1_bias_generator.v -- unit test for stage1_bias_generator (6.2).
// bias = 2^(ew-1) - 1 ; when the operand is subnormal (sf=1) the block
// returns bias-1 (a subnormal's exponent is 1-bias, not 0-bias).
// Exhaustive: every legal exponent width (4..8) x sf (0/1).
`include "fma_defs.vh"

module tb_stage1_bias_generator;
  parameter TB_NAME = "stage1_bias_generator";
  `include "tb_util.vh"

  reg  [3:0] ew;
  reg        sf;
  wire [7:0] bias;
  stage1_bias_generator dut (.ew_i(ew), .sf_i(sf), .bias_o(bias));

  reg [7:0] exp_b;
  reg ok;

  task directed;
    input [3:0] tew;
    input       tsf;
    input [8*34-1:0] fmts;
    begin
      ew = tew; sf = tsf; #10;
      exp_b = ((8'd1 << (tew - 1)) - 1) - (tsf ? 1 : 0);
      ok = (bias === exp_b);
      tally(ok);
      $display("   %0d   %b  | %3d   | %3d  | %s  %0s", ew, sf, bias, exp_b, pf(ok), fmts);
    end
  endtask

  initial begin
    banner("stage1_bias_generator  (MPFMA-DS-001 6.2 Bias Generator)",
           "bias = 2^(ew-1)-1 for a normal operand, bias-1 for a subnormal operand (sf=1)");

    section("exhaustive tests (all exponent widths x subnormal flag)");
    $display("   ew  sf | bias  | exp  | result  formats using this ew");
    directed(4'd4, 1'b0, "E4M3");
    directed(4'd4, 1'b1, "E4M3 (subnormal)");
    directed(4'd5, 1'b0, "E5M2, HP (binary16)");
    directed(4'd5, 1'b1, "E5M2, HP (subnormal)");
    directed(4'd6, 1'b0, "DLFloat16");
    directed(4'd6, 1'b1, "DLFloat16 (subnormal)");
    directed(4'd7, 1'b0, "(not used by a named format)");
    directed(4'd7, 1'b1, "(not used by a named format)");
    directed(4'd8, 1'b0, "BFloat16, TF32, SP");
    directed(4'd8, 1'b1, "BFloat16, TF32, SP (subnormal)");

    summary;
  end
endmodule
