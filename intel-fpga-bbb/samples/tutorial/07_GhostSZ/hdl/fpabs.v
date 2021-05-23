`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/01/2019 12:00:21 PM
// Design Name: 
// Module Name: fpabs
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


module fpabs(
    input [31:0] data,
    output [31:0] result
    );
    

fabs_arria10 core(
		.a(data),      //      a.a
		.areset(0), // areset.reset
		.clk(),    //    clk.clk
		.q(result)       //      q.q
	);
endmodule
