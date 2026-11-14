`timescale 1ns/1ps

module INV (input A, output Y);
  assign Y = ~A;
endmodule

module BUF (input A, output Y);
  assign Y = A;
endmodule

module NAND2 (input A, input B, output Y);
  assign Y = ~(A & B);
endmodule

module NOR2 (input A, input B, output Y);
  assign Y = ~(A | B);
endmodule

module AND2 (input A, input B, output Y);
  assign Y = A & B;
endmodule

module OR2 (input A, input B, output Y);
  assign Y = A | B;
endmodule

module XOR2 (input A, input B, output Y);
  assign Y = A ^ B;
endmodule

module DFFARX1 (input CLK, input RST, input D, output reg Q);
  always @(posedge CLK or posedge RST) begin
    if (RST)
      Q <= 1'b0;
    else
      Q <= D;
  end
endmodule

module SDFFARX1 (input CLK, input RST, input D, input SI, input SE, output reg Q);
  always @(posedge CLK or posedge RST) begin
    if (RST)
      Q <= 1'b0;
    else
      Q <= SE ? SI : D;
  end
endmodule
