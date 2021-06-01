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
    logic [15:0] output_counter;

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
        csrs.cpu_rd_csrs[3].data = 64'(output_counter);
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

    // Number of elements 
    logic [15:0] input_length;

    always_ff @(posedge clk)
    begin
        if (csrs.cpu_wr_csrs[4].en)
        begin
            input_addr <= byteAddrToClAddr(csrs.cpu_wr_csrs[0].data);
            input_length <= byteAddrToClAddr(csrs.cpu_wr_csrs[1].data);
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
        STATE_WRITE_RESULT
    }
    t_state;

    t_state state;
    // Status signals that affect state changes
    logic rd_end_of_input;
    logic rd_last_beat_received;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
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
                        state <= STATE_RUN;
                        $display("AFU starting at 0x%x",
                                 clAddrToByteAddr(input_addr));
                    end
                end

              STATE_RUN:
                begin
                    // rd_end_of_input is set once as input_length elements are read
                    if (rd_end_of_input)
                    begin
                        state <= STATE_END_OF_INPUT;
                        $display("AFU reached end of input");
                    end
                end

              STATE_END_OF_INPUT: //TODO: figure out how states change from here.
                begin
                    if (rd_last_beat_received) //rename
                    begin
                        state <= STATE_WRITE_RESULT;
                        $display("AFU write result to 0x%x",
                                 clAddrToByteAddr(output_addr));
                    end
                end

              STATE_WRITE_RESULT:
                begin
                    if (! fiu.c1TxAlmFull) //change
                    begin
                        state <= STATE_IDLE;
                        $display("AFU done");
                    end
                end
            endcase
        end
    end

