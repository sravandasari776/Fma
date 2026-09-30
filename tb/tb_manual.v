// tb_manual.v
// ONE operation through the real RTL, driven by a pure-Verilog testbench.
//
// There is no Python here and no expected answer anywhere: the inputs come
// from the simulator command line (plusargs), and the only thing that can
// produce the printed result is fma_top. The testbench prints dout_o after
// every clock edge (the result appears 3 edges after the inputs, because
// of the 3 pipeline registers) and, for lane 0, values read directly from
// inside the RTL's pipeline stages while the operation passes through.
//
// Plusargs (run through tb/run_manual.sh):
//   +MIX=0|1  +PRA=n +PRM=n (0=8-bit 1=16-bit 2=SP 3=TF32)  +EWA=n +EWM=n (4..8)
//   +A=hex +B=hex +C=hex   (the a_i/b_i/c_i bus values, lanes packed in the low 32 bits)
`include "fma_defs.vh"

module tb_manual;
  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  reg  [63:0]  a_i, b_i, c_i;
  reg          mixmode_i;
  reg  [1:0]   pra_i, prm_i;
  reg  [3:0]   ewa_i, ewm_i;
  wire [127:0] dout_o;

  fma_top dut (
      .clk_i(clk), .rst_n_i(rst_n),
      .a_i(a_i), .b_i(b_i), .c_i(c_i),
      .mixmode_i(mixmode_i), .pra_i(pra_i), .prm_i(prm_i),
      .ewa_i(ewa_i), .ewm_i(ewm_i),
      .dout_o(dout_o)
  );

  integer mix, pra, prm, ewa, ewm, k, nprod;
  reg [63:0] a, b, c;

  initial begin
    mix = 0; pra = 2; prm = 2; ewa = 8; ewm = 8; a = 0; b = 0; c = 0;
    if (!$value$plusargs("MIX=%d", mix)) $display("note: +MIX not given, using 0");
    if (!$value$plusargs("PRA=%d", pra)) $display("note: +PRA not given, using 2 (SP)");
    if (!$value$plusargs("PRM=%d", prm)) prm = pra;
    if (!$value$plusargs("EWA=%d", ewa)) $display("note: +EWA not given, using 8");
    if (!$value$plusargs("EWM=%d", ewm)) ewm = ewa;
    if (!$value$plusargs("A=%h", a)) $display("note: +A not given, using 0");
    if (!$value$plusargs("B=%h", b)) $display("note: +B not given, using 0");
    if (!$value$plusargs("C=%h", c)) $display("note: +C not given, using 0");

    // reset: all pipeline registers cleared
    a_i = 0; b_i = 0; c_i = 0; mixmode_i = 0; pra_i = 0; prm_i = 0; ewa_i = 4; ewm_i = 4;
    repeat (2) @(posedge clk);
    #1 rst_n = 1;

    // apply the operation and hold it
    a_i = a; b_i = b; c_i = c;
    mixmode_i = mix[0]; pra_i = pra[1:0]; prm_i = prm[1:0]; ewa_i = ewa[3:0]; ewm_i = ewm[3:0];

    $display("");
    $display("=====================================================================");
    $display(" U_FMA manual run -- pure Verilog testbench, no expected answer given");
    $display("=====================================================================");
    $display(" inputs applied to fma_top at time %0t:", $time);
    $display("   mixmode_i=%0d  pra_i=%0d  prm_i=%0d  ewa_i=%0d  ewm_i=%0d", mixmode_i, pra_i, prm_i, ewa_i, ewm_i);
    $display("   a_i=%016h  b_i=%016h  c_i=%016h", a_i, b_i, c_i);
    #1;
    $display("");
    // products that lane 0's pipe actually adds: 1 in multiple-precision
    // mode, 4 (8-bit) or 2 (16-bit) in mixed-precision mode
    nprod = !mix ? 1 : (prm == 0) ? 4 : (prm == 1) ? 2 : 1;
    $display(" inside the RTL, stage 1 (combinational, before the first clock edge), lane 0:");
    $display("   addend      : sign %b, exponent %0d, significand %h (hidden bit = top bit)",
             dut.a_sign_flat[0], $signed(dut.a_exp_flat[`EXPW-1:0]), dut.a_sig_flat[`SIGW-1:0]);
    for (k = 0; k < nprod; k = k + 1)
      $display("   product %0d   : sign %b, exponent %0d, exact 48-bit significand %h", k,
               dut.prod_sign[k], $signed(dut.prod_exp[`EXPW*k +: `EXPW]), dut.prod_sig[`PSIGW*k +: `PSIGW]);

    @(posedge clk); #1;
    $display("");
    $display(" clock edge 1 (time %0t): dout_o[31:0] = %h   <- still the reset value; operation is now in stage 2", $time, dout_o[31:0]);
    $display("   stage 2 inside the RTL: largest term (anchor) = %0s, anchor exponent %0d",
             (dut.LANEPIPE[0].u_pipe.label_sel_s2 == 3'd4) ? "the addend" : "a product",
             $signed(dut.LANEPIPE[0].u_pipe.ref_exp_s2));
    $display("                           right shifts to line up: addend %0d", dut.LANEPIPE[0].u_pipe.shift_a_s2);
    for (k = 0; k < nprod; k = k + 1)
      $display("                                                    product %0d %0d", k,
               dut.LANEPIPE[0].u_pipe.shift_p_s2[`SHW*k +: `SHW]);
    $display("                           terms bit-inverted because their sign differs: %0d",
             dut.LANEPIPE[0].u_pipe.neg_count_s2);
    $display("                           carry-save sum %h, carry %h",
             dut.LANEPIPE[0].u_pipe.sum_s2, dut.LANEPIPE[0].u_pipe.carry_s2);

    @(posedge clk); #1;
    $display("");
    $display(" clock edge 2 (time %0t): dout_o[31:0] = %h   <- operation is now in stage 3", $time, dout_o[31:0]);
    $display("   stage 3 inside the RTL: added value %h, negative=%b, leading-one adjust %0d",
             dut.LANEPIPE[0].u_pipe.resolved_s3, dut.LANEPIPE[0].u_pipe.sign_s3,
             $signed(dut.LANEPIPE[0].u_pipe.exp_adjust_s3));

    @(posedge clk); #1;
    $display("");
    $display(" clock edge 3 (time %0t): dout_o[31:0] = %h   <- RESULT (stage 4 output)", $time, dout_o[31:0]);
    $display("   stage 4 inside the RTL: normalized %h, rounded significand %h, rounding carry %b,",
             dut.LANEPIPE[0].u_pipe.normalized_s4, dut.LANEPIPE[0].u_pipe.rounded_sig_s4,
             dut.LANEPIPE[0].u_pipe.rnd_ovf_s4);
    $display("                           final exponent %0d, final sign %b, NaN %b, Inf %b",
             $signed(dut.LANEPIPE[0].u_pipe.final_exp_s4), dut.LANEPIPE[0].u_pipe.final_sign_s4,
             dut.LANEPIPE[0].u_pipe.is_nan_r4, dut.LANEPIPE[0].u_pipe.is_inf_r4);
    $display("");
    $display(" RESULT: dout_o[31:0] = %h", dout_o[31:0]);
    $display("=====================================================================");
    $finish;
  end
endmodule
