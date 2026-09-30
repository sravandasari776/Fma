// tb_stage4_sign_detection.v -- unit test for stage4_sign_detection (9.4).
// Normal result: final sign = sign_incr XOR ref_sign (the anchor's sign,
// flipped if the relative sum came out negative).
// Special results (IEEE 754): NaN -> 0 ; Inf -> inf_sign (sign of the
// infinite term) ; exact zero -> zero_sign (-0 only if every term was -0).
// Exhaustive: all 128 input combinations.
`include "fma_defs.vh"

module tb_stage4_sign_detection;
  parameter TB_NAME = "stage4_sign_detection";
  `include "tb_util.vh"

  reg  si, rs, z, zs, nn, inf, is;
  wire so;
  stage4_sign_detection dut (.sign_incr_i(si), .ref_sign_i(rs), .is_zero_i(z), .zero_sign_i(zs),
                             .is_nan_i(nn), .is_inf_i(inf), .inf_sign_i(is), .sign_o(so));

  reg e_so, ok;
  integer i, f0;

  task show;
    input [8*44-1:0] note;
    begin
      #10;
      e_so = nn ? 1'b0 : inf ? is : z ? zs : (si ^ rs);
      ok = (so === e_so);
      tally(ok);
      $display("      %b     %b    %b   %b    %b   %b    %b  |  %b   |  %b  | %s  %0s",
               si, rs, z, zs, nn, inf, is, so, e_so, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage4_sign_detection  (MPFMA-DS-001 9.4 Sign Detection)",
           "sign = NaN ? 0 : Inf ? inf_sign : zero ? zero_sign : (sign_incr ^ ref_sign)");

    section("directed tests (the meaningful cases)");
    $display("   s_incr ref zero zsgn nan inf isgn | sign | exp | result  meaning");
    {si, rs, z, zs, nn, inf, is} = 7'b0000000; show("anchor +, sum kept anchor's sign");
    {si, rs, z, zs, nn, inf, is} = 7'b0100000; show("anchor -, sum kept anchor's sign");
    {si, rs, z, zs, nn, inf, is} = 7'b1000000; show("anchor +, but the sum flipped negative");
    {si, rs, z, zs, nn, inf, is} = 7'b1100000; show("anchor -, but the sum flipped positive");
    {si, rs, z, zs, nn, inf, is} = 7'b0110000; show("x + (-x) cancels to zero -> +0");
    {si, rs, z, zs, nn, inf, is} = 7'b0111000; show("-0 + (-0)*(+1) -> -0");
    {si, rs, z, zs, nn, inf, is} = 7'b0000011; show("-Inf operand -> -Inf");
    {si, rs, z, zs, nn, inf, is} = 7'b0100010; show("+Inf operand (anchor sign irrelevant) -> +Inf");
    {si, rs, z, zs, nn, inf, is} = 7'b1100100; show("NaN -> canonical +NaN");

    section("exhaustive tests (all 128 combinations)");
    f0 = n_fail;
    for (i = 0; i < 128; i = i + 1) begin
      {si, rs, z, zs, nn, inf, is} = i;
      #10;
      e_so = nn ? 1'b0 : inf ? is : z ? zs : (si ^ rs);
      ok = (so === e_so);
      tally(ok);
      if (!ok) $display("   FAIL inputs=%b got=%b exp=%b", i[6:0], so, e_so);
    end
    random_done(128, f0);

    summary;
  end
endmodule
