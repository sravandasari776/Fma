// MPFMA-DS-001 9.2 - Rounding.
// Extracts the top 24 bits (hidden + 23) of the normalized magnitude at
// MSBPOS, combines every sticky source collected upstream (Stage-2
// alignment truncation via stage3_sticky_logic, plus any bits exposed by
// a Stage-4 overflow right-shift, plus the normalized register's own
// low bits) and rounds to the target format's mantissa width `m` using
// round-to-nearest-even. A carry out of the rounding step (rnd_ovf_o)
// means the result becomes an exact power of two and the exponent must
// be bumped by the caller (Exponent Adjuster, 9.3).
`include "fma_defs.vh"

module stage4_rounding (
    input  wire [`WW-1:0]     normalized_i,
    input  wire               sticky_upstream_i,
    input  wire               sticky_norm_i,
    input  wire [31:0]        m_i,
    output reg  [`SIGW-1:0]   rounded_sig_o,
    output reg                rnd_ovf_o
);
  `include "fma_funcs.v"

  wire [`SIGW-1:0] sig24;
  wire             guard_extra;
  wire             sticky_extra;

  assign sig24 = normalized_i[`MSBPOS -: `SIGW];
  // bit MSBPOS-SIGW is the guard bit (immediately below sig24's window);
  // everything strictly below that is sticky. Both are needed separately
  // so round_nearest_even can round correctly even at full mantissa width
  // (m=SIGW-1), where sig24 itself has no spare bit to serve as guard.
  assign guard_extra  = normalized_i[`MSBPOS-`SIGW];
  assign sticky_extra = sticky_upstream_i | sticky_norm_i |
                         ((`MSBPOS-`SIGW) > 0 ? (|normalized_i[`MSBPOS-`SIGW-1:0]) : 1'b0);

  wire [`SIGW:0]   packed_result;
  wire [`SIGW-1:0] rnd_result;
  wire             ovf;
  assign packed_result = round_nearest_even(sig24, m_i, guard_extra, sticky_extra);
  assign rnd_result = packed_result[`SIGW-1:0];
  assign ovf        = packed_result[`SIGW];

  always @* begin
    if (ovf) begin
      rounded_sig_o = {1'b1, {(`SIGW-1){1'b0}}};
      rnd_ovf_o      = 1'b1;
    end else begin
      rounded_sig_o = rnd_result;
      rnd_ovf_o      = 1'b0;
    end
  end
endmodule
