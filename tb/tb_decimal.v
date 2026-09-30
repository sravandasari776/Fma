// tb_decimal.v
// Decimal in, decimal out: ONE operation through the decimal I/O shell
// (fma_fp64_top = fp64_to_fmt -> fma_top -> fmt_to_fp64), no Python.
//
// The numbers arrive as text on the simulator command line (see
// tb/run_fma.sh). The ONLY thing this testbench does to them is read the
// text into an IEEE double ($sscanf / $realtobits) -- the step a processor
// or driver performs whenever a program reads "0.1". Everything after that
// is RTL: rounding into the chosen format, packing the lanes, the FMA, and
// converting the result back to a double, which is printed in decimal.
//
// Plusargs: +MIX=0|1 +PRA +PRM +EWA +EWM (as on fma_top), +NL=lanes (multiple
// mode) or products (mixed mode) given, +FMTA=name +FMTP=name (for printing),
// +A0..+A3 +B0..+B3 +C0..+C3 = the numbers as text (default 0;
// inf, -inf, nan, -0 accepted).
`include "fma_defs.vh"

module tb_decimal;
  localparam SW = 64;   // max characters per number

  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  reg  [255:0] a64, b64, c64;
  reg          mix;
  reg  [1:0]   pra, prm;
  reg  [3:0]   ewa, ewm;
  wire [255:0] dout64;
  wire [31:0]  doutp;
  wire [63:0]  abus, bbus, cbus;
  wire [11:0]  inx;

  fma_fp64_top dut (
      .clk_i(clk), .rst_n_i(rst_n),
      .a_fp64_i(a64), .b_fp64_i(b64), .c_fp64_i(c64),
      .mixmode_i(mix), .pra_i(pra), .prm_i(prm), .ewa_i(ewa), .ewm_i(ewm),
      .dout_fp64_o(dout64), .dout_packed_o(doutp),
      .a_bus_o(abus), .b_bus_o(bbus), .c_bus_o(cbus), .inexact_o(inx)
  );

  // lane `ln` of a packed operand bus, right-justified
  function [31:0] lane_of;
    input [63:0] bus;
    input [1:0]  cls;
    input integer ln;
    begin
      case (cls)
        `CLS_8:  lane_of = (bus >> (8 * ln)) & 32'hFF;
        `CLS_16: lane_of = (bus >> (16 * ln)) & 32'hFFFF;
        `CLS_32: lane_of = bus[31:0];
        default: lane_of = bus[18:0];
      endcase
    end
  endfunction

  // the value each operand was actually stored as: the RTL's own
  // fmt_to_fp64 block, reused here only to display it
  wire [255:0] a_st, b_st, c_st;
  genvar G;
  generate
    for (G = 0; G < 4; G = G + 1) begin : SHOW
      wire [63:0] as_, bs_, cs_;
      fmt_to_fp64 ua (.bits_i(lane_of(abus, pra, G)), .cls_i(pra), .ew_i(ewa), .d_o(as_));
      fmt_to_fp64 ub (.bits_i(lane_of(bbus, prm, G)), .cls_i(prm), .ew_i(ewm), .d_o(bs_));
      fmt_to_fp64 uc (.bits_i(lane_of(cbus, prm, G)), .cls_i(prm), .ew_i(ewm), .d_o(cs_));
      assign a_st[64*G +: 64] = as_;
      assign b_st[64*G +: 64] = bs_;
      assign c_st[64*G +: 64] = cs_;
    end
  endgenerate

  reg [8*SW-1:0] ta [0:3];
  reg [8*SW-1:0] tb [0:3];
  reg [8*SW-1:0] tc [0:3];
  reg [8*16-1:0] fmta, fmtp;
  integer imix, ipra, iprm, iewa, iewm, nl, k, bad;

  // the text-to-double step (not RTL: this is what reading a number does)
  function [63:0] text_to_fp64;
    input [8*SW-1:0] t;
    real    r;
    integer rc;
    begin
      if (t == "inf")       text_to_fp64 = 64'h7FF0000000000000;
      else if (t == "-inf") text_to_fp64 = 64'hFFF0000000000000;
      else if (t == "nan")  text_to_fp64 = 64'h7FF8000000000000;
      else if (t == "-0")   text_to_fp64 = 64'h8000000000000000;
      else begin
        r  = 0.0;
        rc = $sscanf(t, "%f", r);
        if (rc != 1) begin
          $display("ERROR: cannot read '%0s' as a number", t);
          bad = 1;
        end
        text_to_fp64 = $realtobits(r);
      end
    end
  endfunction

  // print a double as a decimal number (NaN / Inf spelled out)
  task show;
    input [63:0] x;
    begin
      if (x[62:52] == 11'h7FF) begin
        if (x[51:0] != 0) $write("NaN");
        else if (x[63])   $write("-Inf");
        else              $write("+Inf");
      end else
        $write("%.17g", $bitstoreal(x));
    end
  endtask

  // print an encoded lane with the digit count of its class
  task show_enc;
    input [31:0] v;
    input [1:0]  cls;
    begin
      case (cls)
        `CLS_8:  $write("%h", v[7:0]);
        `CLS_16: $write("%h", v[15:0]);
        `CLS_32: $write("%h", v[31:0]);
        default: $write("%h", v[18:0]);
      endcase
    end
  endtask

  task operand_row;
    input [8*4-1:0]  name;
    input [8*SW-1:0] typed;
    input [63:0]     dbl;
    input [31:0]     enc;
    input [1:0]      cls;
    input [8*16-1:0] fname;
    input            rounded;
    input [63:0]     stored;
    begin
      $write("   %0s = %0s\n", name, typed);
      $write("        double %h  ->  %0s ", dbl, fname);
      show_enc(enc, cls);
      $write("  ->  stored as ");
      show(stored);
      $write("%0s\n", rounded ? "   (rounded to fit the format)" : "");
    end
  endtask

  initial begin
    imix = 0; ipra = 2; iprm = 2; iewa = 8; iewm = 8; nl = 1; bad = 0;
    fmta = "SP"; fmtp = "SP";
    for (k = 0; k < 4; k = k + 1) begin ta[k] = "0"; tb[k] = "0"; tc[k] = "0"; end
    if ($value$plusargs("MIX=%d", imix)) ;
    if ($value$plusargs("PRA=%d", ipra)) ;
    if (!$value$plusargs("PRM=%d", iprm)) iprm = ipra;
    if ($value$plusargs("EWA=%d", iewa)) ;
    if (!$value$plusargs("EWM=%d", iewm)) iewm = iewa;
    if ($value$plusargs("NL=%d", nl)) ;
    if ($value$plusargs("FMTA=%s", fmta)) ;
    if ($value$plusargs("FMTP=%s", fmtp)) ;
    if ($value$plusargs("A0=%s", ta[0])) ;
    if ($value$plusargs("A1=%s", ta[1])) ;
    if ($value$plusargs("A2=%s", ta[2])) ;
    if ($value$plusargs("A3=%s", ta[3])) ;
    if ($value$plusargs("B0=%s", tb[0])) ;
    if ($value$plusargs("B1=%s", tb[1])) ;
    if ($value$plusargs("B2=%s", tb[2])) ;
    if ($value$plusargs("B3=%s", tb[3])) ;
    if ($value$plusargs("C0=%s", tc[0])) ;
    if ($value$plusargs("C1=%s", tc[1])) ;
    if ($value$plusargs("C2=%s", tc[2])) ;
    if ($value$plusargs("C3=%s", tc[3])) ;

    mix = imix[0]; pra = ipra[1:0]; prm = iprm[1:0]; ewa = iewa[3:0]; ewm = iewm[3:0];
    for (k = 0; k < 4; k = k + 1) begin
      a64[64*k +: 64] = text_to_fp64(ta[k]);
      b64[64*k +: 64] = text_to_fp64(tb[k]);
      c64[64*k +: 64] = text_to_fp64(tc[k]);
    end
    if (bad) $finish;

    // reset, then apply the operation (held) and follow it through
    repeat (2) @(posedge clk);
    #1 rst_n = 1;

    $display("");
    $display("==============================================================================");
    if (mix) $display(" U_FMA, decimal in / decimal out:  mixed precision, %0s + %0d x %0s", fmta, nl, fmtp);
    else     $display(" U_FMA, decimal in / decimal out:  multiple precision, %0s, %0d lane(s)", fmta, nl);
    $display("==============================================================================");

    @(posedge clk); #1;   // edge 1: input converters (fp64_to_fmt) registered
    $display(" clock edge 1 -- the RTL rounded each number into the format (fp64_to_fmt):");
    if (mix) begin
      operand_row("A", ta[0], a64[63:0], lane_of(abus, pra, 0), pra, fmta, inx[0], a_st[63:0]);
      for (k = 0; k < nl; k = k + 1) begin
        operand_row(k == 0 ? "B0" : k == 1 ? "B1" : k == 2 ? "B2" : "B3", tb[k], b64[64*k +: 64],
                    lane_of(bbus, prm, k), prm, fmtp, inx[4 + k], b_st[64*k +: 64]);
        operand_row(k == 0 ? "C0" : k == 1 ? "C1" : k == 2 ? "C2" : "C3", tc[k], c64[64*k +: 64],
                    lane_of(cbus, prm, k), prm, fmtp, inx[8 + k], c_st[64*k +: 64]);
      end
    end else begin
      for (k = 0; k < nl; k = k + 1) begin
        operand_row(k == 0 ? "A0" : k == 1 ? "A1" : k == 2 ? "A2" : "A3", ta[k], a64[64*k +: 64],
                    lane_of(abus, pra, k), pra, fmta, inx[k], a_st[64*k +: 64]);
        operand_row(k == 0 ? "B0" : k == 1 ? "B1" : k == 2 ? "B2" : "B3", tb[k], b64[64*k +: 64],
                    lane_of(bbus, prm, k), prm, fmta, inx[4 + k], b_st[64*k +: 64]);
        operand_row(k == 0 ? "C0" : k == 1 ? "C1" : k == 2 ? "C2" : "C3", tc[k], c64[64*k +: 64],
                    lane_of(cbus, prm, k), prm, fmta, inx[8 + k], c_st[64*k +: 64]);
      end
    end
    $display("   buses into fma_top: a_i=%h  b_i=%h  c_i=%h", abus, bbus, cbus);

    @(posedge clk); #1;   // edge 2: fma_top stage 1 -> 2
    $display(" clock edge 2 -- fma_top stage 2 (lane 0): largest term %0s, exponent %0d",
             (dut.u_core.LANEPIPE[0].u_pipe.label_sel_s2 == 3'd4) ? "= the addend" : "= a product",
             $signed(dut.u_core.LANEPIPE[0].u_pipe.ref_exp_s2));
    @(posedge clk); #1;   // edge 3
    $display(" clock edge 3 -- fma_top stage 3 (lane 0): exact sum %h", dut.u_core.LANEPIPE[0].u_pipe.resolved_s3);
    @(posedge clk); #1;   // edge 4: fma_top result
    $display(" clock edge 4 -- fma_top stage 4 output dout_o[31:0] = %h", dut.u_core.dout_o[31:0]);
    @(posedge clk); #1;   // edge 5: output converters (fmt_to_fp64) registered
    $display(" clock edge 5 -- the RTL turned the result back into a double (fmt_to_fp64):");
    $display("");
    if (mix) begin
      $write("   %0s", ta[0]);
      for (k = 0; k < nl; k = k + 1) $write(" + (%0s x %0s)", tb[k], tc[k]);
      $write("\n     = ");
      show(dout64[63:0]);
      $write("      [%0s ", fmta); show_enc(lane_of({32'd0, doutp}, pra, 0), pra);
      $write(", double %h]\n", dout64[63:0]);
    end else begin
      for (k = 0; k < nl; k = k + 1) begin
        $write("   lane %0d:  %0s + %0s x %0s\n     = ", k, ta[k], tb[k], tc[k]);
        show(dout64[64*k +: 64]);
        $write("      [%0s ", fmta); show_enc(lane_of({32'd0, doutp}, pra, k), pra);
        $write(", double %h]\n", dout64[64*k +: 64]);
      end
    end
    $display("");
    $display(" RESULT: dout_packed_o = %h", doutp);
    $display("==============================================================================");
    $finish;
  end
endmodule
