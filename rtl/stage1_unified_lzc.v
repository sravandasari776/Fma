// MPFMA-DS-001 6.4 - Unified Leading Zero Counter (dual instance in fma_top,
// one for the B operand lane set, one for C). Modeled per Fig.4 as four
// 6-bit sub-LZC units whose zero-counts combine with offset propagation
// across segment boundaries, so the same hardware counts leading zeros of
// an 8-, 16- or 24-bit significand. Used to renormalize subnormal operands
// (extractor) and to predict product normalization shift (relative
// normalizer).
`include "fma_defs.vh"

module stage1_unified_lzc (
    input  wire [`SIGW-1:0] sig_i,   // 24-bit raw significand (hidden bit may be 0)
    output reg  [4:0]      lzc_o,   // leading zero count, 0..24
    output reg              az_o     // all-zero flag
);
  // four 6-bit sub-LZC units
  reg [2:0] sub_lzc [0:3];
  reg       sub_az  [0:3];

  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : SUB_LZC
      wire [5:0] seg;
      assign seg = sig_i[23 - g*6 -: 6];
      always @* begin
        sub_az[g] = (seg == 6'b0);
        casez (seg)
          6'b1?????: sub_lzc[g] = 3'd0;
          6'b01????: sub_lzc[g] = 3'd1;
          6'b001???: sub_lzc[g] = 3'd2;
          6'b0001??: sub_lzc[g] = 3'd3;
          6'b00001?: sub_lzc[g] = 3'd4;
          6'b000001: sub_lzc[g] = 3'd5;
          default:   sub_lzc[g] = 3'd6; // all-zero segment
        endcase
      end
    end
  endgenerate

  // offset propagation: a segment's count only matters if every more
  // significant segment was entirely zero.
  always @* begin
    az_o = sub_az[0] & sub_az[1] & sub_az[2] & sub_az[3];
    if (!sub_az[0])       lzc_o = {2'b0, sub_lzc[0]};
    else if (!sub_az[1])  lzc_o = 5'd6  + {2'b0, sub_lzc[1]};
    else if (!sub_az[2])  lzc_o = 5'd12 + {2'b0, sub_lzc[2]};
    else if (!sub_az[3])  lzc_o = 5'd18 + {2'b0, sub_lzc[3]};
    else                  lzc_o = 5'd24;
  end
endmodule
