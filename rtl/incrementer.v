// MPFMA-DS-001 8.5 - Incrementor.
// Generic +1 adder. Two's-complement negation of a value is realized as
// 1's-complement (free bitwise NOT, done by the caller) followed by a
// single pass through this incrementer, per the source paper's technique
// of building decrement/negate paths out of increment-only hardware.
module incrementer #(
    parameter W = 40
) (
    input  wire [W-1:0] a_i,
    output wire [W-1:0] sum_o
);
  assign sum_o = a_i + {{(W-1){1'b0}}, 1'b1};
endmodule
