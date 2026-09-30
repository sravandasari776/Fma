// tb_fmt_to_fp64.v -- unit test for fmt_to_fp64 (decimal I/O shell, output side).
// One encoded value of the selected format goes in; out comes the same
// value as a double -- exactly (every value of all 7 formats fits in a
// double), with +/-0 and +/-Inf keeping their sign and NaN -> canonical NaN.
// Reference: the value decoded with Verilog real arithmetic ($realtobits).
// Also checks the round trip: fp64_to_fmt(fmt_to_fp64(x)) == x for every
// non-NaN encoding (both shell converters together are lossless).
// Exhaustive for E4M3, E5M2, HP, DLFloat16, BFloat16 and TF32; random +
// directed for SP.
`include "fma_defs.vh"

module tb_fmt_to_fp64;
  parameter TB_NAME = "fmt_to_fp64";
  `include "tb_util.vh"

  reg  [31:0] bits;
  reg  [1:0]  cls;
  reg  [3:0]  ew;
  wire [63:0] d;
  wire [31:0] back;
  wire        back_inx;
  fmt_to_fp64 dut (.bits_i(bits), .cls_i(cls), .ew_i(ew), .d_o(d));
  fp64_to_fmt rt  (.d_i(d), .cls_i(cls), .ew_i(ew), .bits_o(back), .inexact_o(back_inx));

  reg [63:0] e_d;
  reg        ok, is_nan;
  integer    i, f0, fi, total, n_enc;

  task set_fmt;
    input integer idx;  // 0..6 = E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP
    begin
      case (idx)
        0: begin cls = `CLS_8;  ew = 4; end
        1: begin cls = `CLS_8;  ew = 5; end
        2: begin cls = `CLS_16; ew = 5; end
        3: begin cls = `CLS_16; ew = 6; end
        4: begin cls = `CLS_16; ew = 8; end
        5: begin cls = `CLS_19; ew = 8; end
        default: begin cls = `CLS_32; ew = 8; end
      endcase
      total = (cls == `CLS_8) ? 8 : (cls == `CLS_16) ? 16 : (cls == `CLS_32) ? 32 : 19;
    end
  endtask

  task ref_model;
    integer m, bias, ef;
    reg     s;
    reg [31:0] mf;
    real    v;
    begin
      m    = total - 1 - ew;
      bias = (1 << (ew - 1)) - 1;
      s    = bits[total - 1];
      ef   = (bits >> m) & ((1 << ew) - 1);
      mf   = bits & ((32'h1 << m) - 1);
      is_nan = 1'b0;
      if (ef == (1 << ew) - 1) begin
        is_nan = (mf != 0);
        e_d = is_nan ? 64'h7FF8000000000000 : {s, 11'h7FF, 52'd0};
      end else if (ef == 0 && mf == 0) begin
        e_d = {s, 63'd0};
      end else begin
        if (ef == 0) v = mf * (2.0 ** (1 - bias - m));
        else         v = (mf + (2.0 ** m)) * (2.0 ** (ef - bias - m));
        e_d = $realtobits(s ? -v : v);
      end
    end
  endtask

  task check;
    begin
      evaluate;
      tally(ok);
    end
  endtask

  task evaluate;
    begin
      #1;
      ref_model;
      // value exact, and the round trip gives the same encoding back
      // (NaN: any NaN encoding comes back as the canonical NaN)
      ok = (d === e_d) && (back_inx === 1'b0) &&
           (is_nan ? (back === (((32'h1 << ew) - 1) << (total - 1 - ew)) + 1) : (back === bits));
    end
  endtask

  task directed;
    input [31:0] tb;
    input integer tf;
    input [63:0] known;
    input [8*40-1:0] note;
    begin
      set_fmt(tf); bits = tb;
      evaluate;
      ok = ok && (d === known);      // must match both the reference model and the known double
      tally(ok);
      $display("   %h fmt %0d | %h | %h | back %h | %s  %0s", bits, tf, d, known, back, pf(ok), note);
    end
  endtask

  initial begin
    banner("fmt_to_fp64  (decimal I/O shell: E4M3/E5M2/HP/DLF16/BF16/TF32/SP -> double)",
           "exact widening to a double; round trip through fp64_to_fmt must give the same bits back");

    section("directed tests (fmt: 0 E4M3, 1 E5M2, 2 HP, 3 DLF16, 4 BF16, 5 TF32, 6 SP)");
    $display("   bits     fmt | double           | known            | round trip | result");
    directed(32'h00003C00, 2, $realtobits(1.0),            "HP 1.0");
    directed(32'h00002E66, 2, $realtobits(0.0999755859375),"HP 0.0999755859375 (0.1 as stored)");
    directed(32'h00007BFF, 2, $realtobits(65504.0),        "HP largest normal");
    directed(32'h00000001, 2, $realtobits(5.9604644775390625e-8), "HP smallest subnormal 2^-24");
    directed(32'h00000077, 0, $realtobits(240.0),          "E4M3 largest 240");
    directed(32'h00000001, 0, $realtobits(0.001953125),    "E4M3 smallest subnormal 2^-9");
    directed(32'h00060100, 5, $realtobits(-2.5),           "TF32 -2.5");
    directed(32'h40490FDB, 6, $realtobits(3.1415927410125732), "SP pi");
    directed(32'h00000001, 6, 64'h36A0000000000000,        "SP smallest subnormal 2^-149");
    directed(32'h00008000, 2, 64'h8000000000000000,        "HP -0 keeps its sign");
    directed(32'h0000FC00, 2, 64'hFFF0000000000000,        "HP -Inf");
    directed(32'h7FC00000, 6, 64'h7FF8000000000000,        "SP NaN -> canonical NaN");

    section("exhaustive tests: every encoding of E4M3, E5M2, HP, DLFloat16, BFloat16, TF32");
    f0 = n_fail;
    n_enc = 0;
    for (fi = 0; fi < 6; fi = fi + 1) begin
      set_fmt(fi);
      for (i = 0; i < (1 << total); i = i + 1) begin
        bits = i;
        check;
        n_enc = n_enc + 1;
        if (!ok && n_fail - f0 <= 10)
          $display("   FAIL fmt=%0d bits=%h got=%h exp=%h back=%h", fi, bits, d, e_d, back);
      end
    end
    $display("   %0d encodings checked (every value of 6 formats): %0d mismatches", n_enc, n_fail - f0);

    section("random tests: SP (2^32 encodings, 20000 sampled, incl. subnormals and specials)");
    f0 = n_fail;
    set_fmt(6);
    for (i = 0; i < 20000; i = i + 1) begin
      bits = $random(seed);
      if (i % 5 == 0) bits[30:23] = 8'h00;          // subnormals / zero
      if (i % 97 == 0) bits[30:23] = 8'hFF;         // Inf / NaN
      check;
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL SP bits=%h got=%h exp=%h back=%h", bits, d, e_d, back);
    end
    random_done(20000, f0);

    summary;
  end
endmodule
