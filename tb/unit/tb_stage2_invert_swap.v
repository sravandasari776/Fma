// tb_stage2_invert_swap.v -- unit test for stage2_invert_swap (7.3).
// All terms are brought to the sign of the "anchor" term (label_sel from
// the Comparator: 0..3 = product lane, 4 = addend):
//   ref_sign = sign of the anchor
//   a term whose sign differs from ref_sign (and is non-zero) is bit-
//   inverted (1's complement); invalid product lanes are forced to 0
//   neg_count = number of inverted terms whose alignment was EXACT
//               (sticky=0) -- the "+1" of each two's-complement negation,
//               added once later in the CSA tree
`include "fma_defs.vh"

module tb_stage2_invert_swap;
  parameter TB_NAME = "stage2_invert_swap";
  `include "tb_util.vh"

  reg  [`WW-1:0]        a_al;
  reg                   a_sg, a_st;
  reg  [`NLANE*`WW-1:0] p_al;
  reg  [`NLANE-1:0]     p_sg, valid, p_st;
  reg  [2:0]            label;
  wire [`WW-1:0]        a_term;
  wire [`NLANE*`WW-1:0] p_term;
  wire [2:0]            negc;
  wire                  rsign;

  stage2_invert_swap dut (
      .a_aligned_i(a_al), .a_sign_i(a_sg), .a_sticky_i(a_st),
      .prod_aligned_i(p_al), .prod_sign_i(p_sg), .lane_valid_i(valid), .prod_sticky_i(p_st),
      .label_sel_i(label),
      .a_term_o(a_term), .prod_term_o(p_term), .neg_count_o(negc), .ref_sign_o(rsign)
  );

  reg                   e_rs;
  reg  [`WW-1:0]        e_a, pl;
  reg  [`NLANE*`WW-1:0] e_p;
  integer               e_n, k, i, f0;
  reg ok, inv;

  task ref_model;
    begin
      e_rs = (label == 3'd4) ? a_sg : p_sg[label];
      inv  = (a_al != 0) && (a_sg != e_rs);
      e_a  = inv ? ~a_al : a_al;
      e_n  = (inv && !a_st) ? 1 : 0;
      for (k = 0; k < `NLANE; k = k + 1) begin
        pl  = p_al[`WW*k +: `WW];
        inv = valid[k] && (pl != 0) && (p_sg[k] != e_rs);
        e_p[`WW*k +: `WW] = !valid[k] ? 0 : (inv ? ~pl : pl);
        if (inv && !p_st[k]) e_n = e_n + 1;
      end
    end
  endtask

  task check;
    begin
      #10;
      ref_model;
      ok = (rsign === e_rs) && (a_term === e_a) && (p_term === e_p) && (negc === e_n);
      tally(ok);
    end
  endtask

  task directed;
    input [8*44-1:0] note;
    begin
      check;
      $display("   %0d  %b%b%b%b%b  %b    %b    %b | %b  %h %h %h  %0d | %b  %0d | %s  %0s",
               label, a_sg, p_sg[0], p_sg[1], p_sg[2], p_sg[3], valid, p_st, a_st,
               rsign, a_term, p_term[39:0], p_term[79:40], negc, e_rs, e_n, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage2_invert_swap  (MPFMA-DS-001 7.3 Invert/Swap)",
           "invert (1's compl.) every non-zero term whose sign != anchor sign; neg_count = # exact inverted terms");

    section("directed tests (1.0 = 10_0000_0000 in the 40-bit frame; p0/p1 terms shown)");
    $display("   lbl sA s0..3 valid p_st a_st | rs a_term     p0_term    p1_term   ncnt | exp rs ncnt | result");
    a_al = 40'h10_0000_0000; p_al = {4{40'h08_0000_0000}};
    a_st = 0; p_st = 0; valid = 4'b0001;

    label = 4; a_sg = 0; p_sg = 4'b0000; directed("all positive: nothing inverted");
    label = 4; a_sg = 0; p_sg = 4'b0001; directed("A=+1.0, P0=-0.5: P0 inverted, ncnt=1");
    label = 0; a_sg = 0; p_sg = 4'b0001; directed("anchor = P0 (neg): A inverted instead");
    label = 4; a_sg = 1; p_sg = 4'b0000; directed("anchor A negative, P0 positive");
    label = 4; a_sg = 0; p_sg = 4'b0001; p_st = 4'b0001;
                                          directed("P0 inverted but inexact: no +1");
    p_st = 0; valid = 4'b0011; p_sg = 4'b0010;
                                          directed("two lanes, P1 negative");
    valid = 4'b0001; p_sg = 4'b0010;      directed("P1 invalid -> forced to 0");
    a_al = 0; a_sg = 1; label = 0; p_sg = 4'b0000;
                                          directed("zero addend never inverted");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      a_al  = ($random(seed) % 4 == 0) ? 0 : {$random(seed), $random(seed)};
      p_al  = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
      if (i % 5 == 0) p_al[`WW +: `WW] = 0;
      a_sg  = $random(seed); a_st = $random(seed);
      p_sg  = $random(seed); p_st = $random(seed); valid = $random(seed);
      label = $random(seed) % 5;
      if (label > 4) label = 4;
      check;
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL lbl=%0d sA=%b sP=%b v=%b got rs=%b n=%0d exp rs=%b n=%0d",
                 label, a_sg, p_sg, valid, rsign, negc, e_rs, e_n);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
