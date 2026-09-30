// tb_stage4_sign_detection.v -- unit test for stage4_sign_detection (9.4).
// final sign = sign_incr XOR ref_sign (anchor's sign, flipped if the
// relative sum came out negative); an exact zero result is always +0.
// Exhaustive: all 8 input combinations.
`include "fma_defs.vh"

module tb_stage4_sign_detection;
  parameter TB_NAME = "stage4_sign_detection";
  `include "tb_util.vh"

  reg  si, rs, z;
  wire so;
  stage4_sign_detection dut (.sign_incr_i(si), .ref_sign_i(rs), .is_zero_i(z), .sign_o(so));

  reg e_so, ok;
  integer i;

  initial begin
    banner("stage4_sign_detection  (MPFMA-DS-001 9.4 Sign Detection)",
           "sign = is_zero ? 0 : (sign_incr ^ ref_sign)");

    section("exhaustive tests");
    $display("   sign_incr ref_sign is_zero | sign | exp | result  meaning");
    for (i = 0; i < 8; i = i + 1) begin
      {z, rs, si} = i;
      #10;
      e_so = z ? 1'b0 : (si ^ rs);
      ok = (so === e_so);
      tally(ok);
      $display("       %b        %b        %b    |  %b   |  %b  | %s  %0s", si, rs, z, so, e_so, pf(ok),
               z ? "exact zero -> +0" :
               (!si && !rs) ? "anchor +, sum kept anchor's sign" :
               (!si &&  rs) ? "anchor -, sum kept anchor's sign" :
               ( si && !rs) ? "anchor +, but the sum flipped negative" :
                              "anchor -, but the sum flipped positive");
    end

    summary;
  end
endmodule
