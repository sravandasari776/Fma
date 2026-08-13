// Generic width-parameterized 3:2 carry-save compressor (full-adder per
// bit). sum_o[i] = a[i]^b[i]^c[i]; carry_o[i] is the majority function of
// bit i, already weight-aligned (carry_o[0]=0, carry_o[i+1]=maj(a[i],b[i],
// c[i])) so that sum_o + carry_o (ordinary binary addition) reproduces
// a+b+c. Reused by every named "CSA"/"CSA 4:2"/"3-to-2 CSA" block in the
// design (6.3, 7.7, 8.1).
module csa32 #(
    parameter W = 48
) (
    input  wire [W-1:0] a_i, b_i, c_i,
    output wire [W-1:0] sum_o,
    output wire [W-1:0] carry_o
);
  wire [W-1:0] maj;
  assign sum_o = a_i ^ b_i ^ c_i;
  assign maj = (a_i & b_i) | (b_i & c_i) | (a_i & c_i);
  assign carry_o = maj << 1; // weight-aligned; top overflow bit is a don't-care given guard-bit headroom upstream
endmodule
