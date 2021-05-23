`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/01/2019 04:17:21 PM
// Design Name: 
// Module Name: comp
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


module comp(
    input clock,
    input [31:0] dataa,
    input [31:0] datab,
    output alb
    );


lessthan core(
		.a(dataa),      //      a.a
		.areset(0), // areset.reset
		.b(datab),      //      b.b
		.clk(clock),    //    clk.clk
		.q(alb)       //      q.q
	);
endmodule
