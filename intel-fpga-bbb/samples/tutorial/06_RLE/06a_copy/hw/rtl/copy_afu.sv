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
        if (csrs.cpu_wr_csrs[0].en)
        begin
            input_addr <= byteAddrToClAddr(csrs.cpu_wr_csrs[0].data);
            $display("Received input address: 0x%x", byteAddrToClAddr(csrs.cpu_wr_csrs[0].data));
        end

        if (csrs.cpu_wr_csrs[1].en)
        begin
            input_length <= csrs.cpu_wr_csrs[1].data;
            $display("Received input length: %0d", csrs.cpu_wr_csrs[1].data);
        end

        if (csrs.cpu_wr_csrs[2].en)
        begin
            output_addr <= byteAddrToClAddr(csrs.cpu_wr_csrs[2].data);
            $display("Received output address: 0x%x", byteAddrToClAddr(csrs.cpu_wr_csrs[2].data));
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

    logic rd_end_of_input; //flag only for state change
    logic wr_done; //flag only for state change

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
                        $display("AFU starting at 0x%x", input_addr);
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

              STATE_END_OF_INPUT:
                begin
                    if (wr_done)
                    begin
                        state <= STATE_DONE;
                        $display("AFU write last result to 0x%x", wr_addr);
                    end
                end

              STATE_DONE:
                begin
                    if (! fiu.c1TxAlmFull) //this if is probably useless
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

    //cl rd addr
    t_cci_clAddr rd_addr;
    t_cci_clAddr rd_addr_next;
    logic rd_addr_next_valid;
    
    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            rd_addr_next_valid <= 1'b0;
            rd_end_of_input <= 1'b0;
        end
        else
        begin
            rd_addr_next_valid <= cci_c0Rx_isReadRsp(fiu.c0Rx);
            rd_addr_next <= (cci_c0Rx_isReadRsp(fiu.c0Rx) ? rd_addr + 1 : rd_addr);

            if (cci_c0Rx_isReadRsp(fiu.c0Rx))
            begin
                $display("Read rsp %x", rd_addr[3:0]);
            end

            if (cci_c0Rx_isReadRsp(fiu.c0Rx) && (rd_addr == input_addr + input_length - 1))
            begin
                rd_end_of_input <= 1'b1;
            end
        end
    end

    logic rd_needed;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            rd_needed <= 1'b0;
        end
        else
        begin
            if (rd_needed)
            begin
                rd_needed <= fiu.c0TxAlmFull;
            end
            else
            begin
                rd_needed <= (start || (rd_addr_next_valid && (state == STATE_RUN)));
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
            fiu.c0Tx <= cci_mpf_genC0TxReadReq(rd_hdr, (rd_needed && (state == STATE_RUN) && ! fiu.c0TxAlmFull));

            if (rd_needed && (state == STATE_RUN) && ! fiu.c0TxAlmFull)
            begin
                // $display("    Read req from VA: 0x%x", rd_addr);
                $display("Read req %x", rd_addr[3:0]);
            end
        end
    end

    logic [511:0] data_in;
    logic data_in_en;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            data_in_en <= 1'b0;
            data_in <= 512'b0;
        end
        else
        begin
            data_in_en <= cci_c0Rx_isReadRsp(fiu.c0Rx);
            if (cci_c0Rx_isReadRsp(fiu.c0Rx))
            begin
                data_in <= fiu.c0Rx.data[511:0];
            end

            // if (cci_c0Rx_isReadRsp(fiu.c0Rx))
            // begin
            //     $display("    Received values: 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x\n    0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x",
            //         fiu.c0Rx.data[31:0],
            //         fiu.c0Rx.data[63:32],
            //         fiu.c0Rx.data[95:64],
            //         fiu.c0Rx.data[127:96],
            //         fiu.c0Rx.data[159:128],
            //         fiu.c0Rx.data[191:160],
            //         fiu.c0Rx.data[223:192],
            //         fiu.c0Rx.data[255:224],
            //         fiu.c0Rx.data[287:256],
            //         fiu.c0Rx.data[319:288],
            //         fiu.c0Rx.data[351:320],
            //         fiu.c0Rx.data[383:352],
            //         fiu.c0Rx.data[415:384],
            //         fiu.c0Rx.data[447:416],
            //         fiu.c0Rx.data[479:448],
            //         fiu.c0Rx.data[511:480]
            //     );
            // end
        end
    end


    //TODO
    //compression
    //  can be fake- just something to change data size somehow
    //circular buffer

    // =========================================================================
    //
    //   Write logic.
    //
    // =========================================================================

    
    logic buffer_consumed; //set once input all contents have been consumed from buffer- tbd

    t_cci_clAddr wr_addr_next;
    logic wr_addr_next_valid;
    logic data_in_en_happened;
    logic write_rsp_happened;
    logic first_write;
    logic first_write_flag;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            wr_addr_next_valid <= 1'b0;
            data_in_en_happened <= 1'b0;
            write_rsp_happened <= 1'b1;
            first_write <= 1'b0;
            first_write_flag <= 1'b1;
            wr_done <= 1'b0;
        end
        else
        begin
            if (data_in_en_happened && write_rsp_happened)
            begin
                // $display("data_in_en_happened && write_rsp_happened");
                wr_addr_next_valid <= 1'b1;
                wr_addr_next <= wr_addr + 1;
                if (first_write_flag)
                begin
                    first_write <= 1'b1;
                    first_write_flag <= 1'b0;
                end
                else
                begin
                    first_write <= 1'b0;
                end

                data_in_en_happened <= data_in_en ? 1'b1 : 1'b0;
                write_rsp_happened <= cci_c1Rx_isWriteRsp(fiu.c1Tx) ? 1'b1 : 1'b0;
            end
            else
            begin
                wr_addr_next_valid <= 1'b0;
                wr_addr_next <= wr_addr;

                //assume 1 req in flight for both read and write
                //so, data_in_en would never be set while data_in_en_happened is set
                //because a write rsp must have happened in the meantime

                if (data_in_en)
                begin
                    // $display("data_in_en");
                    // $display("%x", data_in);
                    data_in_en_happened <= 1'b1;
                end

                if (cci_c1Rx_isWriteRsp(fiu.c1Tx))
                begin
                    $display("Write rsp %x", wr_addr[3:0]);
                    if (buffer_consumed)
                    begin
                        wr_done <= 1'b1;
                    end
                    write_rsp_happened <= 1'b1;
                end
            end
        end
    end

    logic wr_needed;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            wr_needed <= 1'b0;
            wr_addr <= 0;
        end
        else
        begin
            if (wr_needed)
            begin
                wr_needed <= fiu.c1TxAlmFull; //'TxAlmFull' for both rd and wr
            end
            else
            begin
                wr_needed <= (wr_addr_next_valid && ! buffer_consumed);
                wr_addr <= (first_write ? output_addr : wr_addr_next); //replace start with something more sensible. oh jeez @ -1
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
            buffer_consumed <= 1'b0;
        end
        else
        begin
            if (wr_needed && ! fiu.c1TxAlmFull)
            begin
                // $display("    Write req to VA: 0x%x", wr_addr);
                $display("Write req %x", wr_addr[3:0]);
                // $display("%x", data_in);
                if (state == STATE_END_OF_INPUT)
                begin
                    buffer_consumed <= 1'b1;
                end
            end
            fiu.c1Tx <= cci_mpf_genC1TxWriteReq(wr_hdr, data_in, (wr_needed && ! fiu.c1TxAlmFull));
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