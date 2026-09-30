// tb_stage4_output_finalize.v -- unit test for stage4_output_finalize (9.5).
// Packs sign, true exponent and the rounded 24-bit significand into the
// target format's bit pattern:
//   NaN      -> exponent all ones, mantissa = ...001
//   Inf or exponent too large -> exponent all ones, mantissa 0 (overflow)
//   zero     -> all zero
//   normal   -> {sign, exp+bias, top m mantissa bits}
//   too small for normal -> subnormal (significand shifted right, exp field 0)
// Directed cases are well-known encodings that can be checked by hand.
`include "fma_defs.vh"

module tb_stage4_output_finalize;
  parameter TB_NAME = "stage4_output_finalize";
  `include "tb_util.vh"

  reg                     sg, z, n, inf;
  reg  signed [`EXPW-1:0] e;
  reg  [`SIGW-1:0]        sig;
  reg  [1:0]              cls;
  reg  [3:0]              ew;
  wire [31:0]             pk;
  stage4_output_finalize dut (.sign_i(sg), .exp_i(e), .sig_i(sig), .is_zero_i(z), .is_nan_i(n),
                              .is_inf_i(inf), .cls_i(cls), .ew_i(ew), .packed_o(pk));

  // reference packer
  reg [31:0] e_pk;
  reg [23:0] sh;
  integer total, m, bias, ef, mant, shr, i, f0;
  reg ok;

  task ref_model;
    begin
      case (cls)
        `CLS_8: total = 8; `CLS_16: total = 16; `CLS_32: total = 32; default: total = 19;
      endcase
      m = total - 1 - ew; bias = (1 << (ew - 1)) - 1;
      ef = e + bias;
      if (n) begin
        ef = (1 << ew) - 1; mant = 1;
      end else if (inf || ef >= (1 << ew) - 1) begin
        ef = (1 << ew) - 1; mant = 0;
      end else if (z) begin
        ef = 0; mant = 0;
      end else if (ef >= 1) begin
        mant = sig[22:0] >> (23 - m);
      end else begin
        shr = 1 - ef; ef = 0;
        sh  = sig >> shr;
        mant = (shr >= m + 1) ? 0 : (sh[22:0] >> (23 - m));
      end
      e_pk = (sg << (total - 1)) | (ef << m) | mant;
    end
  endtask

  task directed;
    input [8*9-1:0] fmt;
    input [1:0] tc;
    input [3:0] tew;
    input ts;
    input signed [`EXPW-1:0] te;
    input [`SIGW-1:0] tsig;
    input [2:0] flags; // {zero, nan, inf}
    input [31:0] known;  // hand-computed expected encoding
    input [8*30-1:0] note;
    begin
      cls = tc; ew = tew; sg = ts; e = te; sig = tsig; {z, n, inf} = flags; #10;
      ref_model;
      ok = (pk === known) && (pk === e_pk);
      tally(ok);
      $display("   %s  %b %5d %h %b%b%b | %h | %h | %s  %0s", fmt, sg, e, sig, z, n, inf, pk, known, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_output_finalize  (MPFMA-DS-001 9.5 Output Finalizing)",
           "pack {sign, exp+bias, mantissa} per format; NaN/Inf/overflow/zero/subnormal handling");

    section("directed tests: hand-known encodings (flags = zero,nan,inf)");
    $display("      format  s   exp sig    znI | packed   | known    | result");
    directed("       HP", `CLS_16, 5, 0,   0, 24'h800000, 3'b000, 32'h3C00, "1.0");
    directed("       HP", `CLS_16, 5, 1,   1, 24'hA00000, 3'b000, 32'hC100, "-2.5");
    directed("       HP", `CLS_16, 5, 0,  15, 24'hFFE000, 3'b000, 32'h7BFF, "max normal 65504");
    directed("       HP", `CLS_16, 5, 0,  16, 24'h800000, 3'b000, 32'h7C00, "overflow -> +Inf");
    directed("       HP", `CLS_16, 5, 1,   0, 24'h000000, 3'b001, 32'hFC00, "-Inf");
    directed("       HP", `CLS_16, 5, 0,   0, 24'h000000, 3'b010, 32'h7C01, "NaN");
    directed("       HP", `CLS_16, 5, 0,   0, 24'h000000, 3'b100, 32'h0000, "zero");
    directed("       HP", `CLS_16, 5, 0, -15, 24'h800000, 3'b000, 32'h0200, "subnormal 2^-15");
    directed("       HP", `CLS_16, 5, 0, -24, 24'h800000, 3'b000, 32'h0001, "min subnormal 2^-24");
    directed("       SP", `CLS_32, 8, 0,   0, 24'h800000, 3'b000, 32'h3F800000, "1.0");
    directed("       SP", `CLS_32, 8, 1,   1, 24'hA00000, 3'b000, 32'hC0200000, "-2.5");
    directed("       SP", `CLS_32, 8, 0,   1, 24'hC90FDB, 3'b000, 32'h40490FDB, "pi");
    directed("       SP", `CLS_32, 8, 0,-149, 24'h800000, 3'b000, 32'h00000001, "min subnormal 2^-149");
    directed("       SP", `CLS_32, 8, 0, 128, 24'h800000, 3'b000, 32'h7F800000, "overflow -> +Inf");
    directed("     E4M3", `CLS_8,  4, 0,   0, 24'h800000, 3'b000, 32'h38, "1.0");
    directed("     E4M3", `CLS_8,  4, 1,   1, 24'h800000, 3'b000, 32'hC0, "-2.0");
    directed("     E5M2", `CLS_8,  5, 0,   0, 24'h800000, 3'b000, 32'h3C, "1.0");
    directed(" BFloat16", `CLS_16, 8, 0,   0, 24'h800000, 3'b000, 32'h3F80, "1.0");
    directed(" BFloat16", `CLS_16, 8, 1,   1, 24'hA00000, 3'b000, 32'hC020, "-2.5");
    directed("DLFloat16", `CLS_16, 6, 0,   0, 24'h800000, 3'b000, 32'h3E00, "1.0");
    directed("     TF32", `CLS_19, 8, 0,   0, 24'h800000, 3'b000, 32'h1FC00, "1.0");
    directed("     TF32", `CLS_19, 8, 1,   1, 24'hA00000, 3'b000, 32'h60100, "-2.5");

    section("random tests: all 7 formats, normal / subnormal / overflow exponents");
    f0 = n_fail;
    for (i = 0; i < 3500; i = i + 1) begin
      case (i % 7)
        0: begin cls = `CLS_8;  ew = 4; end
        1: begin cls = `CLS_8;  ew = 5; end
        2: begin cls = `CLS_16; ew = 5; end
        3: begin cls = `CLS_16; ew = 6; end
        4: begin cls = `CLS_16; ew = 8; end
        5: begin cls = `CLS_32; ew = 8; end
        default: begin cls = `CLS_19; ew = 8; end
      endcase
      total = (cls == `CLS_8) ? 8 : (cls == `CLS_16) ? 16 : (cls == `CLS_32) ? 32 : 19;
      m = total - 1 - ew; bias = (1 << (ew - 1)) - 1;
      sg  = $random(seed);
      e   = ($random(seed) % (2 * bias + m + 6));      // spans subnormal .. overflow
      sig = 24'h800000 | ($random(seed) & ~((24'h1 << (23 - m)) - 1)); // already rounded to m bits
      {z, n, inf} = 3'b000;
      case ($unsigned($random(seed)) % 20)
        0: z = 1; 1: n = 1; 2: inf = 1; default: ;
      endcase
      #10;
      ref_model;
      ok = (pk === e_pk);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL cls=%0d ew=%0d s=%b e=%0d sig=%h znI=%b%b%b got=%h exp=%h", cls, ew, sg, e, sig, z, n, inf, pk, e_pk);
    end
    random_done(3500, f0);

    summary;
  end
endmodule
