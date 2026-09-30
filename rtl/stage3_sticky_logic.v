// MPFMA-DS-001 8.2 - Sticky Logic.
// OR-reduces every bit discarded during Stage-2 alignment (addend +
// up to 4 products) into a single sticky bit carried forward for
// round-to-nearest-even in Stage 4.
//
// The alignment shifters also "jam" those lost bits into bit 0 of each
// aligned term (align_shifter.v), which is what carries the *sign* of a
// lost remainder through the signed addition; whenever exactly one term
// lost bits this makes the accumulated value itself inexact, so this OR is
// then redundant with it, and is kept as the explicit "alignment was
// inexact" flag that Fig. 3 of the source paper draws.
module stage3_sticky_logic (
    input  wire       a_sticky_i,
    input  wire [3:0] prod_sticky_i,
    output wire       sticky_o
);
  assign sticky_o = a_sticky_i | prod_sticky_i[0] | prod_sticky_i[1] |
                     prod_sticky_i[2] | prod_sticky_i[3];
endmodule
