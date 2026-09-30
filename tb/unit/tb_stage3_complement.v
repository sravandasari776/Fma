// tb_stage3_complement.v -- unit test for stage3_complement (8.6).
// Converts the CSLA's 76-bit two's-complement result to sign + magnitude:
//   sign_o = bit 75 ; magnitude_o = sign ? -x : x   (1.0 = bit 71)
`include "fma_defs.vh"

module tb_stage3_complement;
  parameter TB_NAME = "stage3_complement";
  `include "tb_util.vh"

  reg  [`WW-1:0] x;
  wire           sg;
  wire [`WW-1:0] mag;
  stage3_complement dut (.resolved_i(x), .sign_o(sg), .magnitude_o(mag));

  localparam [`WW-1:0] ONE  = {{(`WW-1){1'b0}}, 1'b1} << `MSBPOS;   // 1.0 (bit 71)
  localparam [`WW-1:0] ALL1 = {`WW{1'b1}};                          // -1 LSB
  reg           e_sg, ok;
  reg [`WW-1:0] e_mag;
  integer i, f0;

  task ref_model;
    begin
      e_sg  = x[`WW-1];
      e_mag = e_sg ? (~x + 1) : x;
    end
  endtask

  task directed;
    input [`WW-1:0] tx;
    input [8*44-1:0] note;
    begin
      x = tx; #10;
      ref_model;
      ok = (sg === e_sg) && (mag === e_mag);
      tally(ok);
      $display("   %h | %b %h | %b %h | %s  %0s", x, sg, mag, e_sg, e_mag, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage3_complement  (MPFMA-DS-001 8.6 Complement)",
           "sign = resolved[75] ; magnitude = sign ? (~resolved + 1) : resolved");

    section("directed tests");
    $display("   resolved (76b)      | got: s magnitude        | exp: s magnitude        | result");
    directed(ONE,           "+1.0 stays as is");
    directed(~ONE + 1,      "-1.0 -> sign 1, magnitude 1.0");
    directed(ALL1,          "-1 LSB -> magnitude 1");
    directed(0,             "zero");
    directed(ALL1 >> 1,     "largest positive");
    directed(~(ALL1 >> 1),  "most negative (magnitude = 2^75)");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      x = {$random(seed), $random(seed), $random(seed)};
      #10;
      ref_model;
      ok = (sg === e_sg) && (mag === e_mag);
      tally(ok);
      if (!ok && n_fail - f0 <= 10) $display("   FAIL x=%h got=%b/%h exp=%b/%h", x, sg, mag, e_sg, e_mag);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
