// MPFMA-DS-001 7.2 - Addend Alignment (see align_shifter.v for the shared
// barrel-shifter core).
`include "fma_defs.vh"

module stage2_addend_alignment (
    input  wire [`SIGW-1:0] sig_i,
    input  wire [`SHW-1:0]  shift_i,
    output wire [`WW-1:0]   aligned_o,
    output wire             sticky_o
);
  align_shifter #(.SW(`SIGW)) u_shift (.sig_i(sig_i), .shift_i(shift_i), .aligned_o(aligned_o), .sticky_o(sticky_o));
endmodule
