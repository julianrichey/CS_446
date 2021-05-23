`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/09/2019 03:55:31 PM
// Design Name: 
// Module Name: conv_fix2flt
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


module conv_fix2flt(
    input clk,
    input [31:0] a,
    output [31:0] res
    );
    
fix2flt core(
		.a(a),      //      a.a
		.areset(0), // areset.reset
		.clk(clk),    //    clk.clk
		.q(res)       //      q.q
	);
    
endmodule
