//
// Copyright (c) 2017, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

`include "cci_mpf_if.vh"
`include "csr_mgr.vh"
`include "afu_json_info.vh"


module app_afu
   (
    input  logic clk,

    // Connection toward the host.  Reset comes in here.
    cci_mpf_if.to_fiu fiu,

    // CSR connections
    app_csrs.app csrs,

    // MPF tracks outstanding requests.  These will be true as long as
    // reads or unacknowledged writes are still in flight.
    input  logic c0NotEmpty,
    input  logic c1NotEmpty
    );

    // Local reset to reduce fan-out
    logic reset = 1'b1;
    always @(posedge clk)
    begin
        reset <= fiu.reset;
    end


    //
    // Convert between byte addresses and line addresses.  The conversion
    // is simple: adding or removing low zero bits.
    //

    localparam CL_BYTE_IDX_BITS = 6;
    typedef logic [$bits(t_cci_clAddr) + CL_BYTE_IDX_BITS - 1 : 0] t_byteAddr;

    function automatic t_cci_clAddr byteAddrToClAddr(t_byteAddr addr);
        return addr[CL_BYTE_IDX_BITS +: $bits(t_cci_clAddr)];
    endfunction

    function automatic t_byteAddr clAddrToByteAddr(t_cci_clAddr addr);
        return {addr, CL_BYTE_IDX_BITS'(0)};
    endfunction


    // ====================================================================
    //
    //  CSRs (simple connections to the external CSR management engine)
    //
    // ====================================================================

    // Count bytes generated and export in CSR 3.
    logic [15:0] output_length;

    // Set when afu finishes. 
    logic done;

    // logic [15:0] cnt_list_length;

    always_comb
    begin
        // The AFU ID is a unique ID for a given program.  Here we generated
        // one with the "uuidgen" program and stored it in the AFU's JSON file.
        // ASE and synthesis setup scripts automatically invoke afu_json_mgr
        // to extract the UUID into afu_json_info.vh.
        csrs.afu_id = `AFU_ACCEL_UUID;

        // Default
        for (int i = 0; i < NUM_APP_CSRS; i = i + 1)
        begin
            csrs.cpu_rd_csrs[i].data = 64'(0);
        end

        // Exported counters.  The simple csrs interface used here has
        // no read request.  It expects the current CSR value to be
        // available every cycle.
        csrs.cpu_rd_csrs[3].data = 64'(output_length);
        csrs.cpu_rd_csrs[4].data = 64'(done);
    end


    //
    // Consume configuration CSR writes
    //

    // First memory address to which this AFU will write the result
    t_ccip_clAddr output_addr;

    // CSR 4 write triggers afu start
    logic start;
    t_ccip_clAddr input_addr;

    // Number of elements (lines)
    logic [15:0] input_length;

    always_ff @(posedge clk)
    begin
        if (csrs.cpu_wr_csrs[4].en)
        begin
            input_addr <= byteAddrToClAddr(csrs.cpu_wr_csrs[0].data);
            input_length <= csrs.cpu_wr_csrs[1].data;
            output_addr <= byteAddrToClAddr(csrs.cpu_wr_csrs[2].data);
        end

        start <= csrs.cpu_wr_csrs[4].en;
    end

