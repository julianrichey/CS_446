`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/09/2019 01:05:33 PM
// Design Name: 
// Module Name: sub_fast
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


module sub_fast(
    input clk,
    input [31:0] a,
    input [31:0] b,
    output [31:0] res
    );
    
subfast core(
		.a(a),      //      a.a
		.areset(0), // areset.reset
		.b(b),      //      b.b
		.clk(clk),    //    clk.clk
		.q(res)       //      q.q
	);
    
endmodule
