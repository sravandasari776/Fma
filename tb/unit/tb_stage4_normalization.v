// tb_stage4_normalization.v -- unit test for stage4_normalization (9.1).
// Uses the LZAU's exp_adjust to bring the leading '1' back to bit MSBPOS=71:
//   shift >= 0 : right shift, extra_sticky = OR of bits lost
//   shift <  0 : left shift (no bits lost, sticky = 0)
// ...except that the result exponent (ref_exp + shift) may not go below
// the output format's emin = 1 - bias(ew): then the shift used is
// (emin - ref_exp) instead, leaving a subnormal (leading '1' below bit 71).
// exp_adjust_o must report the shift actually used.
`include "fma_defs.vh"

module tb_stage4_normalization;
  parameter TB_NAME = "stage4_normalization";
  `include "tb_util.vh"

  reg  [`WW-1:0]          mag;
  reg  signed [`EXPW-1:0] adj, ref_e;
  reg  [3:0]              ew;
  wire [`WW-1:0]          norm;
  wire                    xst;
  wire signed [`EXPW-1:0] adj_used;
  stage4_normalization dut (.magnitude_i(mag), .exp_adjust_i(adj), .ref_exp_i(ref_e), .ew_i(ew),
                            .normalized_o(norm), .extra_sticky_o(xst), .exp_adjust_o(adj_used));

  localparam [`WW-1:0] ONE = {{(`WW-1){1'b0}}, 1'b1} << `MSBPOS;

  reg [`WW+127:0] full;
  reg [`WW-1:0]   e_norm, bitp;
  reg             e_st, ok;
  integer         emin, e_adj, sh, p, i, f0;

  task ref_model;
    begin
      emin  = 2 - (1 << (ew - 1));            // 1 - bias
      e_adj = (ref_e + adj < emin) ? emin - ref_e : adj;
      if (e_adj >= 0) begin
        sh     = (e_adj > 127) ? 127 : e_adj;
        full   = {mag, 128'b0} >> sh;
        e_norm = full[`WW+127:128];
        e_st   = |full[127:0];
      end else begin
        e_norm = mag << (-e_adj);
        e_st   = 1'b0;
      end
    end
  endtask

  task check;
    begin
      #10;
      ref_model;
      ok = (norm === e_norm) && (xst === e_st) && (adj_used === e_adj);
      tally(ok);
    end
  endtask

  task directed;
    input [`WW-1:0] tm;
    input signed [`EXPW-1:0] ta, tr;
    input [3:0] tew;
    input [8*44-1:0] note;
    begin
      mag = tm; adj = ta; ref_e = tr; ew = tew;
      check;
      $display("   %h %4d %5d %0d | %h %b %4d | %h %b %4d | %s  %0s",
               mag, adj, ref_e, ew, norm, xst, adj_used, e_norm, e_st, e_adj, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_normalization  (MPFMA-DS-001 9.1 Normalization)",
           "shift the leading 1 to bit 71 (right: +sticky, left: cancellation), but never below emin -> subnormal");

    section("directed tests (ew=8: emin=-126, ew=5: emin=-14)");
    $display("   magnitude            adj  ref_e ew | normalized        st used | expected          st used | result");
    directed(ONE,                  0,    0, 8, "already normalized");
    directed(ONE << 1,             1,    0, 8, "2.0 -> shift right 1");
    directed((ONE << 1) | 1,       1,    0, 8, "right shift loses a 1 -> sticky");
    directed(ONE << 3 | 4,         3,    0, 8, "right shift 3");
    directed(ONE >> 6,            -6,    0, 8, "cancellation: shift left 6");
    directed(1,                  -71,    0, 8, "LSB only: shift left 71");
    directed(ONE >> 3,            -3,  -14, 5, "HP: below emin -> no shift (subnormal)");
    directed(ONE >> 3,            -3,  -12, 5, "HP: left shift limited to 2");
    directed(ONE,                  0,  -20, 5, "HP: 2^-20 -> right shift 6 (deep subnormal)");
    directed(ONE | 1,              0, -200, 5, "far below the subnormal range -> all sticky");

    section("random tests A: normal range, adj = leading-one position - 71 (as the LZAU gives)");
    f0 = n_fail;
    ew = 8; ref_e = 0;
    for (p = 0; p < `WW; p = p + 1) begin
      for (i = 0; i < 25; i = i + 1) begin
        // random magnitude whose leading '1' is at bit p
        if (p >= `MSBPOS) bitp = ONE << (p - `MSBPOS);
        else              bitp = ONE >> (`MSBPOS - p);
        mag = ({$random(seed), $random(seed), $random(seed)} & (bitp - 1)) | bitp;
        adj = p - `MSBPOS;
        check;
        ok = ok && norm[`MSBPOS] && (norm[`WW-1:`MSBPOS+1] == 0);
        if (!ok && n_fail - f0 <= 10)
          $display("   FAIL mag=%h adj=%0d got=%h/%b exp=%h/%b", mag, adj, norm, xst, e_norm, e_st);
      end
    end
    random_done(`WW * 25, f0);

    section("random tests B: random ref_exp / ew, subnormal limiting");
    f0 = n_fail;
    for (i = 0; i < 1000; i = i + 1) begin
      mag   = {$random(seed), $random(seed), $random(seed)} >> ($unsigned($random(seed)) % `WW);
      adj   = ($unsigned($random(seed)) % 75) - 71;
      ref_e = ($unsigned($random(seed)) % 400) - 300;
      ew    = 4 + $unsigned($random(seed)) % 5;
      check;
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL mag=%h adj=%0d ref=%0d ew=%0d got=%h/%b/%0d exp=%h/%b/%0d",
                 mag, adj, ref_e, ew, norm, xst, adj_used, e_norm, e_st, e_adj);
    end
    random_done(1000, f0);

    summary;
  end
endmodule