//this simplifies a ton bc no longer worried about pointer chasing
//instead, just increment addr_next and compare it to input_length rather than check for null ptr
//NOTE: start editing here
    // =========================================================================
    //
    //   Read logic.
    //
    // =========================================================================

    logic [15:0] input_counter;
    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            input_counter <= 16'b0;
        end
        else
        begin
            if (start)
            begin
                input_counter <= 16'b1;
            end
            else if (input_counter == input_length - 1) //TODO: potential off by 1
            begin
                rd_end_of_input <= 1'b1; //hold counter until reset or start
            end
            else if (input_counter != 16'b0) //add condition if there is any reason to delay incrementing memory.. fiu stuff
            begin
                input_counter <= input_counter + 16'b1;
            end
        end
    end







    //
    // READ REQUEST
    //

    // Did a read response just arrive containing a pointer to the next entry
    // in the list?
    logic addr_next_valid;

    // When a read response contains a next pointer, this is the next address.
    t_cci_clAddr addr_next;

    always_ff @(posedge clk)
    begin
        // Read response from the first line in a 4 line group?  The next
        // pointer is in the first line of each 4-line object.  The read
        // response header's cl_num is 0 for the first line.
        addr_next_valid <= cci_c0Rx_isReadRsp(fiu.c0Rx) &&
                           (fiu.c0Rx.hdr.cl_num == t_cci_clNum'(0));

        // Next address is in the low word of the line
        addr_next <= byteAddrToClAddr(fiu.c0Rx.data[63:0]);

        // End of list reached if the next address is NULL.  This test
        // is a combination of the same state setting addr_next_valid
        // this cycle, with the addition of a test for a NULL next address.
// (addr_next == input length) or something
        rd_end_of_input <= (byteAddrToClAddr(fiu.c0Rx.data[63:0]) == t_cci_clAddr'(0)) &&
                          cci_c0Rx_isReadRsp(fiu.c0Rx) &&
                          (fiu.c0Rx.hdr.cl_num == t_cci_clNum'(0));
    end

//this should actually stay the exact same?
    //
    // Since back pressure may prevent an immediate read request, we must
    // record whether a read is needed and hold it until the request can
    // be sent to the FIU.
    //
    t_cci_clAddr rd_addr;
    logic rd_needed;

    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            rd_needed <= 1'b0;
        end
        else
        begin
            // If reads are allowed this cycle then we can safely clear
            // any previously requested reads.  This simple AFU has only
            // one read in flight at a time since it is walking a pointer
            // chain.
            if (rd_needed)
            begin
                rd_needed <= fiu.c0TxAlmFull;
            end
            else
            begin
                // Need a read under two conditions:
                //   - Starting a new walk
                //   - A read response just arrived from a line containing
                //     a next pointer.
                rd_needed <= (start || (addr_next_valid && ! rd_end_of_input));
                rd_addr <= (start ? input_addr : addr_next);
            end
        end
    end


    //
    // Emit read requests to the FIU.
    //

    // Read header defines the request to the FIU
    t_cci_mpf_c0_ReqMemHdr rd_hdr;
    t_cci_mpf_ReqMemHdrParams rd_hdr_params;

    always_comb
    begin
        // Use virtual addresses
        rd_hdr_params = cci_mpf_defaultReqHdrParams(1);
        // Let the FIU pick the channel
        rd_hdr_params.vc_sel = eVC_VA;
        // Read 4 lines (the size of an entry in the list)
        rd_hdr_params.cl_len = eCL_LEN_4;

        // Generate the header
        rd_hdr = cci_mpf_c0_genReqHdr(eREQ_RDLINE_I,
                                      rd_addr,
                                      t_cci_mdata'(0),
                                      rd_hdr_params);
    end

    // Send read requests to the FIU
    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            fiu.c0Tx.valid <= 1'b0;
            // cnt_list_length <= 0;
        end
        else
        begin
            // Generate a read request when needed and the FIU isn't full
            fiu.c0Tx <= cci_mpf_genC0TxReadReq(rd_hdr,
                                               (rd_needed && ! fiu.c0TxAlmFull));

            if (rd_needed && ! fiu.c0TxAlmFull)
            begin
                // cnt_list_length <= cnt_list_length + 1;
                $display("  Reading from VA 0x%x", clAddrToByteAddr(rd_addr));
            end
        end
    end


    //
    // READ RESPONSE HANDLING
    //
//no hash
    //
    // Registers requesting the addition of read data to the hash.
    //
    logic hash_data_en;
    logic [31:0] hash_data;
    // The cache-line number of the associated data is recorded in order
    // to figure out when reading is complete.  We will have read all
    // the data when the 4th beat of the final request is read.
    t_cci_clNum hash_cl_num;

    //
    // Receive data (read responses).
    //
    always_ff @(posedge clk)
    begin
        // A read response is data if the cl_num is non-zero.  (When cl_num
        // is zero the response is a pointer to the next record.)
        hash_data_en <= (cci_c0Rx_isReadRsp(fiu.c0Rx) &&
                         (fiu.c0Rx.hdr.cl_num != t_cci_clNum'(0)));
        hash_data <= fiu.c0Rx.data[31:0];
        hash_cl_num <= fiu.c0Rx.hdr.cl_num;

        if (cci_c0Rx_isReadRsp(fiu.c0Rx) &&
            (fiu.c0Rx.hdr.cl_num != t_cci_clNum'(0)))
        begin
            $display("    Received entry v%0d: %0d",
                     fiu.c0Rx.hdr.cl_num, fiu.c0Rx.data[63:0]);
        end
    end


    //
    // Signal completion of reading a line.  The state machine consumes this
    // to transition from END_OF_LIST to WRITE_RESULT.
    //
    assign rd_last_beat_received = hash_data_en &&
                                   (hash_cl_num == t_cci_clNum'(3));

    //
    // Compute a hash of the received data.
    //
    logic [31:0] hash_value;

    hash32
      hash
       (
        .clk,
        .reset(reset || start),
        .en(hash_data_en),
        .new_data(hash_data),
        .value(hash_value)
        );


    // //
    // // Count the number of fields read and added to the hash.
    // //
    // always_ff @(posedge clk)
    // begin
    //     if (reset || start)
    //     begin
    //         output_counter <= 0;
    //     end
    //     else if (hash_data_en)
    //     begin
    //         output_counter <= output_counter + 1;
    //     end
    // end
















//writing out lots of data, not just a hash. should be similar to what read ends up looking like
    // =========================================================================
    //
    //   Write logic.
    //
    // =========================================================================


    // always_ff @(posedge clk)
    // begin
    //     if (reset)
    //     begin
    //         output_counter <= 1'b0;
    //     end
    //     else
    //     begin
    //         //TODO: how to count these?
    //         //for memcpy, just use input_counter
    //     end
    // end










    // Construct a memory write request header.  For this AFU it is always
    // the same, since we write to only one address.
    t_cci_mpf_c1_ReqMemHdr wr_hdr;
    assign wr_hdr = cci_mpf_c1_genReqHdr(eREQ_WRLINE_I,
                                         output_addr,
                                         t_cci_mdata'(0),
                                         cci_mpf_defaultReqHdrParams(1));

    // Data to write to memory.  The low word is a non-zero flag.  The
    // CPU-side software will spin, waiting for this flag.  The computed
    // hash is written in the 2nd 64 bit word.
    assign fiu.c1Tx.data = t_ccip_clData'({ hash_value, 64'h1 });
//is this 128bits/cycle? how to change address as it goes?
//once compressing, this will probably get harder
//need a fifo probably???
//if an input is x bits wide
//the output could be x-y or x+y or x or whatever bits wide
//likely shove it all into a fifo that gets consumed down here
//an alternative that just sends the compressed version of each element might kinda defeat the acceleration intent??
//like if the cpu had to come in and rearrange memory

    // Control logic for memory writes
    always_ff @(posedge clk)
    begin
        if (reset)
        begin
            fiu.c1Tx.valid <= 1'b0;
        end
        else
        begin
            // Request the write as long as the channel isn't full.
            fiu.c1Tx.valid <= ((state == STATE_WRITE_RESULT) && //will do the writing in the run state
                               ! fiu.c1TxAlmFull);
        end

        fiu.c1Tx.hdr <= wr_hdr;
    end


    //
    // This AFU never handles MMIO reads.  MMIO is managed in the CSR module.
    //
    assign fiu.c2Tx.mmioRdValid = 1'b0;

endmodule // app_afu














/*

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