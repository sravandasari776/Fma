// MPFMA-DS-001 6.3 - Unified Multiple-Precision Booth Multiplier.
// Radix-4 Booth multiplication of the 24-bit unified significands of one
// (B,C) lane pair. Because subnormal/lower-precision operands are already
// zero-padded into the fixed 24-bit left-justified representation by the
// extractor, a single 24x24 Booth array correctly realizes an 8x8, 12x12
// or 24x24 multiply for any configured precision with no separate
// per-precision datapath (the padded low bits simply contribute all-zero
// partial products). Four instances of this module (one per lane) realize
// the paper's parallel PPG structure (Fig. 6); NLANE instances are
// generated in fma_top.
//
// Produces a carry-save (sum, carry) pair rather than a fully resolved
// product, per Fig. 3 (output is compressed via a fixed 13->9->6->4->3->2
// tree of 3:2 CSAs), deferring final carry propagation to Stage 2/3.
`include "fma_defs.vh"

module stage1_booth_multiplier (
    input  wire [`SIGW-1:0] sig_b_i,
    input  wire [`SIGW-1:0] sig_c_i,
    output wire [47:0]     sum_o,
    output wire [47:0]     carry_o
);
  localparam NPP = 13;
  localparam PW  = 52; // partial-product working width (48 + guard)

  wire [26:0] y_ext;
  assign y_ext = {2'b00, sig_b_i, 1'b0};

  reg  signed [26:0] pp_val   [0:NPP-1];  // multiple(booth group) * sig_c
  wire [PW-1:0]       pp_ext   [0:NPP-1];  // sign-extended to PW bits
  wire [PW-1:0]       pp_wide  [0:NPP-1];  // sign-extended & shifted

  genvar i;
  generate
    for (i = 0; i < NPP; i = i + 1) begin : PPG
      wire [2:0] grp;
      assign grp = y_ext[2*i +: 3];
      always @* begin
        case (grp)
          3'b000, 3'b111: pp_val[i] = 0;
          3'b001, 3'b010: pp_val[i] = {3'b000, sig_c_i};
          3'b011:         pp_val[i] = {2'b00, sig_c_i, 1'b0};
          3'b100:         pp_val[i] = -{2'b00, sig_c_i, 1'b0};
          3'b101, 3'b110: pp_val[i] = -{3'b000, sig_c_i};
          default:        pp_val[i] = 0;
        endcase
      end
      // manual sign-extension: Verilog shift results are self-determined
      // width (same as the left operand), not automatically widened by
      // the assignment target, so pp_val must be extended to PW bits
      // *before* shifting rather than relying on an SV size-cast (which
      // does not exist in plain Verilog).
      assign pp_ext[i]  = {{(PW-27){pp_val[i][26]}}, pp_val[i]};
      assign pp_wide[i] = pp_ext[i] << (2*i);
    end
  endgenerate

  // fixed reduction tree: 13 -> 9 -> 6 -> 4 -> 3 -> 2
  wire [PW-1:0] l1 [0:8];
  wire [PW-1:0] l2 [0:5];
  wire [PW-1:0] l3 [0:3];
  wire [PW-1:0] l4 [0:2];
  wire [PW-1:0] l5 [0:1];

  csa32 #(PW) c00 (pp_wide[0],  pp_wide[1],  pp_wide[2],  l1[0], l1[1]);
  csa32 #(PW) c01 (pp_wide[3],  pp_wide[4],  pp_wide[5],  l1[2], l1[3]);
  csa32 #(PW) c02 (pp_wide[6],  pp_wide[7],  pp_wide[8],  l1[4], l1[5]);
  csa32 #(PW) c03 (pp_wide[9],  pp_wide[10], pp_wide[11], l1[6], l1[7]);
  assign l1[8] = pp_wide[12];

  csa32 #(PW) c10 (l1[0], l1[1], l1[2], l2[0], l2[1]);
  csa32 #(PW) c11 (l1[3], l1[4], l1[5], l2[2], l2[3]);
  csa32 #(PW) c12 (l1[6], l1[7], l1[8], l2[4], l2[5]);

  csa32 #(PW) c20 (l2[0], l2[1], l2[2], l3[0], l3[1]);
  csa32 #(PW) c21 (l2[3], l2[4], l2[5], l3[2], l3[3]);

  csa32 #(PW) c30 (l3[0], l3[1], l3[2], l4[0], l4[1]);
  assign l4[2] = l3[3];

  csa32 #(PW) c40 (l4[0], l4[1], l4[2], l5[0], l5[1]);

  assign sum_o   = l5[0][47:0];
  assign carry_o = l5[1][47:0];
endmodule
