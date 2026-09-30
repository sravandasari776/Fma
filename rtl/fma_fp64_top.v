// fma_fp64_top.v
// Decimal I/O shell around U_FMA: the FMA with IEEE 754 double operands
// and results, so a user only ever deals in ordinary numbers.
//
//   typed decimal --(CPU / driver / simulator reads the text)--> double
//     --> [C0] fp64_to_fmt x12: round each operand into the selected format,
//              pack the lanes onto a_i/b_i/c_i                  -> register
//     --> fma_top (U_FMA, unchanged: 4 stages, 3 registers)
//     --> [C5] fmt_to_fp64 x4: result lanes back to doubles (exact) -> register
//     --> double --> printed as a decimal
//
// U_FMA itself is untouched and still takes binary-encoded operands, as
// MPFMA-DS-001 section 4.3 requires ("no format conversion" inside it):
// this shell sits OUTSIDE it. Turning typed text into a double is not
// done here -- hardware never sees text; a processor, driver or (here) the
// simulator does that, exactly as when a program reads "0.1".
//
// Ports: operands as doubles, 4 lanes each (lane i at [64*i +: 64]):
//   multiple-precision (mixmode_i=0): lane i computes A_i + B_i*C_i
//   (4 lanes for 8-bit formats, 2 for 16-bit, 1 for SP/TF32);
//   mixed-precision (mixmode_i=1): A lane 0 is the single addend, B/C lanes
//   are the dot-product operands (4 for 8-bit, 2 for 16-bit products).
// Mode/format controls mean exactly what they mean on fma_top.
// dout_fp64_o: result lanes as doubles (unused lanes 0); dout_packed_o: the
// core's own packed result; a/b/c_bus_o: the operands as encoded for the
// core; inexact_o: operand i was rounded to fit ({C3..C0, B3..B0, A3..A0}).
//
// Latency: 5 clock edges (1 input register + 3 inside fma_top + 1 output
// register); one new operation per clock.
`include "fma_defs.vh"

module fma_fp64_top (
    input  wire          clk_i,
    input  wire          rst_n_i,

    input  wire [255:0]  a_fp64_i, b_fp64_i, c_fp64_i,
    input  wire          mixmode_i,
    input  wire [1:0]    pra_i, prm_i,
    input  wire [3:0]    ewa_i, ewm_i,

    output reg  [255:0]  dout_fp64_o,
    output reg  [31:0]   dout_packed_o,
    output wire [63:0]   a_bus_o, b_bus_o, c_bus_o,
    output wire [11:0]   inexact_o
);
  `include "fma_funcs.v"

  // pack 4 right-justified lane encodings onto a 64-bit operand bus: the
  // inverse of lane_slice() (byte / halfword / word / low-19-bit lanes)
  function [63:0] pack_lanes;
    input [127:0] lanes;
    input [1:0]   cls;
    begin
      case (cls)
        `CLS_8:  pack_lanes = {32'd0, lanes[96 +: 8], lanes[64 +: 8], lanes[32 +: 8], lanes[0 +: 8]};
        `CLS_16: pack_lanes = {32'd0, lanes[32 +: 16], lanes[0 +: 16]};
        `CLS_32: pack_lanes = {32'd0, lanes[0 +: 32]};
        default: pack_lanes = {45'd0, lanes[0 +: 19]};
      endcase
    end
  endfunction

  // ---------------- C0: doubles -> format encodings ----------------
  wire [127:0] a_cv, b_cv, c_cv;
  wire [3:0]   a_inx, b_inx, c_inx;
  genvar L;
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : CVIN
      wire [31:0] ab, bb, cb;
      wire        ai, bi, ci;
      fp64_to_fmt u_a (.d_i(a_fp64_i[64*L +: 64]), .cls_i(pra_i), .ew_i(ewa_i), .bits_o(ab), .inexact_o(ai));
      fp64_to_fmt u_b (.d_i(b_fp64_i[64*L +: 64]), .cls_i(prm_i), .ew_i(ewm_i), .bits_o(bb), .inexact_o(bi));
      fp64_to_fmt u_c (.d_i(c_fp64_i[64*L +: 64]), .cls_i(prm_i), .ew_i(ewm_i), .bits_o(cb), .inexact_o(ci));
      assign a_cv[32*L +: 32] = ab;
      assign b_cv[32*L +: 32] = bb;
      assign c_cv[32*L +: 32] = cb;
      assign a_inx[L] = ai;
      assign b_inx[L] = bi;
      assign c_inx[L] = ci;
    end
  endgenerate

  reg [63:0] a_bus_r, b_bus_r, c_bus_r;
  reg        mix_r;
  reg [1:0]  pra_r, prm_r;
  reg [3:0]  ewa_r, ewm_r;
  reg [11:0] inexact_r;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      a_bus_r <= 0; b_bus_r <= 0; c_bus_r <= 0;
      mix_r <= 1'b0; pra_r <= `CLS_8; prm_r <= `CLS_8; ewa_r <= 4'd4; ewm_r <= 4'd4;
      inexact_r <= 0;
    end else begin
      a_bus_r <= pack_lanes(a_cv, pra_i);
      b_bus_r <= pack_lanes(b_cv, prm_i);
      c_bus_r <= pack_lanes(c_cv, prm_i);
      mix_r <= mixmode_i; pra_r <= pra_i; prm_r <= prm_i; ewa_r <= ewa_i; ewm_r <= ewm_i;
      inexact_r <= {c_inx, b_inx, a_inx};
    end
  end

  assign a_bus_o   = a_bus_r;
  assign b_bus_o   = b_bus_r;
  assign c_bus_o   = c_bus_r;
  assign inexact_o = inexact_r;

  // ---------------- U_FMA (unchanged) ----------------
  wire [127:0] core_dout;
  fma_top u_core (
      .clk_i(clk_i), .rst_n_i(rst_n_i),
      .a_i(a_bus_r), .b_i(b_bus_r), .c_i(c_bus_r),
      .mixmode_i(mix_r), .pra_i(pra_r), .prm_i(prm_r), .ewa_i(ewa_r), .ewm_i(ewm_r),
      .dout_o(core_dout)
  );

  // the result format of the operation now on core_dout: the core's 3
  // register edges later (mixed mode: the addend's format; multiple mode:
  // pra == prm)
  reg        mix_d1, mix_d2, mix_d3;
  reg [1:0]  pra_d1, pra_d2, pra_d3;
  reg [3:0]  ewa_d1, ewa_d2, ewa_d3;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      mix_d1 <= 1'b0; mix_d2 <= 1'b0; mix_d3 <= 1'b0;
      pra_d1 <= `CLS_8; pra_d2 <= `CLS_8; pra_d3 <= `CLS_8;
      ewa_d1 <= 4'd4; ewa_d2 <= 4'd4; ewa_d3 <= 4'd4;
    end else begin
      mix_d1 <= mix_r;  mix_d2 <= mix_d1;  mix_d3 <= mix_d2;
      pra_d1 <= pra_r;  pra_d2 <= pra_d1;  pra_d3 <= pra_d2;
      ewa_d1 <= ewa_r;  ewa_d2 <= ewa_d1;  ewa_d3 <= ewa_d2;
    end
  end

  // ---------------- C5: result lanes -> doubles ----------------
  wire [255:0] out_cv;
  integer n_used;
  always @* n_used = mix_d3 ? 1 : lane_count(pra_d3);
  generate
    for (L = 0; L < `NLANE; L = L + 1) begin : CVOUT
      wire [31:0] lane;
      wire [63:0] od;
      assign lane = lane_slice({32'd0, core_dout[31:0]}, pra_d3, L);
      fmt_to_fp64 u_o (.bits_i(lane), .cls_i(pra_d3), .ew_i(ewa_d3), .d_o(od));
      assign out_cv[64*L +: 64] = (L < n_used) ? od : 64'd0;
    end
  endgenerate

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      dout_fp64_o   <= 0;
      dout_packed_o <= 0;
    end else begin
      dout_fp64_o   <= out_cv;
      dout_packed_o <= core_dout[31:0];
    end
  end
endmodule
