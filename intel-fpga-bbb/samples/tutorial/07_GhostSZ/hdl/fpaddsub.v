`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/01/2019 11:40:56 AM
// Design Name: 
// Module Name: fpaddsub
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


module fpaddsub(
    add_sub, //1 for add, 0 for sub
	clock,
	dataa,
	datab,
	result	
    );
parameter IN_WIDTH=32;

input wire clock, add_sub;
input wire [IN_WIDTH-1:0] dataa,datab;
output wire [IN_WIDTH-1:0] result;


fpas core(
		.a(dataa),      //      a.a
		.areset(0), // areset.reset
		.b(datab),      //      b.b
		.clk(clock),    //    clk.clk
		.q(result),      //      q.q
		.opSel(add_sub)       //      s.s
	);
	
endmodule
