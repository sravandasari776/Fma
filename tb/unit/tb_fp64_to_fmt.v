// tb_fp64_to_fmt.v -- unit test for fp64_to_fmt (decimal I/O shell, input side).
// A double goes in; out comes the nearest value of the selected format
// (round to nearest, ties to even), +/-Inf on overflow, subnormals/zero at
// the bottom, canonical NaN for NaN.
// Reference model: written independently with Verilog real arithmetic --
// scale the value by powers of 2 (exact) so the kept bits become an
// integer part, then round the fractional remainder. It shares no code
// with the bit-slicing RTL.
`include "fma_defs.vh"

module tb_fp64_to_fmt;
  parameter TB_NAME = "fp64_to_fmt";
  `include "tb_util.vh"

  reg  [63:0] d;
  reg  [1:0]  cls;
  reg  [3:0]  ew;
  wire [31:0] bits;
  wire        inx;
  fp64_to_fmt dut (.d_i(d), .cls_i(cls), .ew_i(ew), .bits_o(bits), .inexact_o(inx));

  reg [31:0] e_bits;
  reg        e_inx, ok;
  integer    i, f0, fi;

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
    end
  endtask

  task ref_model;
    integer total, m, bias, emin, emax, E, se, n, ones;
    real    xv, t, q, fr;
    reg     s;
    begin
      total = (cls == `CLS_8) ? 8 : (cls == `CLS_16) ? 16 : (cls == `CLS_32) ? 32 : 19;
      m     = total - 1 - ew;
      bias  = (1 << (ew - 1)) - 1;
      emin  = 1 - bias;
      emax  = bias;
      ones  = (1 << ew) - 1;
      s     = d[63];
      e_inx = 1'b0;
      if (d[62:52] == 11'h7FF) begin
        if (d[51:0] != 0) e_bits = (ones << m) | 1;                         // canonical NaN
        else              e_bits = ({31'd0, s} << (total - 1)) | (ones << m); // +/-Inf
      end else if (d[62:52] == 0) begin
        e_bits = {31'd0, s} << (total - 1);                                   // +/-0
        e_inx  = (d[51:0] != 0);
      end else begin
        xv = $bitstoreal({1'b0, d[62:0]});                                   // |value|
        t = xv; E = 0;
        while (t >= 2.0) begin t = t / 2.0; E = E + 1; end
        while (t < 1.0)  begin t = t * 2.0; E = E - 1; end
        se = (E < emin) ? emin : E;
        q  = xv * (2.0 ** (m - se));       // integer part = the kept bits
        n  = $rtoi(q);
        fr = q - n;
        e_inx = (fr != 0.0);
        if (fr > 0.5 || (fr == 0.5 && (n % 2) == 1)) n = n + 1;
        if (E >= emin) begin
          if (n >= (1 << (m + 1))) begin n = n / 2; E = E + 1; end
          if (E > emax) begin
            e_bits = ({31'd0, s} << (total - 1)) | (ones << m);
            e_inx  = 1'b1;
          end else begin
            e_bits = ({31'd0, s} << (total - 1)) | ((E + bias) << m) | (n - (1 << m));
          end
        end else begin
          // subnormal: n <= 2^m; n == 2^m is exactly the smallest normal encoding
          e_bits = ({31'd0, s} << (total - 1)) | n;
        end
      end
    end
  endtask

  task evaluate;
    begin
      #1;
      ref_model;
      ok = (bits === e_bits) && (inx === e_inx);
    end
  endtask

  task check;
    begin
      evaluate;
      tally(ok);
    end
  endtask

  task directed;
    input [63:0] td;
    input integer tf;
    input [31:0] known;       // hand-known encoding
    input [8*44-1:0] note;
    begin
      d = td; set_fmt(tf);
      evaluate;
      ok = ok && (bits === known);   // must match both the reference model and the known encoding
      tally(ok);
      $display("   %h -> fmt %0d | %h %b | %h %b | known %h | %s  %0s",
               d, tf, bits, inx, e_bits, e_inx, known, pf(ok), note);
    end
  endtask

  initial begin
    banner("fp64_to_fmt  (decimal I/O shell: double -> E4M3/E5M2/HP/DLF16/BF16/TF32/SP)",
           "round a double to the selected format: nearest-even, overflow -> Inf, subnormals, NaN");

    section("directed tests (fmt: 0 E4M3, 1 E5M2, 2 HP, 3 DLF16, 4 BF16, 5 TF32, 6 SP)");
    $display("   double             fmt | got      inx | reference inx | known    | result");
    directed($realtobits(1.0),                  6, 32'h3F800000, "SP 1.0");
    directed($realtobits(0.1),                  6, 32'h3DCCCCCD, "SP 0.1 (rounded)");
    directed($realtobits(0.1),                  2, 32'h00002E66, "HP 0.1 (rounded)");
    directed($realtobits(-2.5),                 5, 32'h00060100, "TF32 -2.5");
    directed($realtobits(1.0),                  3, 32'h00003E00, "DLFloat16 1.0");
    directed($realtobits(65504.0),              2, 32'h00007BFF, "HP largest normal");
    directed($realtobits(65520.0),              2, 32'h00007C00, "HP tie above max -> even -> +Inf");
    directed($realtobits(65519.0),              2, 32'h00007BFF, "HP just below that tie -> max");
    directed($realtobits(240.0),                0, 32'h00000077, "E4M3 largest (IEEE-style) 240");
    directed($realtobits(248.0),                0, 32'h00000078, "E4M3 tie above 240 -> +Inf");
    directed($realtobits(57344.0),              1, 32'h0000007B, "E5M2 largest 57344");
    directed($realtobits(61440.0),              1, 32'h0000007C, "E5M2 tie above max -> +Inf");
    directed($realtobits(5.9604644775390625e-8),2, 32'h00000001, "HP 2^-24 = smallest subnormal");
    directed($realtobits(2.98023223876953125e-8),2,32'h00000000, "HP 2^-25: tie with 0 -> even = 0");
    directed($realtobits(4.470348358154296875e-8),2,32'h00000001,"HP 1.5*2^-25 -> smallest subnormal");
    directed($realtobits(1.0e-8),               2, 32'h00000000, "HP 1e-8 -> 0");
    directed($realtobits(1.00048828125),        2, 32'h00003C00, "HP 1+2^-11: tie, even -> 1.0");
    directed($realtobits(1.00146484375),        2, 32'h00003C02, "HP 1+3*2^-11: tie, odd -> up");
    directed($realtobits(1.00390625),           4, 32'h00003F80, "BF16 1+2^-8: tie, even -> 1.0");
    directed(64'h7FF8000000000000,              6, 32'h7F800001, "NaN -> canonical NaN");
    directed(64'hFFF0000000000000,              2, 32'h0000FC00, "-Inf");
    directed(64'h8000000000000000,              6, 32'h80000000, "-0 keeps its sign");
    directed(64'h0000000000000001,              6, 32'h00000000, "double subnormal -> 0");
    directed($realtobits(1.0e300),              6, 32'h7F800000, "1e300 -> SP +Inf");

    section("random tests: every format, exponents from below its subnormals to above its max");
    f0 = n_fail;
    for (i = 0; i < 7000; i = i + 1) begin
      fi = i % 7;
      set_fmt(fi);
      d[63]    = $random(seed);
      // exponent within [emin - 30, emax + 3] of the format (bias 1023 in the double)
      d[62:52] = 1023 + (2 - (1 << (ew - 1))) - 30 + ($unsigned($random(seed)) % ((1 << ew) + 30));
      d[51:0]  = {$random(seed), $random(seed)};
      if (i % 4 == 0) d[51:0] = d[51:0] & ~((52'd1 << (52 - ($unsigned($random(seed)) % 26))) - 1); // short mantissas: exact values and ties
      check;
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL d=%h fmt=%0d got=%h/%b exp=%h/%b", d, fi, bits, inx, e_bits, e_inx);
    end
    random_done(7000, f0);

    summary;
  end
endmodule
