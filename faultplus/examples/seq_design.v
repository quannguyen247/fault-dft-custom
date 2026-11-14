module seq_design (
  input  wire clk,
  input  wire rst,
  input  wire [1:0] in_d,
  output reg  [1:0] out_q
);
  always @(posedge clk or posedge rst) begin
    if (rst)
      out_q <= 2'b00;
    else
      out_q <= in_d;
  end
endmodule
