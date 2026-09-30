// tb_stage4_normalization.v -- unit test for stage4_normalization (9.1).
// Uses the LZAU's exp_adjust to bring the leading '1' back to bit 36:
//   exp_adjust >= 0 : right shift by exp_adjust, extra_sticky = OR of bits lost
//   exp_adjust <  0 : left shift by -exp_adjust (no bits lost, sticky = 0)
// The random test feeds exp_adjust = (leading-one position - 36), exactly as
// the LZAU would, and also checks the result really is normalized.
`include "fma_defs.vh"

module tb_stage4_normalization;
  parameter TB_NAME = "stage4_normalization";
  `include "tb_util.vh"

  reg  [`WW-1:0]          mag;
  reg  signed [`EXPW-1:0] adj;
  wire [`WW-1:0]          norm;
  wire                    xst;
  stage4_normalization dut (.magnitude_i(mag), .exp_adjust_i(adj), .normalized_o(norm), .extra_sticky_o(xst));

  reg [103:0]   full;
  reg [`WW-1:0] e_norm;
  reg           e_st, ok;
  integer p, i, f0;

  task ref_model;
    begin
      if (adj >= 0) begin
        full   = {mag, 64'b0} >> adj;
        e_norm = full[103:64];
        e_st   = |full[63:0];
      end else begin
        e_norm = mag << (-adj);
        e_st   = 1'b0;
      end
    end
  endtask

  task directed;
    input [`WW-1:0] tm;
    input signed [`EXPW-1:0] ta;
    input [8*40-1:0] note;
    begin
      mag = tm; adj = ta; #10;
      ref_model;
      ok = (norm === e_norm) && (xst === e_st);
      tally(ok);
      $display("   %h %4d | %h %b | %h %b | %s  %0s", mag, adj, norm, xst, e_norm, e_st, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_normalization  (MPFMA-DS-001 9.1 Normalization)",
           "adj>=0: right shift by adj (+sticky of lost bits); adj<0: left shift by -adj; leading 1 ends at bit 36");

    section("directed tests");
    $display("   magnitude  adj  | normalized st | expected   st | result");
    directed(40'h10_0000_0000,   0, "already normalized");
    directed(40'h20_0000_0000,   1, "2.0 -> shift right 1");
    directed(40'h30_0000_0001,   1, "right shift loses a 1 -> sticky");
    directed(40'h80_0000_0004,   3, "right shift 3");
    directed(40'h00_4000_0000,  -6, "cancellation: shift left 6");
    directed(40'h00_0000_0001, -36, "LSB only: shift left 36");

    section("random tests: exp_adjust = leading-one position - 36 (as the LZAU gives)");
    f0 = n_fail;
    for (p = 0; p < `WW; p = p + 1) begin
      for (i = 0; i < 25; i = i + 1) begin
        mag = ({$random(seed), $random(seed)} & ((40'h1 << p) - 1)) | (40'h1 << p);
        adj = p - `MSBPOS;
        #10;
        ref_model;
        ok = (norm === e_norm) && (xst === e_st) && norm[`MSBPOS] && (norm[`WW-1:`MSBPOS+1] == 0);
        tally(ok);
        if (!ok && n_fail - f0 <= 10)
          $display("   FAIL mag=%h adj=%0d got=%h/%b exp=%h/%b", mag, adj, norm, xst, e_norm, e_st);
      end
    end
    random_done(`WW * 25, f0);

    summary;
  end
endmodule
