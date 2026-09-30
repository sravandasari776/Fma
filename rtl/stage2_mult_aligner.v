// MPFMA-DS-001 7.6 - Multiplication Aligner/Inversion.
// Right-shifts one lane's normalized, full-precision (48-bit, exact)
// product significand into the WW-bit accumulation frame (see
// align_shifter.v). The sign-based inversion
// described in the source paper is applied by stage2_invert_swap, which
// consumes this block's unsigned aligned magnitude.
`include "fma_defs.vh"

module stage2_mult_aligner (
    input  wire [`PSIGW-1:0] sig_i,
    input  wire [`SHW-1:0]  shift_i,
    output wire [`WW-1:0]   aligned_o,
    output wire             sticky_o
);
  align_shifter #(.SW(`PSIGW)) u_shift (.sig_i(sig_i), .shift_i(shift_i), .aligned_o(aligned_o), .sticky_o(sticky_o));
endmodule
