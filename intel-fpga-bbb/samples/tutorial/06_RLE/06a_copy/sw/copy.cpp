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

#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>

#include <iostream>
#include <string>
#include <atomic>

using namespace std;

#include "opae_svc_wrapper.h"
#include "csr_mgr.h"

using namespace opae::fpga::types;
using namespace opae::fpga::bbb::mpf::types;

#include "afu_json_info.h"

//for now, just use ints. ghostsz apparently uses ints, floats, and doubles
//read in one line at a time
//one line is 64 bytes, or 16 ints
const int LINE_BYTES = 64;
const int INPUT_LINES = 5; //arbitrary for now

typedef struct t_line
{
    int data[16];
}
t_line;

t_line* initMem(t_line* ptr) //ptr points to the first t_line
{
    t_line* p = ptr;
    int v = 1; //different contents will compress differently, replace this

    for (int i = 0; i < INPUT_LINES; i++)
    {
        for (int j = 0; j < 16; j++)
        {
            p->data[j] = v++;
        }

        //no need for this syntax rather than an array of t_lines, just staying close to the example
        t_line* p_next = (t_line*)(intptr_t(p) + LINE_BYTES);
        
        p = p_next;
    }

    std::atomic_thread_fence(std::memory_order_seq_cst);

    return ptr;
}

/*
CSRs
0: write ptr to input buffer
1: write number of lines in input buffer
2: write ptr to output buffer
3: read number of lines in used portion of output buffer
4: read whether the afu has finished

example reuses CSRs, but for no now need
*/

int main(int argc, char *argv[])
{
    OPAE_SVC_WRAPPER fpga(AFU_ACCEL_UUID);
    assert(fpga.isOk());
    CSR_MGR csrs(fpga);

    int input_bytes = INPUT_LINES * LINE_BYTES;
    auto input_buf_handle = fpga.allocBuffer(input_bytes);
    auto input_buf = reinterpret_cast<volatile t_line*>(input_buf_handle->c_type());
    assert(NULL != input_buf);
    cout << "input_buf= 0x" << hex << intptr_t(input_buf) << endl;
    csrs.writeCSR(0, intptr_t(input_buf)); //intptr_t -> uint64_t?
    cout << "input_lines= " << dec << INPUT_LINES << endl;
    csrs.writeCSR(1, INPUT_LINES);

    initMem(const_cast<t_line*>(input_buf));

    int output_bytes = input_bytes * 2; //adjust based on worst case
    auto output_buf_handle = fpga.allocBuffer(output_bytes);
    auto output_buf = reinterpret_cast<volatile int*>(output_buf_handle->c_type());
    assert(NULL != output_buf);
    output_buf[0] = 0; //probably delete this line
    cout << "output_buf= 0x" << hex << intptr_t(output_buf) << endl;
    csrs.writeCSR(2, intptr_t(output_buf));

    csrs.writeCSR(3, 0);
    csrs.writeCSR(4, 0); //fpga waiting for this

    struct timespec pause;
    pause.tv_sec = (fpga.hwIsSimulated() ? 1 : 0);
    pause.tv_nsec = 2500000; //could adjust this but probably doesnt matter

    //control signal indicating done
    //cant use normal output, as last written index not known ahead of time
    while (0 == csrs.readCSR(4))
    {
        cout << "CSR4=0 ";
        nanosleep(&pause, NULL);
    };

    //confirm output

    int v = 1;
    int n_errors = 0;

    int output_ints = csrs.readCSR(3) * 16;
    cout << "CSR4=" << csrs.readCSR(4) << endl;
    cout << "CSR3=" << csrs.readCSR(3) << endl;
    cout << "output_ints= " << output_ints << endl;

    for (int i = 0; i < output_ints; i++)
    {
        cout << *(output_buf + i*4);
        if (*(output_buf + i*4) != v++)
            n_errors++;
    }

    cout << "Number of memcpy errors: " << n_errors;


    // // Hash is stored in result_buf[1]
    // uint64_t r = result_buf[1];
    // cout << "Hash: 0x" << hex << r << dec << "  ["
    //      << ((0x5726aa1d == r) ? "Correct" : "ERROR")
    //      << "]" << endl << endl;

    // // Reads CSRs to get some statistics
    // cout << "# List length: " << csrs.readCSR(0) << endl
    //      << "# Linked list data entries read: " << csrs.readCSR(1) << endl;

    // cout << "#" << endl
    //      << "# AFU frequency: " << csrs.getAFUMHz() << " MHz"
    //      << (fpga.hwIsSimulated() ? " [simulated]" : "")
    //      << endl;

    // MPF VTP (virtual to physical) statistics
    mpf_handle::ptr_t mpf = fpga.mpf;
    if (mpfVtpIsAvailable(*mpf))
    {
        mpf_vtp_stats vtp_stats;
        mpfVtpGetStats(*mpf, &vtp_stats);

        cout << "#" << endl;
        if (vtp_stats.numFailedTranslations)
        {
            cout << "# VTP failed translating VA: 0x" << hex << uint64_t(vtp_stats.ptWalkLastVAddr) << dec << endl;
        }
        cout << "# VTP PT walk cycles: " << vtp_stats.numPTWalkBusyCycles << endl
             << "# VTP L2 4KB hit / miss: " << vtp_stats.numTLBHits4KB << " / "
             << vtp_stats.numTLBMisses4KB << endl
             << "# VTP L2 2MB hit / miss: " << vtp_stats.numTLBHits2MB << " / "
             << vtp_stats.numTLBMisses2MB << endl;
    }

    // All shared buffers are automatically released and the FPGA connection
    // is closed when their destructors are invoked here.
    return 0;
}



/*
# VTP PT walk cycles: 1122
# VTP L2 4KB hit / miss: 0 / 1
# VTP L2 2MB hit / miss: 0 / 8

#   Transaction count   |       VA      VL0      VH0      VH1 |    MCL-1    MCL-2    MCL-4              
#   ========================================================================================            
#   MMIOWrReq          25 |                                                                             
#   MMIORdReq          30 |                                                                             
#   MMIORdRsp          30 |                                                                             
#   IntrReq             0 |                                                                             
#   IntrResp            0 |                                                                             
#   RdReq             135 |       39        0        0        0 |        7        0       32            
#   RdResp            135 |        0       68       34       33 |                                       
#   WrReq               1 |        1        0        0        0 |        1        0        0            
#   WrResp              1 |        0        1        0        0 |        1        0        0            
#   WrFence             0 |        0        0        0        0 |                                       
#   WrFenRsp            0 |        0        0        0        0 |                                       

*/