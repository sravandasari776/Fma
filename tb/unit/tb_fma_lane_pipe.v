// tb_fma_lane_pipe.v -- unit test for fma_lane_pipe (Stages 2-4 of one accumulation).
// Inputs are already in the unified (Stage-1) form: sign, unbiased exponent,
// addend significand 24 bits with hidden bit at [23] (1.0 = exp 0, sig
// 800000), products exact 48 bits with hidden bit at [47] (the low 24 bits
// are given separately below, 0 = the product fits in 24 bits).
// It computes  A + P0 + P1 + P2 + P3  (only valid lanes) with ONE rounding
// and packs the result in the format given by cls/ew.
// The block has 2 internal pipeline registers -> result 2 clocks after the
// inputs are applied.
//
// Part 1 applies one operation at a time and waits for it (easy to read).
// Part 2 re-issues the same operations back-to-back, one per clock, and
// checks each result comes out 2 clocks later (pipelined throughput).
`include "fma_defs.vh"

module tb_fma_lane_pipe;
  parameter TB_NAME = "fma_lane_pipe";
  `include "tb_util.vh"

  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  reg                     a_s, a_z, a_n, a_i;
  reg  signed [`EXPW-1:0] a_e;
  reg  [`SIGW-1:0]        a_sig;
  reg  [`NLANE-1:0]       p_s, p_z, p_n, p_i, p_v;
  reg  [`NLANE*`EXPW-1:0] p_e;
  reg  [`NLANE*`PSIGW-1:0] p_sig;
  reg  [1:0]              cls;
  reg  [3:0]              ew;
  wire [31:0]             dout;

  fma_lane_pipe dut (
      .clk_i(clk), .rst_n_i(rst_n),
      .a_sign_i(a_s), .a_exp_i(a_e), .a_sig_i(a_sig), .a_zero_i(a_z), .a_nan_i(a_n), .a_inf_i(a_i),
      .p_sign_i(p_s), .p_exp_i(p_e), .p_sig_i(p_sig), .p_zero_i(p_z), .p_nan_i(p_n), .p_inf_i(p_i),
      .p_valid_i(p_v), .cls_i(cls), .ew_i(ew), .dout_o(dout)
  );

  // ---- stored test vectors (so part 2 can replay them pipelined) ----
  localparam NV = 16;
  reg [8*44-1:0] v_note [0:NV-1];
  reg [8*9-1:0]  v_fmt  [0:NV-1];
  reg [31:0]     v_exp  [0:NV-1];
  reg [3:0]      v_a    [0:NV-1];   // {s, z, n, i}
  reg signed [`EXPW-1:0] v_ae [0:NV-1];
  reg [`SIGW-1:0] v_asig [0:NV-1];
  reg [`NLANE-1:0] v_ps [0:NV-1], v_pz [0:NV-1], v_pn [0:NV-1], v_pi [0:NV-1], v_pv [0:NV-1];
  reg [`NLANE*`EXPW-1:0] v_pe [0:NV-1];
  reg [`NLANE*`PSIGW-1:0] v_psig [0:NV-1];
  reg [1:0] v_cls [0:NV-1];
  reg [3:0] v_ew  [0:NV-1];
  integer nv;

  task new_vec;
    input [8*9-1:0] fmt;
    input [1:0] tc;
    input [3:0] tew;
    input [3:0] aflags;           // {sign, zero, nan, inf}
    input signed [`EXPW-1:0] ae;
    input [`SIGW-1:0] asig;
    input [31:0] expected;
    input [8*44-1:0] note;
    begin
      v_fmt[nv] = fmt; v_cls[nv] = tc; v_ew[nv] = tew; v_a[nv] = aflags;
      v_ae[nv] = ae; v_asig[nv] = asig; v_exp[nv] = expected; v_note[nv] = note;
      v_ps[nv] = 0; v_pz[nv] = 4'b1111; v_pn[nv] = 0; v_pi[nv] = 0; v_pv[nv] = 0;
      v_pe[nv] = 0; v_psig[nv] = 0;
      nv = nv + 1;
    end
  endtask

  // add product lane l to the most recent vector
  task prod;
    input integer l;
    input s;
    input signed [`EXPW-1:0] pe;
    input [`SIGW-1:0] psig;
    input [2:0] flags;            // {zero, nan, inf}
    input [`SIGW-1:0] plo;        // low 24 bits of the exact 48-bit product
    begin
      v_pv[nv-1][l] = 1'b1; v_ps[nv-1][l] = s;
      {v_pz[nv-1][l], v_pn[nv-1][l], v_pi[nv-1][l]} = flags;
      v_pe[nv-1][`EXPW*l +: `EXPW] = pe;
      v_psig[nv-1][`PSIGW*l +: `PSIGW] = {psig, plo};
    end
  endtask

  task drive;
    input integer k;
    begin
      {a_s, a_z, a_n, a_i} = v_a[k]; a_e = v_ae[k]; a_sig = v_asig[k];
      p_s = v_ps[k]; p_z = v_pz[k]; p_n = v_pn[k]; p_i = v_pi[k]; p_v = v_pv[k];
      p_e = v_pe[k]; p_sig = v_psig[k]; cls = v_cls[k]; ew = v_ew[k];
    end
  endtask

  reg ok;
  integer k, cyc;

  initial begin
    banner("fma_lane_pipe  (Stages 2-4: align, add, normalize, round, pack; 2-cycle latency)",
           "dout = round( A + sum of valid products ) packed in format (cls, ew); inputs in unified form");

    nv = 0;
    //       format       cls     ew  {s,z,n,i} a_exp a_sig     expected      note
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h40000000, "1.0 + 1.0 = 2.0");
      prod(0, 0,  0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h00000000, "1.0 + (-1.0) = +0");
      prod(0, 1,  0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0100,  0, 24'h000000, 32'h3FC00000, "0 + 1.5 = 1.5");
      prod(0, 0,  0, 24'hC00000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b1000,  1, 24'hC00000, 32'hC0000000, "-3.0 + 1.0 = -2.0 (sign flip)");
      prod(0, 0,  0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000, -1, 24'h800000, 32'h33000000, "0.5 - (0.5-2^-25) = 2^-25 (cancel)");
      prod(0, 1, -2, 24'hFFFFFF, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h3F800000, "1.0 + 2^-24 : exact tie -> even (1.0)");
      prod(0, 0,-24, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h3F800001, "1.0 + 2^-24*(1+2^-47): above tie -> up");
      prod(0, 0,-24, 24'h800000, 3'b000, 24'h000001);
    new_vec("       HP", `CLS_16, 5, 4'b0000,  0, 24'h800000, 32'h00003E00, "HP: 1.0 + 0.5 = 1.5");
      prod(0, 0, -1, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h40A00000, "mixed: 1 + 1+1+1+1 = 5.0");
      prod(0, 0,  0, 24'h800000, 3'b000, 0); prod(1, 0, 0, 24'h800000, 3'b000, 0);
      prod(2, 0,  0, 24'h800000, 3'b000, 0); prod(3, 0, 0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0100,  0, 24'h000000, 32'h3FE00000, "mixed: 0 + 2 - 1 + 0.5 + 0.25 = 1.75");
      prod(0, 0,  1, 24'h800000, 3'b000, 0); prod(1, 1, 0, 24'h800000, 3'b000, 0);
      prod(2, 0, -1, 24'h800000, 3'b000, 0); prod(3, 0, -2, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0010,  0, 24'h000000, 32'h7F800001, "A = NaN -> NaN");
      prod(0, 0,  0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0000,  0, 24'h800000, 32'h7F800000, "product = +Inf -> +Inf");
      prod(0, 0,  0, 24'h000000, 3'b001, 0);
    new_vec("       SP", `CLS_32, 8, 4'b1001,  0, 24'h000000, 32'hFF800000, "A = -Inf, product 1.0 -> -Inf");
      prod(0, 0,  0, 24'h800000, 3'b000, 0);
    new_vec("       SP", `CLS_32, 8, 4'b0001,  0, 24'h000000, 32'h7F800001, "+Inf + (-Inf) -> NaN");
      prod(0, 1,  0, 24'h000000, 3'b001, 0);
    new_vec("       SP", `CLS_32, 8, 4'b1100,  0, 24'h000000, 32'h80000000, "-0 + (-0) -> -0");
      prod(0, 1,  0, 24'h000000, 3'b100, 0);
    new_vec("       HP", `CLS_16, 5, 4'b0100,  0, 24'h000000, 32'h00000001, "HP: 0 + 0.75*2^-24 -> rounds to 2^-24 (subnormal)");
      prod(0, 0,-25, 24'hC00000, 3'b000, 0);

    // reset
    drive(0);
    repeat (2) @(posedge clk);
    rst_n = 1;

    section("part 1: one operation at a time (apply inputs, wait 2 clocks, read dout)");
    $display("      format  | dout     | expected | result  operation");
    for (k = 0; k < nv; k = k + 1) begin
      drive(k);
      @(posedge clk); @(posedge clk); #1;
      ok = (dout === v_exp[k]);
      tally(ok);
      $display("   %s  | %h | %h | %s  %0s", v_fmt[k], dout, v_exp[k], pf(ok), v_note[k]);
    end

    section("part 2: same operations issued back-to-back, one per clock (pipelined)");
    $display("   clock | issued op | result of op | dout     | expected | result");
    for (cyc = 0; cyc < nv + 1; cyc = cyc + 1) begin
      if (cyc < nv) drive(cyc);
      @(posedge clk); #1;
      if (cyc >= 1) begin
        ok = (dout === v_exp[cyc - 1]);
        tally(ok);
        $display("   %4d  |    %2d     |     %2d       | %h | %h | %s", cyc, (cyc < nv) ? cyc : -1, cyc - 1,
                 dout, v_exp[cyc - 1], pf(ok));
      end
    end

    summary;
  end
endmodule
