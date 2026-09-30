// tb_stage3_lzau.v -- unit test for stage3_lzau (8.4 Leading Zero Anticipator Unit).
// exp_adjust = (position of the leading '1') - 71   (bit 71 = MSBPOS)
//   > 0 : the sum overflowed above 1.x, needs a right shift, exponent grows
//   < 0 : cancellation, needs a left shift, exponent shrinks
// is_zero = 1 (and exp_adjust = 0) when the magnitude is 0.
`include "fma_defs.vh"

module tb_stage3_lzau;
  parameter TB_NAME = "stage3_lzau";
  `include "tb_util.vh"

  reg  [`WW-1:0]          mag;
  wire signed [`EXPW-1:0] adj;
  wire                    z;
  stage3_lzau dut (.magnitude_i(mag), .exp_adjust_o(adj), .is_zero_o(z));

  localparam [`WW-1:0] ONE  = {{(`WW-1){1'b0}}, 1'b1} << `MSBPOS;   // 1.0 (bit 71)
  localparam [`WW-1:0] ALL1 = {`WW{1'b1}};                          // -1 LSB
  integer e_adj, k, q, p, i, f0;
  reg [`WW-1:0] bitp;
  reg e_z, ok;

  task ref_model;
    begin
      e_z = (mag == 0);
      q = -1;
      for (k = 0; k < `WW; k = k + 1) if (mag[k]) q = k;
      e_adj = e_z ? 0 : q - `MSBPOS;
    end
  endtask

  task directed;
    input [`WW-1:0] tm;
    input [8*40-1:0] note;
    begin
      mag = tm; #10;
      ref_model;
      ok = (adj === e_adj[`EXPW-1:0]) && (z === e_z);
      tally(ok);
      $display("   %h | %4d %b | %4d %b | %s  %0s", mag, adj, z, e_adj, e_z, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage3_lzau  (MPFMA-DS-001 8.4 LZAU)",
           "exp_adjust = (leading-one position) - 71 ; is_zero when magnitude == 0");

    section("directed tests");
    $display("   magnitude (76b)     | got adj z | exp adj z | result");
    directed(ONE,        "1.x already normalized -> 0");
    directed(ONE << 1,   "2.x (overflow by 1) -> +1");
    directed(ONE << 3,   "5-term sum, leading one at bit 74 -> +3");
    directed(ONE >> 6,   "cancellation, bit 65 -> -6");
    directed(1,          "only the LSB -> -71");
    directed(0,          "zero -> is_zero");

    section("random tests: leading '1' at every bit position 75..0");
    f0 = n_fail;
    for (p = 0; p < `WW; p = p + 1) begin
      for (i = 0; i < 25; i = i + 1) begin
        bitp = {{(`WW-1){1'b0}}, 1'b1} << p;
        mag = ({$random(seed), $random(seed), $random(seed)} & (bitp - 1)) | bitp;
        #10;
        ref_model;
        ok = (adj === e_adj[`EXPW-1:0]) && (z === e_z);
        tally(ok);
        if (!ok && n_fail - f0 <= 10) $display("   FAIL mag=%h got=%0d exp=%0d", mag, adj, e_adj);
      end
    end
    random_done(`WW * 25, f0);

    summary;
  end
endmodule
