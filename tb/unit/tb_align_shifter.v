// tb_align_shifter.v -- unit test for align_shifter (shared barrel right-shifter).
// The 24-bit significand is placed with its hidden bit (sig[23]) at bit
// MSBPOS=36 of a 40-bit frame, then shifted right by shift_i (0..63).
// sticky_o must be 1 exactly when a '1' bit fell off the bottom.
`include "fma_defs.vh"

module tb_align_shifter;
  parameter TB_NAME = "align_shifter";
  `include "tb_util.vh"

  reg  [`SIGW-1:0] sig;
  reg  [`SHW-1:0]  sh;
  wire [`WW-1:0]   aligned;
  wire             sticky;

  align_shifter dut (.sig_i(sig), .shift_i(sh), .aligned_o(aligned), .sticky_o(sticky));

  // reference: do the shift in a 104-bit register (64 extra fraction bits)
  // so nothing is lost, then split into the kept 40 bits and the sticky OR.
  reg [103:0] full;
  reg [`WW-1:0] exp_al;
  reg exp_st, ok;
  integer i, f0;

  task ref_model;
    begin
      full   = {3'b0, sig, 13'b0, 64'b0} >> sh;
      exp_al = full[103:64];
      exp_st = |full[63:0];
    end
  endtask

  task directed;
    input [`SIGW-1:0] s;
    input [`SHW-1:0]  n;
    input [8*30-1:0]  note;
    begin
      sig = s; sh = n; #10;
      ref_model;
      ok = (aligned === exp_al) && (sticky === exp_st);
      tally(ok);
      $display("   %h   %2d  | %h  %b | %h  %b | %s  %0s",
               sig, sh, aligned, sticky, exp_al, exp_st, pf(ok), note);
    end
  endtask

  initial begin
    banner("align_shifter  (barrel shifter shared by Addend Alignment 7.2 / Mult Aligner 7.6)",
           "aligned = ({3'b0,sig,13'b0} >> shift) ; sticky = OR of all bits shifted out");

    section("directed tests");
    $display("   sig      shift | aligned(40b)  st | expected      st | result");
    directed(24'h800000,  0, "1.0, no shift (bit 36)");
    directed(24'h800000,  1, "1.0 >> 1 -> 0.5");
    directed(24'hC00000,  4, "1.5 >> 4");
    directed(24'hC00001, 13, "LSB lands on bit 0");
    directed(24'hC00001, 14, "LSB shifted out -> sticky");
    directed(24'h800000, 36, "hidden bit at bit 0");
    directed(24'h800000, 37, "all shifted out -> sticky");
    directed(24'hFFFFFF, 63, "max shift");
    directed(24'h000000, 10, "zero in -> zero, no sticky");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      sig = $random(seed);
      sh  = $random(seed);
      #10;
      ref_model;
      ok = (aligned === exp_al) && (sticky === exp_st);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL sig=%h sh=%0d got=%h/%b exp=%h/%b", sig, sh, aligned, sticky, exp_al, exp_st);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
