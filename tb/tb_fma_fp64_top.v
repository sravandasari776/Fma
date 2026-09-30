// tb_fma_fp64_top.v
// System regression through the decimal I/O shell (fma_fp64_top).
//
// Same tb/vectors.txt as tb_fma_top.v, but every operand lane is first
// turned into an IEEE double by this testbench (its own real-arithmetic
// decode, independent of the RTL converters) and fed to fma_fp64_top,
// which must convert it back into the format, run U_FMA, and convert the
// result to a double again. One vector per clock, back-to-back.
// Checks, for every vector:
//   dout_packed_o == the expected encoding (bit for bit), and
//   dout_fp64_o   == the expected result as a double, lane by lane
//                    (a NaN result only has to be a NaN).
// Writes out/sim_results_fp64.txt ("idx got exp P|F").
`include "fma_defs.vh"

module tb_fma_fp64_top;
  localparam MAXV = 20000;
  // 5 registers (input conversion, 3 in fma_top, output conversion); inputs
  // are applied before each loop iteration's posedge, so a vector's result
  // is read LAT = 4 iterations later.
  localparam LAT  = 4;
  localparam LW   = 48;

  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  reg  [255:0] a64, b64, c64;
  reg          mixmode_i;
  reg  [1:0]   pra_i, prm_i;
  reg  [3:0]   ewa_i, ewm_i;
  wire [255:0] dout64;
  wire [31:0]  doutp;
  wire [63:0]  abus, bbus, cbus;
  wire [11:0]  inx;

  fma_fp64_top dut (
      .clk_i(clk), .rst_n_i(rst_n),
      .a_fp64_i(a64), .b_fp64_i(b64), .c_fp64_i(c64),
      .mixmode_i(mixmode_i), .pra_i(pra_i), .prm_i(prm_i), .ewa_i(ewa_i), .ewm_i(ewm_i),
      .dout_fp64_o(dout64), .dout_packed_o(doutp),
      .a_bus_o(abus), .b_bus_o(bbus), .c_bus_o(cbus), .inexact_o(inx)
  );

  integer n_vec;
  integer v_mixmode [0:MAXV-1];
  integer v_pra     [0:MAXV-1];
  integer v_prm     [0:MAXV-1];
  integer v_ewa     [0:MAXV-1];
  integer v_ewm     [0:MAXV-1];
  reg [63:0] v_a [0:MAXV-1];
  reg [63:0] v_b [0:MAXV-1];
  reg [63:0] v_c [0:MAXV-1];
  reg [31:0] v_exp [0:MAXV-1];
  reg [8*LW-1:0] v_label [0:MAXV-1];
  reg [8*LW-1:0] label_tmp;

  integer fd, fr, rc, i, cyc, idx, ln, nl, pass_count, fail_count;
  reg ok, lane_ok;
  reg [63:0] want, got64;

  function integer total_bits;
    input [1:0] cls;
    begin
      case (cls)
        `CLS_8:  total_bits = 8;
        `CLS_16: total_bits = 16;
        `CLS_32: total_bits = 32;
        default: total_bits = 19;
      endcase
    end
  endfunction

  function integer n_lanes;
    input [1:0] cls;
    begin
      case (cls)
        `CLS_8:  n_lanes = 4;
        `CLS_16: n_lanes = 2;
        default: n_lanes = 1;
      endcase
    end
  endfunction

  function [31:0] lane_bits;
    input [63:0] bus;
    input [1:0]  cls;
    input integer ln;
    begin
      case (cls)
        `CLS_8:  lane_bits = (bus >> (8 * ln)) & 32'hFF;
        `CLS_16: lane_bits = (bus >> (16 * ln)) & 32'hFFFF;
        `CLS_32: lane_bits = bus[31:0];
        default: lane_bits = bus[18:0];
      endcase
    end
  endfunction

  // one encoded value -> the same value as a double (testbench's own decode)
  function [63:0] enc_to_fp64;
    input [31:0] bits;
    input [1:0]  cls;
    input [3:0]  ew;
    integer total, m, bias, ef;
    reg     s;
    reg [31:0] mf;
    real    v;
    begin
      total = total_bits(cls);
      m     = total - 1 - ew;
      bias  = (1 << (ew - 1)) - 1;
      s     = bits[total - 1];
      ef    = (bits >> m) & ((1 << ew) - 1);
      mf    = bits & ((32'h1 << m) - 1);
      if (ef == (1 << ew) - 1)
        enc_to_fp64 = (mf != 0) ? 64'h7FF8000000000000 : {s, 11'h7FF, 52'd0};
      else if (ef == 0 && mf == 0)
        enc_to_fp64 = {s, 63'd0};
      else begin
        if (ef == 0) v = mf * (2.0 ** (1 - bias - m));
        else         v = (mf + (2.0 ** m)) * (2.0 ** (ef - bias - m));
        enc_to_fp64 = $realtobits(s ? -v : v);
      end
    end
  endfunction

  function is_nan64;
    input [63:0] x;
    begin
      is_nan64 = (x[62:52] == 11'h7FF) && (x[51:0] != 0);
    end
  endfunction

  task drive;
    input integer v;
    integer l;
    begin
      mixmode_i = v_mixmode[v][0];
      pra_i = v_pra[v][1:0]; prm_i = v_prm[v][1:0];
      ewa_i = v_ewa[v][3:0]; ewm_i = v_ewm[v][3:0];
      for (l = 0; l < 4; l = l + 1) begin
        a64[64*l +: 64] = enc_to_fp64(lane_bits(v_a[v], pra_i, l), pra_i, ewa_i);
        b64[64*l +: 64] = enc_to_fp64(lane_bits(v_b[v], prm_i, l), prm_i, ewm_i);
        c64[64*l +: 64] = enc_to_fp64(lane_bits(v_c[v], prm_i, l), prm_i, ewm_i);
      end
    end
  endtask

  initial begin
    fd = $fopen("vectors.txt", "r");
    if (fd == 0) begin
      $display("ERROR: could not open vectors.txt");
      $finish;
    end
    rc = $fscanf(fd, "%d\n", n_vec);
    if (n_vec > MAXV) begin
      $display("ERROR: %0d vectors > MAXV=%0d", n_vec, MAXV);
      $finish;
    end
    $display("Reading %0d vectors (through the decimal I/O shell, fma_fp64_top)", n_vec);
    for (i = 0; i < n_vec; i = i + 1) begin
      rc = $fscanf(fd, "%d %d %d %d %d %h %h %h %h %s\n",
                   v_mixmode[i], v_pra[i], v_prm[i], v_ewa[i], v_ewm[i],
                   v_a[i], v_b[i], v_c[i], v_exp[i], label_tmp);
      if (rc != 10) begin
        $display("ERROR: parse failure at vector %0d (rc=%0d)", i, rc);
        $finish;
      end
      v_label[i] = label_tmp;
    end
    $fclose(fd);

    fr = $fopen("sim_results_fp64.txt", "w");
    pass_count = 0;
    fail_count = 0;
    a64 = 0; b64 = 0; c64 = 0; mixmode_i = 0; pra_i = `CLS_8; prm_i = `CLS_8; ewa_i = 4; ewm_i = 4;

    @(posedge clk);
    rst_n = 1;

    for (cyc = 0; cyc < n_vec + LAT + 2; cyc = cyc + 1) begin
      if (cyc < n_vec) drive(cyc);
      else begin a64 = 0; b64 = 0; c64 = 0; end

      @(posedge clk);
      #1;

      if (cyc >= LAT) begin
        idx = cyc - LAT;
        if (idx < n_vec) begin
          ok = (doutp === v_exp[idx]);
          nl = v_mixmode[idx] ? 1 : n_lanes(v_pra[idx][1:0]);
          for (ln = 0; ln < nl; ln = ln + 1) begin
            want  = enc_to_fp64(lane_bits({32'd0, v_exp[idx]}, v_pra[idx][1:0], ln),
                                v_pra[idx][1:0], v_ewa[idx][3:0]);
            got64 = dout64[64*ln +: 64];
            lane_ok = is_nan64(want) ? is_nan64(got64) : (got64 === want);
            ok = ok && lane_ok;
          end
          if (ok) begin
            pass_count = pass_count + 1;
            $fdisplay(fr, "%0d %08x %08x P", idx, doutp, v_exp[idx]);
          end else begin
            fail_count = fail_count + 1;
            $fdisplay(fr, "%0d %08x %08x F", idx, doutp, v_exp[idx]);
            if (fail_count <= 40)
              $display("FAIL [%0d] %0s: packed got=%08x exp=%08x  double lane0 got=%016x",
                       idx, v_label[idx], doutp, v_exp[idx], dout64[63:0]);
          end
        end
      end
    end
    $fclose(fr);

    $display("---------------------------------------------");
    $display("TOTAL: %0d   PASS: %0d   FAIL: %0d", n_vec, pass_count, fail_count);
    if (fail_count == 0) $display("RESULT: ALL PASS");
    else $display("RESULT: FAILURES PRESENT");
    $finish;
  end

  initial begin
    #100000000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
