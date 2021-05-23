/*qx, CAAD, BU, 12022018*/


module sz(
	rst,
	clk,
	data_in,
   enable, //new added to tell the pipelines the data is here
	hold
);

parameter TYPE='b00;   //00:float; 01:double; 10: int; 11: float 
parameter WIDTH= 32; 
parameter OUT_WIDTH=2;
//parameter ERROR = 0.0001;  //absolute error
//stream data in from DRAM; having a FIFO/buffer to store
wire [WIDTH-1:0] data_in,dram_in,dram_out;
wire [OUT_WIDTH-1:0] data_out;




wire [WIDTH-1:0] omit; 

/*******************Out of Order Fitting*********************/

wire [1:0] data_out;
wire [31:0] phase3_data_out;
wire [15:0] phase2_data_out; // quant is 14 bits
wire phase2_valid, data_out_valid;
wire phase3_valid;

sz_inner sz0(
    rst,
    clk,
    data_in,
    enable,
	 hold,
    data_out,
	 data_out_valid,
    phase2_data_out,
    phase2_valid,
    phase3_data_out,
    phase3_valid
);

//Gzip; removed gzip for opensource

//get the output, store in the buffer, and store into DRAM
//removed dram for Opensource



endmodule








