// tb_stage1_unified_lzc.v -- unit test for stage1_unified_lzc (6.4).
// Counts leading zeros of a 24-bit significand (0..24) and flags all-zero.
// Built from four 6-bit sub-counters, so the random test places the
// leading '1' at EVERY bit position (covers every segment boundary).
`include "fma_defs.vh"

module tb_stage1_unified_lzc;
  parameter TB_NAME = "stage1_unified_lzc";
  `include "tb_util.vh"

  reg  [`SIGW-1:0] sig;
  wire [4:0]       lzc;
  wire             az;
  stage1_unified_lzc dut (.sig_i(sig), .lzc_o(lzc), .az_o(az));

  reg [4:0] exp_lzc;
  reg       exp_az, ok;
  integer i, p, k, f0;

  // reference: scan from MSB for the first '1'
  task ref_model;
    begin
      exp_az  = (sig == 0);
      exp_lzc = 24;
      for (k = 0; k < 24; k = k + 1)
        if (exp_lzc == 24 && sig[23 - k]) exp_lzc = k;
    end
  endtask

  task directed;
    input [`SIGW-1:0] s;
    input [8*30-1:0] note;
    begin
      sig = s; #10;
      ref_model;
      ok = (lzc === exp_lzc) && (az === exp_az);
      tally(ok);
      $display("   %b | %2d  %b | %2d  %b | %s  %0s", sig, lzc, az, exp_lzc, exp_az, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage1_unified_lzc  (MPFMA-DS-001 6.4 Unified Leading Zero Counter)",
           "lzc = number of leading zeros of the 24-bit significand (0..24); az = 1 if all zero");

    section("directed tests");
    $display("   sig (24 bits)            | lzc az | exp az | result");
    directed(24'h800000, "normalized (hidden bit set)");
    directed(24'h400000, "1 leading zero");
    directed(24'h020000, "first 6-bit segment empty");
    directed(24'h00FFFF, "8 leading zeros");
    directed(24'h000800, "segment boundary 12");
    directed(24'h000020, "segment boundary 18");
    directed(24'h000001, "only LSB set");
    directed(24'h000000, "all zero");

    section("random tests: leading '1' at every position 23..0, random bits below");
    f0 = n_fail;
    for (p = 0; p < 24; p = p + 1) begin
      for (i = 0; i < 40; i = i + 1) begin
        sig = ($random(seed) & ((24'h1 << p) - 1)) | (24'h1 << p);
        #10;
        ref_model;
        ok = (lzc === exp_lzc) && (az === exp_az);
        tally(ok);
        if (!ok && n_fail - f0 <= 10)
          $display("   FAIL sig=%b got lzc=%0d az=%b exp lzc=%0d az=%b", sig, lzc, az, exp_lzc, exp_az);
      end
    end
    random_done(24 * 40, f0);

    summary;
  end
endmodule
