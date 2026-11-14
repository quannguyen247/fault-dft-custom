`timescale 1ns/1ps
module tb_scan;
reg clk=0,rst=1,sin=0,shift=1,tck=0,test=1;
reg [1:0] in_d=0;
wire [1:0] out_q;
wire sout;
reg [11:0] data=12'b011011001101;
integer i;
seq_design dut(.clk(clk),.rst(rst),.in_d(in_d),.out_q(out_q),.sin(sin),.shift(shift),.sout(sout),.tck(tck),.test(test));
initial begin
  #2 rst=0;
  for (i=0; i<12; i=i+1) begin
    sin=data[i]; #5 tck=1; #1;
    if (i>=5 && sout !== data[i-5]) $fatal(1,"scan mismatch i=%0d expected=%b actual=%b",i,data[i-5],sout);
    #4 tck=0;
  end
  $display("FAULTPLUS_SCAN_PASS"); $finish;
end
endmodule
