`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/09/2019 12:21:38 PM
// Design Name: 
// Module Name: mult
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module mult(
    input rst,
    input clk,
    input [31:0] a,
    input [31:0] b,
    output [31:0] res
    );
    
multiply core(
		.a(a),      //      a.a
		.areset(rst), // areset.reset
		.b(b),      //      b.b
		.clk(clk),    //    clk.clk
		.q(res)       //      q.q
	);
    
endmodule
