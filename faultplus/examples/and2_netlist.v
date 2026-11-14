// A technology-mapped combinational example with an unused test clock/reset.
module and2_top(input clk, input rst, input a, input b, output y);
  AND2 u_and (.A(a), .B(b), .Y(y));
endmodule
