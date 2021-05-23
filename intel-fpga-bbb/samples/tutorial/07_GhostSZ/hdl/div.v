`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/03/2019 04:13:16 PM
// Design Name: 
// Module Name: div
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


module div(
    input clk,
	 input rst,
    input [31:0] a,
    input [31:0] b,
    output [31:0] res
    );
    
divide core(
		.a(a),      //      a.a
		.areset(rst), // areset.reset
		.b(b),      //      b.b
		.clk(clk),    //    clk.clk
		.q(res)       //      q.q
	);
    
endmodule
