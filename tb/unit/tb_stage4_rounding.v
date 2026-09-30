// tb_stage4_rounding.v -- unit test for stage4_rounding (9.2).
// Round-to-nearest-even of the normalized value (hidden bit at bit 36) to
// the target format's mantissa width m:
//   keep hidden bit + m bits; look at what is below (guard + rest + the two
//   sticky inputs); round up if > half ULP, or == half ULP and the kept
//   LSB is odd (ties-to-even). A carry out of the top (1.111..1 + ULP)
//   gives rnd_ovf = 1 and significand 1.000..0 (exponent +1 later).
// Output significand is 24 bits, left-justified (hidden bit at [23]).
`include "fma_defs.vh"

module tb_stage4_rounding;
  parameter TB_NAME = "stage4_rounding";
  `include "tb_util.vh"

  reg  [`WW-1:0]   norm;
  reg              st_up, st_nm;
  reg  [31:0]      m;
  wire [`SIGW-1:0] sig;
  wire             ovf;
  stage4_rounding dut (.normalized_i(norm), .sticky_upstream_i(st_up), .sticky_norm_i(st_nm),
                       .m_i(m), .rounded_sig_o(sig), .rnd_ovf_o(ovf));

  // reference model with plain integer arithmetic
  reg [63:0] v, kept, rem, half, k2;
  reg [`SIGW-1:0] e_sig;
  reg e_ovf, up, st, ok;
  integer drop, i, f0;

  task ref_model;
    begin
      v    = norm[`MSBPOS:0];
      drop = `MSBPOS - m;
      kept = v >> drop;
      rem  = v & ((64'd1 << drop) - 1);
      half = 64'd1 << (drop - 1);
      st   = st_up | st_nm;
      up   = (rem > half) || (rem == half && (st || kept[0]));
      k2   = kept + up;
      if (k2 >> (m + 1)) begin e_ovf = 1'b1; e_sig = 24'h800000; end
      else               begin e_ovf = 1'b0; e_sig = k2 << (23 - m); end
    end
  endtask

  task directed;
    input [`WW-1:0] tn;
    input [31:0] tm;
    input tsu, tsn;
    input [8*46-1:0] note;
    begin
      norm = tn; m = tm; st_up = tsu; st_nm = tsn; #10;
      ref_model;
      ok = (sig === e_sig) && (ovf === e_ovf);
      tally(ok);
      $display("   %h %2d  %b %b | %h %b | %h %b | %s  %0s", norm, m, st_up, st_nm, sig, ovf, e_sig, e_ovf, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_rounding  (MPFMA-DS-001 9.2 Rounding)",
           "round-to-nearest-even to m mantissa bits; carry out of the top -> rnd_ovf=1, sig=1.0");

    section("directed tests  (m=10 HP/TF32, m=23 SP, m=3 E4M3)");
    $display("   normalized  m  su sn | sig    ovf | expected ovf | result");
    directed(40'h10_0000_0000, 10, 0, 0, "HP 1.0 exact");
    directed(40'h10_0200_0000, 10, 0, 0, "HP 1.0 + half ULP: tie, even -> down");
    directed(40'h10_0600_0000, 10, 0, 0, "HP 1+1ULP + half: tie, odd -> up");
    directed(40'h10_0200_0000, 10, 1, 0, "HP 1.0 + half + upstream sticky -> up");
    directed(40'h10_01FF_FFFF, 10, 0, 0, "HP just below half -> down");
    directed(40'h1F_FE00_0000, 10, 0, 0, "HP 1.11..1 + half -> overflow");
    directed(40'h10_0000_1000, 23, 0, 0, "SP 1.0 + half ULP: tie, even -> down");
    directed(40'h10_0000_1000, 23, 0, 1, "SP same + normalization sticky -> up");
    directed(40'h10_0000_3000, 23, 0, 0, "SP odd LSB + half -> up");
    directed(40'h11_0000_0000,  3, 0, 0, "E4M3 1.0 + half ULP -> down (even)");
    directed(40'h13_0000_0000,  3, 0, 0, "E4M3 1.125 + half ULP -> 1.25");

    section("random tests: m in {2,3,7,9,10,23} (E5M2,E4M3,BF16,DLF16,HP/TF32,SP)");
    f0 = n_fail;
    for (i = 0; i < 6000; i = i + 1) begin
      case (i % 6)
        0: m = 2; 1: m = 3; 2: m = 7; 3: m = 9; 4: m = 10; default: m = 23;
      endcase
      norm  = {$random(seed), $random(seed)};
      norm[`WW-1:`MSBPOS] = 4'b0001;               // normalized input
      if (i % 3 == 0) norm = norm & ~((40'h1 << (`MSBPOS - m - 1)) - 1); // clear below guard: exact ties common
      st_up = ($random(seed) % 4 == 0);
      st_nm = ($random(seed) % 4 == 0);
      #10;
      ref_model;
      ok = (sig === e_sig) && (ovf === e_ovf);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL norm=%h m=%0d su=%b sn=%b got=%h/%b exp=%h/%b", norm, m, st_up, st_nm, sig, ovf, e_sig, e_ovf);
    end
    random_done(6000, f0);

    summary;
  end
endmodule
