// MPFMA-DS-001 8.2 - Sticky Logic.
// OR-reduces every bit discarded during Stage-2 alignment (addend +
// up to 4 products) into a single sticky bit carried forward for
// round-to-nearest-even in Stage 4.
module stage3_sticky_logic (
    input  wire       a_sticky_i,
    input  wire [3:0] prod_sticky_i,
    output wire       sticky_o
);
  assign sticky_o = a_sticky_i | prod_sticky_i[0] | prod_sticky_i[1] |
                     prod_sticky_i[2] | prod_sticky_i[3];
endmodule
