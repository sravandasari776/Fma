// tb_stage1_unified_extractor.v -- unit test for stage1_unified_extractor (6.1).
// Unpacks the packed a/b/c buses into per-lane sign, true (unbiased)
// exponent and 24-bit unified significand (hidden bit at sig[23]), plus
// zero/NaN/Inf flags. Subnormals must come out renormalized (sig[23]=1,
// exponent lowered accordingly).
//
// Directed cases use well-known encodings of every supported format
// (1.0, -2.5, smallest subnormal, zero, Inf, NaN) so the expected values
// can be checked by hand. The random section decodes every active lane of
// all three operands with an independent reference decoder written here.
`include "fma_defs.vh"

module tb_stage1_unified_extractor;
  parameter TB_NAME = "stage1_unified_extractor";
  `include "tb_util.vh"

  reg  [63:0] a, b, c;
  reg  [1:0]  pra, prm;
  reg  [3:0]  ewa, ewm;
  wire [`NLANE-1:0]       as, bs, cs, az, bz, cz, an, bn, cn, ai, bi, ci;
  wire [`NLANE*`EXPW-1:0] ae, be, ce;
  wire [`NLANE*`SIGW-1:0] asg, bsg, csg;

  stage1_unified_extractor dut (
      .a_i(a), .b_i(b), .c_i(c), .pra_i(pra), .prm_i(prm), .ewa_i(ewa), .ewm_i(ewm),
      .a_sign_o(as), .b_sign_o(bs), .c_sign_o(cs),
      .a_exp_o(ae), .b_exp_o(be), .c_exp_o(ce),
      .a_sig_o(asg), .b_sig_o(bsg), .c_sig_o(csg),
      .a_zero_o(az), .b_zero_o(bz), .c_zero_o(cz),
      .a_nan_o(an), .b_nan_o(bn), .c_nan_o(cn),
      .a_inf_o(ai), .b_inf_o(bi), .c_inf_o(ci)
  );

  // ---------------- reference decoder ----------------
  reg              r_s, r_z, r_n, r_i;
  reg signed [`EXPW-1:0] r_e;
  reg [`SIGW-1:0]  r_sig;
  reg [31:0]       lv;
  integer total, ew, m, bias, ef, mf, k, p;

  function integer total_of;
    input [1:0] cls;
    begin
      case (cls)
        `CLS_8: total_of = 8; `CLS_16: total_of = 16; `CLS_32: total_of = 32; default: total_of = 19;
      endcase
    end
  endfunction

  function integer lanes_of;
    input [1:0] cls;
    begin
      case (cls)
        `CLS_8: lanes_of = 4; `CLS_16: lanes_of = 2; default: lanes_of = 1;
      endcase
    end
  endfunction

  // value of lane l of a packed bus
  function [31:0] lane_of;
    input [63:0] bus;
    input [1:0]  cls;
    input integer l;
    begin
      case (cls)
        `CLS_8:  lane_of = (bus >> (8 * l))  & 32'hFF;
        `CLS_16: lane_of = (bus >> (16 * l)) & 32'hFFFF;
        `CLS_32: lane_of = bus[31:0];
        default: lane_of = bus[18:0];
      endcase
    end
  endfunction

  task ref_decode;
    input [31:0] v;
    input [1:0]  cls;
    input [3:0]  e_w;
    begin
      total = total_of(cls); ew = e_w; m = total - 1 - ew; bias = (1 << (ew - 1)) - 1;
      r_s = v[total - 1];
      ef  = (v >> m) & ((1 << ew) - 1);
      mf  = v & ((1 << m) - 1);
      r_z = 0; r_n = 0; r_i = 0; r_e = 0; r_sig = 0;
      if (ef == (1 << ew) - 1) begin          // Inf / NaN
        r_n = (mf != 0);
        r_i = (mf == 0);
      end else if (ef == 0 && mf == 0) begin   // zero
        r_z = 1;
      end else if (ef == 0) begin              // subnormal: renormalize
        r_sig = mf << (23 - m);                // first mantissa bit at sig[22]
        p = 0;
        for (k = 0; k < 24; k = k + 1) if (r_sig[k]) p = k; // highest '1'
        r_sig = r_sig << (23 - p);
        r_e   = 1 - bias - (23 - p);
      end else begin                           // normal
        r_sig = (1 << 23) | (mf << (23 - m));
        r_e   = ef - bias;
      end
    end
  endtask

  // ---------------- compare one lane of one operand ----------------
  reg ok, lane_ok;
  reg g_s, g_z, g_n, g_i;
  reg signed [`EXPW-1:0] g_e;
  reg [`SIGW-1:0] g_sig;

  task get_lane;
    input integer op; // 0=A 1=B 2=C
    input integer l;
    begin
      case (op)
        0: begin g_s = as[l]; g_z = az[l]; g_n = an[l]; g_i = ai[l];
                 g_e = ae[`EXPW*l +: `EXPW]; g_sig = asg[`SIGW*l +: `SIGW]; end
        1: begin g_s = bs[l]; g_z = bz[l]; g_n = bn[l]; g_i = bi[l];
                 g_e = be[`EXPW*l +: `EXPW]; g_sig = bsg[`SIGW*l +: `SIGW]; end
        default: begin g_s = cs[l]; g_z = cz[l]; g_n = cn[l]; g_i = ci[l];
                 g_e = ce[`EXPW*l +: `EXPW]; g_sig = csg[`SIGW*l +: `SIGW]; end
      endcase
    end
  endtask

  task check_lane;
    input integer op;
    input integer l;
    begin
      if (op == 0) begin lv = lane_of(a, pra, l); ref_decode(lv, pra, ewa); end
      else if (op == 1) begin lv = lane_of(b, prm, l); ref_decode(lv, prm, ewm); end
      else begin lv = lane_of(c, prm, l); ref_decode(lv, prm, ewm); end
      get_lane(op, l);
      // exponent/significand are don't-care for Inf/NaN, sign is don't-care for nothing
      lane_ok = (g_s === r_s) && (g_z === r_z) && (g_n === r_n) && (g_i === r_i) &&
                ((r_n || r_i) ? 1'b1 : ((g_e === r_e) && (g_sig === r_sig)));
    end
  endtask

  // directed: check + print every active lane of operand `op`
  task show_op;
    input integer op;
    input [8*9-1:0] fmt;
    input integer nl;
    integer l;
    begin
      for (l = 0; l < nl; l = l + 1) begin
        check_lane(op, l);
        tally(lane_ok);
        $display("   %s %s L%0d  %h | %b %5d %h %b%b%b | %b %5d %h %b%b%b | %s",
                 fmt, (op == 0) ? "A" : (op == 1) ? "B" : "C", l, lv,
                 g_s, g_e, g_sig, g_z, g_n, g_i, r_s, r_e, r_sig, r_z, r_n, r_i, pf(lane_ok));
      end
    end
  endtask

  task cfg;
    input [1:0] tpra, tprm;
    input [3:0] tewa, tewm;
    input [63:0] ta, tb_, tc;
    begin
      pra = tpra; prm = tprm; ewa = tewa; ewm = tewm; a = ta; b = tb_; c = tc;
      #10;
    end
  endtask

  integer i, op, l, f0, nl;

  initial begin
    banner("stage1_unified_extractor  (MPFMA-DS-001 6.1 Sign/Exponent/Mantissa Unified Extractor)",
           "per lane: sign, unbiased exponent, 24-bit significand (hidden bit at [23]), zero/NaN/Inf flags");

    section("directed tests: well-known encodings of each format (flags = zero,nan,inf)");
    $display("   format    op lane raw      | got: s   exp sig    znI | exp: s   exp sig    znI | result");

    // E4M3, 4 byte lanes: 1.0 | -2.0 | smallest subnormal 2^-9 | 0
    cfg(`CLS_8, `CLS_8, 4, 4, 64'h00_01_C0_38, 64'h00_01_C0_38, 64'h00_01_C0_38);
    show_op(1, "E4M3", 4);
    // E5M2: 1.0 | +Inf | NaN | -0
    cfg(`CLS_8, `CLS_8, 5, 5, 64'h80_7E_7C_3C, 64'h80_7E_7C_3C, 64'h80_7E_7C_3C);
    show_op(1, "E5M2", 4);
    // HP (binary16): 1.0 | -2.5 ; then smallest subnormal 2^-24 | +Inf
    cfg(`CLS_16, `CLS_16, 5, 5, 64'hC100_3C00, 64'hC100_3C00, 64'h7C00_0001);
    show_op(1, "HP", 2);
    show_op(2, "HP", 2);
    // DLFloat16: 1.0 | 2.0
    cfg(`CLS_16, `CLS_16, 6, 6, 64'h4000_3E00, 64'h4000_3E00, 64'h4000_3E00);
    show_op(1, "DLFloat16", 2);
    // BFloat16: 1.0 | -2.5
    cfg(`CLS_16, `CLS_16, 8, 8, 64'hC020_3F80, 64'hC020_3F80, 64'hC020_3F80);
    show_op(1, "BFloat16", 2);
    // TF32 (19 bits): 1.0 ; -2.5
    cfg(`CLS_19, `CLS_19, 8, 8, 64'h1FC00, 64'h1FC00, 64'h60100);
    show_op(1, "TF32", 1);
    show_op(2, "TF32", 1);
    // SP: 1.0 ; -2.5 ; smallest subnormal 2^-149 ; NaN
    cfg(`CLS_32, `CLS_32, 8, 8, 64'h3F800000, 64'hC0200000, 64'h00000001);
    show_op(0, "SP", 1);
    show_op(1, "SP", 1);
    show_op(2, "SP", 1);
    cfg(`CLS_32, `CLS_32, 8, 8, 64'h7FC00000, 64'h7F800000, 64'h00000000);
    show_op(0, "SP", 1);
    show_op(1, "SP", 1);
    show_op(2, "SP", 1);
    // mixed precision: A is SP, B/C are E4M3
    cfg(`CLS_32, `CLS_8, 8, 4, 64'h40490FDB, 64'h38_40_48_B8, 64'h01_02_04_08);
    show_op(0, "SP(mix)", 1);
    show_op(1, "E4M3(mix)", 4);
    show_op(2, "E4M3(mix)", 4);

    section("random tests: all formats, every active lane of A, B and C");
    f0 = n_fail;
    for (i = 0; i < 2100; i = i + 1) begin
      case (i % 7)
        0: begin pra = `CLS_8;  ewa = 4; end
        1: begin pra = `CLS_8;  ewa = 5; end
        2: begin pra = `CLS_16; ewa = 5; end
        3: begin pra = `CLS_16; ewa = 6; end
        4: begin pra = `CLS_16; ewa = 8; end
        5: begin pra = `CLS_32; ewa = 8; end
        default: begin pra = `CLS_19; ewa = 8; end
      endcase
      case ((i / 7) % 7)
        0: begin prm = `CLS_8;  ewm = 4; end
        1: begin prm = `CLS_8;  ewm = 5; end
        2: begin prm = `CLS_16; ewm = 5; end
        3: begin prm = `CLS_16; ewm = 6; end
        4: begin prm = `CLS_16; ewm = 8; end
        5: begin prm = `CLS_32; ewm = 8; end
        default: begin prm = `CLS_19; ewm = 8; end
      endcase
      a = {$random(seed), $random(seed)};
      b = {$random(seed), $random(seed)};
      c = {$random(seed), $random(seed)};
      // every 4th vector: force small exponents so subnormals get exercised
      if (i % 4 == 0) begin a = a & 64'h8381_8381_8381_8381; b = b & 64'h0381_0381_0381_0381; end
      #10;
      ok = 1'b1;
      for (op = 0; op < 3; op = op + 1) begin
        nl = lanes_of(op == 0 ? pra : prm);
        for (l = 0; l < nl; l = l + 1) begin
          check_lane(op, l);
          if (!lane_ok) begin
            ok = 1'b0;
            if (n_fail - f0 < 10)
              $display("   FAIL op=%0d lane=%0d cls=%0d ew=%0d raw=%h got s=%b e=%0d sig=%h znI=%b%b%b exp s=%b e=%0d sig=%h znI=%b%b%b",
                       op, l, (op == 0) ? pra : prm, (op == 0) ? ewa : ewm, lv,
                       g_s, g_e, g_sig, g_z, g_n, g_i, r_s, r_e, r_sig, r_z, r_n, r_i);
          end
        end
      end
      tally(ok);
    end
    random_done(2100, f0);

    summary;
  end
endmodule
