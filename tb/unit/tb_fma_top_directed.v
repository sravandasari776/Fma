// tb_fma_top_directed.v -- small, human-readable directed test of the full
// fma_top (all 4 stages, 3 pipeline registers -> result 3 clocks later).
// Every case uses simple values (1.0, 2.0, -2.5, ...) so the expected
// answer can be worked out by hand; each expected value was also confirmed
// with tb/golden_model.py. For the full 925-vector regression use
// tb/tb_fma_top.v (run_sim.sh / run_vcs.sh).
//
// Packing reminder: lanes sit in the low 32 bits of a/b/c/dout
//   8-bit class : 4 byte lanes    {L3,L2,L1,L0}
//   16-bit class: 2 halfword lanes {L1,L0}
//   SP / TF32   : 1 lane
// Mixed precision (mix=1): a = one higher-precision addend, b/c = the
// lower-precision dot-product operands, dout = A + sum(Bi*Ci).
`include "fma_defs.vh"

module tb_fma_top_directed;
  parameter TB_NAME = "fma_top_directed";
  `include "tb_util.vh"

  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  reg  [63:0]  a, b, c;
  reg          mix;
  reg  [1:0]   pra, prm;
  reg  [3:0]   ewa, ewm;
  wire [127:0] dout;

  fma_top dut (
      .clk_i(clk), .rst_n_i(rst_n), .a_i(a), .b_i(b), .c_i(c),
      .mixmode_i(mix), .pra_i(pra), .prm_i(prm), .ewa_i(ewa), .ewm_i(ewm), .dout_o(dout)
  );

  localparam NV = 18;
  reg [8*52-1:0] v_note [0:NV-1];
  reg [8*15-1:0] v_fmt  [0:NV-1];
  reg [63:0] v_a [0:NV-1], v_b [0:NV-1], v_c [0:NV-1];
  reg [31:0] v_exp [0:NV-1];
  reg        v_mix [0:NV-1];
  reg [1:0]  v_pra [0:NV-1], v_prm [0:NV-1];
  reg [3:0]  v_ewa [0:NV-1], v_ewm [0:NV-1];
  integer nv;

  task vec;
    input [8*15-1:0] fmt;
    input tmix;
    input [1:0] tpra, tprm;
    input [3:0] tewa, tewm;
    input [31:0] ta, tb_, tc, texp;
    input [8*52-1:0] note;
    begin
      v_fmt[nv] = fmt; v_mix[nv] = tmix; v_pra[nv] = tpra; v_prm[nv] = tprm;
      v_ewa[nv] = tewa; v_ewm[nv] = tewm;
      v_a[nv] = ta; v_b[nv] = tb_; v_c[nv] = tc; v_exp[nv] = texp; v_note[nv] = note;
      nv = nv + 1;
    end
  endtask

  task drive;
    input integer k;
    begin
      a = v_a[k]; b = v_b[k]; c = v_c[k]; mix = v_mix[k];
      pra = v_pra[k]; prm = v_prm[k]; ewa = v_ewa[k]; ewm = v_ewm[k];
    end
  endtask

  reg ok;
  integer k, cyc;

  initial begin
    banner("fma_top  (full U_FMA, directed hand-checkable cases; 3-cycle latency)",
           "dout = A + B*C per lane (multiple-precision)  or  A + sum(Bi*Ci) (mixed-precision), one rounding");

    nv = 0;
    //   format           mix pra      prm      ewa ewm  a            b            c            expected
    vec("HP x2 lanes",    0, `CLS_16, `CLS_16, 5, 5, 32'h3800_3C00, 32'h4000_3C00, 32'h4200_3C00, 32'h4680_4000,
        "L0: 1+1*1=2.0   L1: 0.5+2*3=6.5");
    vec("E4M3 x4 lanes",  0, `CLS_8,  `CLS_8,  4, 4, 32'h00_38_00_38, 32'h3C_B8_40_38, 32'h40_38_40_38, 32'h44_00_48_40,
        "L0: 1+1*1=2  L1: 0+2*2=4  L2: 1-1*1=0  L3: 0+1.5*2=3");
    vec("E5M2 x4 lanes",  0, `CLS_8,  `CLS_8,  5, 5, 32'h3C3C3C3C, 32'h3C3C3C3C, 32'h3C3C3C3C, 32'h40404040,
        "every lane: 1+1*1 = 2.0");
    vec("BFloat16 x2",    0, `CLS_16, `CLS_16, 8, 8, 32'hC020_3F80, 32'h3F80_3F80, 32'h3F80_3F80, 32'hBFC0_4000,
        "L0: 1+1*1=2.0   L1: -2.5+1*1=-1.5");
    vec("DLFloat16 x2",   0, `CLS_16, `CLS_16, 6, 6, 32'h3E00_3E00, 32'h3E00_3E00, 32'h3E00_3E00, 32'h4000_4000,
        "both lanes: 1+1*1 = 2.0");
    vec("SP",             0, `CLS_32, `CLS_32, 8, 8, 32'h3FC00000, 32'h40000000, 32'h40400000, 32'h40F00000,
        "1.5 + 2.0*3.0 = 7.5");
    vec("TF32",           0, `CLS_19, `CLS_19, 8, 8, 32'h0001FC00, 32'h0001FC00, 32'h00060100, 32'h0005FE00,
        "1.0 + 1.0*(-2.5) = -1.5");
    vec("SP",             0, `CLS_32, `CLS_32, 8, 8, 32'h3F800000, 32'h3F800001, 32'h3F800001, 32'h40000001,
        "1 + (1+2^-23)^2 : sticky bits round up");
    vec("HP",             0, `CLS_16, `CLS_16, 5, 5, 32'h00003C00, 32'h00001000, 32'h00003C00, 32'h00003C00,
        "1.0 + 2^-11*1 : exact half-ULP tie -> even (1.0)");
    vec("HP",             0, `CLS_16, `CLS_16, 5, 5, 32'h00003C01, 32'h00001000, 32'h00003C00, 32'h00003C02,
        "(1+2^-10) + 2^-11 : tie, odd LSB -> round up");
    vec("SP",             0, `CLS_32, `CLS_32, 8, 8, 32'h3F800000, 32'h7F800000, 32'h3F800000, 32'h7F800000,
        "1 + Inf*1 = +Inf");
    vec("SP",             0, `CLS_32, `CLS_32, 8, 8, 32'h3F800000, 32'h7F800000, 32'h00000000, 32'h7F800001,
        "1 + Inf*0 = NaN");
    vec("SP",             0, `CLS_32, `CLS_32, 8, 8, 32'h40400000, 32'hBF800000, 32'h40400000, 32'h00000000,
        "3 + (-1)*3 = +0 (exact cancellation)");
    vec("MIX SP+4xE4M3",  1, `CLS_32, `CLS_8,  8, 4, 32'h3F800000, 32'h38383838, 32'h38383838, 32'h40A00000,
        "1.0 + (1*1 + 1*1 + 1*1 + 1*1) = 5.0");
    vec("MIX HP+4xE4M3",  1, `CLS_16, `CLS_8,  5, 4, 32'h00003C00, 32'h38384038, 32'h38384038, 32'h00004800,
        "1.0 + (1 + 2*2 + 1 + 1) = 8.0");
    vec("MIX SP+2xHP",    1, `CLS_32, `CLS_16, 8, 5, 32'h3F800000, 32'hBC00_3C00, 32'h3800_4000, 32'h40200000,
        "1.0 + (1*2 + (-1)*0.5) = 2.5");
    vec("MIX BF16+4xE4M3",1, `CLS_16, `CLS_8,  8, 4, 32'h00003F80, 32'h38383838, 32'h38383838, 32'h000040A0,
        "1.0 + 4 x (1*1) = 5.0 in BFloat16");
    vec("MIX SP+4xE5M2",  1, `CLS_32, `CLS_8,  8, 5, 32'hBF800000, 32'h3C3C3C3C, 32'h3C3C3C3C, 32'h40400000,
        "-1.0 + 4 x (1*1) = 3.0");

    drive(0);
    repeat (2) @(posedge clk);
    rst_n = 1;

    section("part 1: one operation at a time (apply inputs, wait 3 clocks, read dout[31:0])");
    $display("   format          | a        b        c        | dout     | expected | result  meaning");
    for (k = 0; k < nv; k = k + 1) begin
      drive(k);
      repeat (3) @(posedge clk);
      #1;
      ok = (dout[31:0] === v_exp[k]);
      tally(ok);
      $display("   %s | %h %h %h | %h | %h | %s  %0s", v_fmt[k], v_a[k][31:0], v_b[k][31:0], v_c[k][31:0],
               dout[31:0], v_exp[k], pf(ok), v_note[k]);
    end

    section("part 2: same operations issued back-to-back, one per clock (pipelined)");
    $display("   clock | result of op | dout     | expected | result");
    for (cyc = 0; cyc < nv + 2; cyc = cyc + 1) begin
      if (cyc < nv) drive(cyc);
      @(posedge clk); #1;
      if (cyc >= 2) begin
        ok = (dout[31:0] === v_exp[cyc - 2]);
        tally(ok);
        $display("   %4d  |     %2d       | %h | %h | %s", cyc, cyc - 2, dout[31:0], v_exp[cyc - 2], pf(ok));
      end
    end

    summary;
  end
endmodule
