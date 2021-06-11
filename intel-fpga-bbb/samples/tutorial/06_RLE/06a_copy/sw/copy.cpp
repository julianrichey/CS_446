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
    int v = 1; //different contents will compress differently, replace this with other data as needed

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
4: write to start afu, read whether the afu has finished
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
    csrs.writeCSR(0, intptr_t(input_buf)); //intptr_t -> uint64_t? assume this is fine
    cout << "input_lines= " << dec << INPUT_LINES << endl;
    csrs.writeCSR(1, INPUT_LINES);

    initMem(const_cast<t_line*>(input_buf));

    int output_bytes = input_bytes * 2; //once compressing, adjust based on worst case compression ratio
    auto output_buf_handle = fpga.allocBuffer(output_bytes);
    auto output_buf = reinterpret_cast<volatile int*>(output_buf_handle->c_type());
    assert(NULL != output_buf);
    output_buf[0] = 0; //not needed, only useful if checking for output_buf being filled. CSR4 'done' accomplishes this indirectly
    cout << "output_buf= 0x" << hex << intptr_t(output_buf) << endl;
    csrs.writeCSR(2, intptr_t(output_buf));

    csrs.writeCSR(3, 0);
    csrs.writeCSR(4, 0); //fpga waiting for this to start. writing 0 is fine because the enable bit is also set

    struct timespec pause;
    pause.tv_sec = (fpga.hwIsSimulated() ? 1 : 0);
    pause.tv_nsec = 2500000;

    //control signal indicating done
    //cant use normal output, as last written index not known ahead of time
    while (0 == csrs.readCSR(4))
    {
        cout << "CSR4=0 ";
        nanosleep(&pause, NULL);
    };

    nanosleep(&pause, NULL); // !!! some amount of time here is necessary to give time to receive the last cache line !!!
    nanosleep(&pause, NULL); //more just in case

    //confirm output
    int v = 1;
    int n_errors = 0;

    int output_bytes_real = csrs.readCSR(3) * 64;
    cout << "CSR4=" << csrs.readCSR(4) << endl;
    cout << "CSR3=" << csrs.readCSR(3) << endl;
    cout << "output_bytes_real= " << dec << output_bytes_real << endl;

    for (int i = 0; i < output_bytes_real / 4; i++)
    {
        cout << hex << output_buf[i] << " ";
        
        if (output_buf[i] != v++)
            n_errors++;
    }

    cout << "Number of copy errors: " << dec << n_errors << endl;


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



// For INPUT_LINES = 5
// #   Transaction count   |       VA      VL0      VH0      VH1 |    MCL-1    MCL-2    MCL-4
// #   ========================================================================================
// #   MMIOWrReq          14 |
// #   MMIORdReq          56 |
// #   MMIORdRsp          56 |
// #   IntrReq             0 |
// #   IntrResp            0 |
// #   RdReq              10 |       10        0        0        0 |       10        0        0
// #   RdResp             10 |        0        5        3        2 |
// #   WrReq               5 |        5        0        0        0 |        5        0        0
// #   WrResp              5 |        0        3        1        1 |        5        0        0
// #   WrFence             0 |        0        0        0        0 |
// #   WrFenRsp            0 |        0        0        0        0 |
