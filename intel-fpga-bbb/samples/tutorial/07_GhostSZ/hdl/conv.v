`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/03/2019 03:58:21 PM
// Design Name: 
// Module Name: conv
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


module conv(
	 input rst,
    input clk,
    input [31:0] data,
    output overflow,
    output [15:0] result,
    output underflow
    );
fl2in core(
		.a(data),      //      a.a
		.areset(rst), // areset.reset
		.clk(clk),    //    clk.clk
		.q(result)       //      q.q
	);    
//``overflow'' and ``underflow'' is not available for current board; manually generate
//assign underflow = (result == 16'h8000) ;  //<=-32768 
//assign overflow = (result == 16'h7fff);  //>=32767
assign underflow = (result[15] ==1'b1)? ((-result) > 8191) : 'b0;
assign overflow = (result[15] ==1'b0)? (result > 8191) : 'b0;

endmodule
