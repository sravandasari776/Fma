// MPFMA-DS-001 7.4 - Unified Relative Normalizer.
// The source paper normalizes all non-anchor products relative to the
// anchor's Stage-1 LZC value in a single shared pass, avoiding an
// independent normalizer per product. In this implementation every
// product is already independently, absolutely normalized in Stage 1
// (stage1_unified_extractor / stage1_exp_align_controller), because the
// extractor pre-normalizes B and C before multiplication rather than
// deferring normalization to post-multiply. This block is therefore a
// structural pass-through, retained so the module hierarchy mirrors
// Fig. 3 of the source paper; see docs/DEVIATIONS.md.
//
// Ports are packed vectors (lane i at [PSIGW*i +: PSIGW] / [EXPW*i +: EXPW])
// -- see stage1_unified_extractor.v's header comment.
`include "fma_defs.vh"

module stage2_relative_normalizer (
    input  wire [`NLANE*`PSIGW-1:0] sig_i,
    input  wire [`NLANE*`EXPW-1:0] exp_i,
    output wire [`NLANE*`PSIGW-1:0] sig_o,
    output wire [`NLANE*`EXPW-1:0] exp_o
);
  assign sig_o = sig_i;
  assign exp_o = exp_i;
endmodule
