// MPFMA-DS-001 8.4 - LZAU (Leading Zero Anticipator Unit).
// Determines the shift needed to renormalize the post-Complement
// magnitude so its leading '1' sits back at bit MSBPOS. The source paper
// anticipates this concurrently with the CSLA add (a critical-path
// optimization); this implementation computes it directly on the
// magnitude once Complement has resolved it, which is functionally
// equivalent (same shift amount) at the cost of the two blocks no longer
// running in parallel -- immaterial for functional verification.
`include "fma_defs.vh"

module stage3_lzau (
    input  wire [`WW-1:0]          magnitude_i,
    output reg  signed [`EXPW-1:0] exp_adjust_o, // add to ref_exp to get true exponent
    output reg                     is_zero_o
);
  integer pos;
  integer b;
  always @* begin
    is_zero_o = (magnitude_i == 0);
    pos = -1;
    for (b = `WW-1; b >= 0; b = b - 1) begin
      if (pos == -1 && magnitude_i[b]) pos = b;
    end
    // MSBPOS is the "no shift" leading-one position; pos>MSBPOS means the
    // accumulation overflowed (needs a right shift, exp increases);
    // pos<MSBPOS means cancellation occurred (needs a left shift, exp
    // decreases).
    exp_adjust_o = is_zero_o ? 0 : (pos - `MSBPOS);
  end
endmodule
