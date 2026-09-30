// tb_stage1_comparator.v -- unit test for stage1_comparator (6.6).
// Picks the largest exponent among the addend and the valid, non-zero
// product lanes. label_sel = 0..3 (product lane) or 4 (addend).
// Rules checked: invalid lanes and zero terms are ignored; on a tie the
// addend (or the lower-numbered lane) keeps the win; if every term is zero
// the addend is returned.
`include "fma_defs.vh"

module tb_stage1_comparator;
  parameter TB_NAME = "stage1_comparator";
  `include "tb_util.vh"

  reg  [`NLANE*`EXPW-1:0] pexp;
  reg  [`NLANE-1:0]       valid, pzero;
  reg  signed [`EXPW-1:0] aexp;
  reg                     azero;
  wire signed [`EXPW-1:0] exp_sel;
  wire [2:0]              label;

  stage1_comparator dut (
      .prod_exp_i(pexp), .lane_valid_i(valid), .prod_zero_i(pzero),
      .a_exp_i(aexp), .a_zero_i(azero),
      .exp_sel_o(exp_sel), .label_sel_o(label)
  );

  reg signed [`EXPW-1:0] best, e_exp, pe;
  reg [2:0] e_lab;
  reg found, ok;
  integer i, k, f0;

  // reference: straightforward "largest non-zero valid term" search
  task ref_model;
    begin
      found = !azero;
      best  = aexp;
      e_lab = 3'd4;
      for (k = 0; k < `NLANE; k = k + 1) begin
        pe = pexp[`EXPW*k +: `EXPW];
        if (valid[k] && !pzero[k] && (!found || pe > best)) begin
          best = pe; e_lab = k; found = 1'b1;
        end
      end
      e_exp = found ? best : aexp;
    end
  endtask

  task directed;
    input signed [`EXPW-1:0] e0, e1, e2, e3, ea;
    input [3:0] v, z;
    input za;
    input [8*40-1:0] note;
    begin
      pexp = {e3, e2, e1, e0}; valid = v; pzero = z; aexp = ea; azero = za;
      #10;
      ref_model;
      ok = (exp_sel === e_exp) && (label === e_lab);
      tally(ok);
      $display("   %4d %4d %4d %4d | %b  %b | %4d %b  | %4d  %0d  | %4d  %0d  | %s  %0s",
               e0, e1, e2, e3, v, z, ea, za, exp_sel, label, e_exp, e_lab, pf(ok), note);
    end
  endtask

  initial begin
    banner("stage1_comparator  (MPFMA-DS-001 6.6 Comparator)",
           "select the largest exponent among addend + valid non-zero products; label 0..3 = lane, 4 = addend");

    section("directed tests");
    $display("   product exp lane0..3 | valid zero | a_exp az | got  lbl | exp  lbl | result");
    directed(  3,   5,  -2,   1,    4, 4'b1111, 4'b0000, 0, "lane 1 has the largest exponent");
    directed(  3,   5,  -2,   1,   10, 4'b1111, 4'b0000, 0, "addend dominates");
    directed(  3,   5,  -2,  20,    4, 4'b0111, 4'b0000, 0, "lane 3 (exp 20) is NOT valid");
    directed(  0,   0,   0,   0,  -10, 4'b0001, 4'b0001, 0, "zero product must not beat tiny addend");
    directed(  0,   0,   0,   0,    7, 4'b1111, 4'b1111, 1, "everything zero -> addend");
    directed(  4,   0,   0,   0,    4, 4'b0001, 4'b0000, 0, "tie -> addend keeps the win");
    directed(-20,  -3,  -7,-100,    0, 4'b1111, 4'b0000, 1, "negative exps, addend zero");
    directed(  6,   6,   2,   2,    0, 4'b0011, 4'b0000, 1, "tie between lanes -> lower lane");

    section("random tests");
    f0 = n_fail;
    for (i = 0; i < 2000; i = i + 1) begin
      for (k = 0; k < `NLANE; k = k + 1)
        pexp[`EXPW*k +: `EXPW] = ($random(seed) % 200);
      aexp  = $random(seed) % 200;
      valid = $random(seed);
      pzero = $random(seed) & $random(seed);
      azero = ($random(seed) % 4 == 0);
      #10;
      ref_model;
      ok = (exp_sel === e_exp) && (label === e_lab);
      tally(ok);
      if (!ok && n_fail - f0 <= 10)
        $display("   FAIL pexp=%h v=%b z=%b a=%0d az=%b got=%0d/%0d exp=%0d/%0d",
                 pexp, valid, pzero, aexp, azero, exp_sel, label, e_exp, e_lab);
    end
    random_done(2000, f0);

    summary;
  end
endmodule
