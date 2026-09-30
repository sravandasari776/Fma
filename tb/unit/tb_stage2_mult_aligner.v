// tb_stage2_mult_aligner.v -- unit test for stage2_mult_aligner (wrapper around align_shifter, SW=48: full exact product).
// The 48-bit significand is placed with its MSB (hidden bit, sig[47]) at
// bit MSBPOS=71 of the 76-bit accumulation frame, then shifted right by
// shift_i (0..127). Every bit that falls below bit 1 is "jammed" (OR-ed)
// into frame bit 0, so a term that lost bits is carried as truncated+1/2.
// sticky_o must be 1 exactly when a '1' bit fell off the bottom (below bit 0).
`include "fma_defs.vh"

module tb_stage2_mult_aligner;
  parameter TB_NAME = "stage2_mult_aligner";
  `include "tb_util.vh"

  reg  [48-1:0]    sig;
  reg  [`SHW-1:0]  sh;
  wire [`WW-1:0]   aligned;
  wire             sticky;

  stage2_mult_aligner dut (.sig_i(sig), .shift_i(sh), .aligned_o(aligned), .sticky_o(sticky));

  // reference: do the shift in a WW+128-bit register (128 extra fraction
  // bits) so nothing is lost, then split into the kept WW bits and the
  // sticky OR, and jam the sticky into bit 0.
  reg [`WW+127:0] full;
  reg [`WW-1:0] raw, exp_al;
  reg exp_st, ok;
  integer i, f0;

  task ref_model;
    begin
      full   = { {(`WW-1-`MSBPOS){1'b0}}, sig, {(`MSBPOS+1-48){1'b0}}, 128'b0 } >> sh;
      raw    = full[`WW+127:128];
      exp_st = |full[127:0];
      exp_al = {raw[`WW-1:1], raw[0] | exp_st};
    end
  endtask

  task directed;
    input [48-1:0]    s;
    input [`SHW-1:0]  n;
    input [8*44-1:0]  note;
    begin
      sig = s; sh = n; #10;
      ref_model;
      ok = (aligned === exp_al) && (sticky === exp_st);
      tally(ok);
      $display("   %h  %3d | %h %b | %h %b | %s  %0s",
               sig, sh, aligned, sticky, exp_al, exp_st, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage2_mult_aligner  (MPFMA-DS-001 7.6 Multiplication Aligner)",
           "aligned = (sig placed at bit 71) >> shift, lost bits jammed into bit 0 ; sticky = OR of bits lost");

    section("directed tests");
    $display("   sig  shift | aligned(76b)        st | expected            st | result");
    directed(48'h800000000000,   0, "1.0, no shift (hidden bit at bit 71)");
    directed(48'h800000000000,   1, "1.0 >> 1 -> 0.5");
    directed(48'hC00000000000,   4, "1.5 >> 4");
    directed(48'hC00000000001,  24, "LSB lands exactly on bit 0 (exact)");
    directed(48'hC00000000001,  25, "LSB shifted out -> sticky, jam bit 0");
    directed(48'hFFFFFFFFFFFF,  30, "low 7 bits lost -> jam bit 0");
    directed(48'h800000000000,  71, "hidden bit lands on bit 0");
    directed(48'h800000000000,  72, "all shifted out -> only jam bit set");
    directed(48'hFFFFFFFFFFFF, 127, "max shift");
    directed(48'h000000000000,  10, "zero in -> zero, no sticky");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      sig = {$random(seed), $random(seed)};
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