//rather than doing a single write at the end (state_write_result)
//write while in state_run
    // =========================================================================
    //
    //   State machine
    //
    // =========================================================================

    typedef enum logic [1:0]
    {
        STATE_IDLE,
        STATE_RUN,
        STATE_END_OF_INPUT,
        STATE_DONE
    }
    t_state;

    t_state state;
    // Status signals that affect state changes
    logic rd_end_of_input;
    // logic rd_last_beat_received;
    logic data_in_en;
    t_cci_clAddr wr_addr;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            done <= 1'b0;
            output_length <= 16'b0;
            state <= STATE_IDLE;
        end
        else
        begin
            case (state)
              STATE_IDLE:
                begin
                    // Reading begins when CSR 4 is written
                    if (start)
                    begin
                        done <= 1'b0;
                        output_length <= 16'b0;
                        state <= STATE_RUN;
                        $display("AFU starting at 0x%x",
                                 clAddrToByteAddr(input_addr));
                    end
                end

              STATE_RUN:
                begin
                    // rd_end_of_input is set once as input_length lines are read
                    if (rd_end_of_input)
                    begin
                        state <= STATE_END_OF_INPUT;
                        $display("AFU reached end of input");
                    end
                end

              STATE_END_OF_INPUT: //TODO: figure out how states change from here.
                begin
                    if (data_in_en) //rd_last_beat_received needed to wait for 4 lines. only using 1 line, so use first (only) response
                    begin
                        state <= STATE_DONE;
                        $display("AFU write result to 0x%x",
                                 clAddrToByteAddr(wr_addr));
                    end
                end

              STATE_DONE:
                begin
                    if (! fiu.c1TxAlmFull)
                    begin
                        done <= 1'b1;
                        output_length <= wr_addr - output_addr + 1;
                        state <= STATE_IDLE;
                        $display("AFU done");
                    end
                end
            endcase
        end
    end


    // =========================================================================
    //
    //   Read logic.
    //
    // =========================================================================

    t_cci_clAddr rd_addr;
    t_cci_clAddr rd_addr_next;
    logic rd_addr_next_valid;
    
    always_ff @(posedge clk)
    begin
        rd_addr_next_valid <= cci_c0Rx_isReadRsp(fiu.c0Rx);
        rd_addr_next <= rd_addr + 1;
        //rd_addr or rd_addr_next? probably rd_addr_next because in example,
        //rd_end_of_input is set once rd_addr_next is NULL
        rd_end_of_input <= (rd_addr_next == (input_addr + input_length));
    end

    //hold request until can be sent (have next address, not full)
    logic rd_needed;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            rd_needed <= 1'b0;
        end
        else
        begin
            //might want more than one read in flight? just one for now, keep current rd_needed logic
            if (rd_needed)
            begin
                rd_needed <= fiu.c0TxAlmFull;
            end
            else
            begin
                //rd_addr_next_valid always set, could slow down input by setting every x cycles
                rd_needed <= (start || (rd_addr_next_valid && ! rd_end_of_input));
                rd_addr <= (start ? input_addr : rd_addr_next);
            end
        end
    end

    //construct request
    t_cci_mpf_c0_ReqMemHdr rd_hdr;
    t_cci_mpf_ReqMemHdrParams rd_hdr_params;

    always_comb
    begin
        rd_hdr_params = cci_mpf_defaultReqHdrParams(1);
        rd_hdr_params.vc_sel = eVC_VA;
        rd_hdr_params.cl_len = eCL_LEN_1; //read one line for now?
        rd_hdr = cci_mpf_c0_genReqHdr(
            eREQ_RDLINE_I,
            rd_addr,
            t_cci_mdata'(0),
            rd_hdr_params
        );
    end

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            fiu.c0Tx.valid <= 1'b0;
        end
        else
        begin
            fiu.c0Tx <= cci_mpf_genC0TxReadReq(rd_hdr, (rd_needed && ! fiu.c0TxAlmFull));
            // if (rd_needed && ! fiu.c0TxAlmFull)
            // begin
            //     $display("  Reading from VA 0x%x", clAddrToByteAddr(rd_addr));
            // end
        end
    end

    logic [511:0] data_in;

//interesting... each line comes indepently on the bus, right?
//if all being added to the hash and order matteres, bus maintains order?
    always_ff @(posedge clk)
    begin
        data_in_en <= cci_c0Rx_isReadRsp(fiu.c0Rx);
        data_in <= fiu.c0Rx.data[511:0];

        // if (cci_c0Rx_isReadRsp(fiu.c0Rx))
        // begin
        //     $display("    Received entry v: %0d", fiu.c0Rx.data[511:0]);
        // end
    end


    // =========================================================================
    //
    //   Write logic.
    //
    // =========================================================================

    t_cci_clAddr wr_addr_next;
    logic wr_addr_next_valid; //delete? maybe not if need to check against upper bound, if it exists

    always_ff @(posedge clk)
    begin
        wr_addr_next_valid <= cci_c1Rx_isWriteRsp(fiu.c1Tx); 
        wr_addr_next <= wr_addr + 1;
    end

    //hold request until can be sent (have next address, not full)
    logic wr_needed; //just assume we can always write? or does the example skip checking bc only one write???
    logic buffer_consumed; //set once input contents have been consumed from buffer
    assign buffer_consumed = rd_end_of_input; //for copy, buffer not used

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            wr_needed <= 1'b0;
        end
        else
        begin
            //might want more than one write in flight? just one for now, keep current wr_needed logic
            if (wr_needed)
            begin
                wr_needed <= fiu.c1TxAlmFull; //'TxAlmFull' for both rd and wr?
            end
            else
            begin
                //wr_addr_next_valid always set, could slow down input by setting every x cycles
                wr_needed <= (start || (wr_addr_next_valid || ! buffer_consumed));
                wr_addr <= (start ? output_addr : wr_addr_next);
            end
        end
    end

    //construct request
    t_cci_mpf_c1_ReqMemHdr wr_hdr;
    t_cci_mpf_ReqMemHdrParams wr_hdr_params;

    always_comb
    begin
        wr_hdr_params = cci_mpf_defaultReqHdrParams(1);
        wr_hdr_params.vc_sel = eVC_VA;
        wr_hdr_params.cl_len = eCL_LEN_1;
        wr_hdr = cci_mpf_c1_genReqHdr(
            eREQ_WRLINE_I,
            wr_addr,
            t_cci_mdata'(0),
            wr_hdr_params
        );
    end

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            fiu.c1Tx.valid <= 1'b0;
        end
        else
        begin
            fiu.c1Tx <= cci_mpf_genC1TxWriteReq(wr_hdr, data_in, data_in_en);
        end
    end


    //
    // This AFU never handles MMIO reads.  MMIO is managed in the CSR module.
    //
    assign fiu.c2Tx.mmioRdValid = 1'b0;

endmodule // app_afu














/*
once compressing, writing will probably get harder
need a fifo probably???
if an input is x bits wide
the output could be x-y or x+y or x or whatever bits wide
likely shove it all into a fifo that gets consumed down here


beneath is a fifo
it needs to take in an extra input, din_used
x bits of input data gets converted to y bits of compressed data
assume that y can be any value up to some multiple of x, set din width
app_afu will give this the width of y

something like this may also need to happen on the input???
example: if doing a RLE, where the maximum run it can encode is
    256 bits for example, would need a fifo(?) up front that keeps
    on recording if the input is repeatedly the same
would this even be a fifo? could it be just part of the read logic?


TODO: this fifo is currently doesnt take in din_used and is written
    in verilog
make q 1d, just a long circular buffer
output 32 bits every cycle rd_en is set
will need parameters: input width, size, output width

*/

/*
`define CLOG2(x) \
    (x <= 2) ? 1 : \
    (x <= 4) ? 2 : \
    (x <= 8) ? 3 : \
    (x <= 16) ? 4 : \
    (x <= 32) ? 5 : \
    (x <= 64) ? 6 : \
    (x <= 128) ? 7 : \
    (x <= 256) ? 8 : \
    (x <= 512) ? 9 : \
    (x <= 1024) ? 10 : \
    (x <= 2048) ? 11 : \
    (x <= 4096) ? 12 : \
    -1

module fifo #(
    parameter FIFO_BUFFER_SIZE,
    parameter FIFO_DATA_WIDTH
) (
    input reset,

    input wr_clk,
    input wr_en,
    input [FIFO_DATA_WIDTH-1:0] din,
    output reg full,

    input rd_clk,
    input rd_en,
    output reg [FIFO_DATA_WIDTH-1:0] dout,
    output reg empty
);
    //{} for +1 overflow (e.g. depth=8)
    localparam idx_width = {1'b0, `CLOG2(FIFO_BUFFER_SIZE)} + 1;

    reg [FIFO_DATA_WIDTH-1:0] q [FIFO_BUFFER_SIZE-1:0];
    reg [idx_width-1:0] wr_idx;
    reg [idx_width-1:0] rd_idx;

    assign dout = q[rd_idx[idx_width-2:0]];
    assign empty = wr_idx == rd_idx;
    assign full = (wr_idx[idx_width-1] != rd_idx[idx_width-1]) && 
                  (wr_idx[idx_width-2:0] == rd_idx[idx_width-2:0]);

    integer i;
    always @(posedge wr_clk) begin
        if (reset) begin
            wr_idx <= 0;
            for (i=0; i<FIFO_BUFFER_SIZE; i=i+1) q[i] <= 0;
        end else if (wr_en) begin
            q[wr_idx[idx_width-2:0]] <= din;
            wr_idx <= wr_idx + 1;
        end
    end

    always @(posedge rd_clk) begin
        if (reset) begin
            rd_idx <= 0;
        end else if (rd_en) begin
            rd_idx <= rd_idx + 1;
        end
    end
endmodule
*/