///////////////////////////////////////////
// csr.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified: 
//          dottolia@hmc.edu 7 April 2021
//
// Purpose: Counter Control and Status Registers
//          See RISC-V Privileged Mode Specification 20190608 
// 
// A component of the CORE-V-WALLY configurable RISC-V project.
// 
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
// except in compliance with the License, or, at your option, the Apache License version 2.0. You 
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the 
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module csr #(parameter
    MIP = 12'h344,
    SIP = 12'h144
  ) (
  input  logic             clk, reset,
  input  logic             FlushM, FlushW,
  input  logic             StallE, StallM, StallW,
  input  logic [31:0]      InstrM, 
  input  logic [`XLEN-1:0] PCM, SrcAM, IEUAdrM, PCNext2F,
  input  logic             CSRReadM, CSRWriteM, TrapM, mretM, sretM, wfiM, IntPendingM, InterruptM,
  input  logic             MTimerInt, MExtInt, SExtInt, MSwInt,
  input  logic [63:0]      MTIME_CLINT, 
  input  logic             InstrValidM, FRegWriteM, LoadStallD,
  input  logic             DirPredictionWrongM,
  input  logic             BTBPredPCWrongM,
  input  logic             RASPredPCWrongM,
  input  logic             PredictionInstrClassWrongM,
  input  logic [4:0]       InstrClassM,
  input  logic             DCacheMiss,
  input  logic             DCacheAccess,
  input  logic             ICacheMiss,
  input  logic             ICacheAccess,
  input  logic [1:0]       NextPrivilegeModeM, PrivilegeModeW,
  input  logic [`LOG_XLEN-1:0] CauseM, 
  input  logic             SelHPTW,
  output logic [1:0]       STATUS_MPP,
  output logic             STATUS_SPP, STATUS_TSR, STATUS_TVM,
  output logic [`XLEN-1:0]      MEDELEG_REGW, 
  output logic [`XLEN-1:0] SATP_REGW,
  output logic [11:0]      MIP_REGW, MIE_REGW, MIDELEG_REGW,
  output logic             STATUS_MIE, STATUS_SIE,
  output logic             STATUS_MXR, STATUS_SUM, STATUS_MPRV, STATUS_TW,
  output logic [1:0]       STATUS_FS,
  output var logic [7:0]      PMPCFG_ARRAY_REGW[`PMP_ENTRIES-1:0],
  output var logic [`XLEN-1:0] PMPADDR_ARRAY_REGW[`PMP_ENTRIES-1:0],
  
  input  logic [4:0]       SetFflagsM,
  output logic [2:0]       FRM_REGW, 
  output logic [`XLEN-1:0] CSRReadValW, UnalignedPCNextF,
  output logic             IllegalCSRAccessM, BigEndianM
);

  localparam NOP = 32'h13;
  logic [`XLEN-1:0] CSRMReadValM, CSRSReadValM, CSRUReadValM, CSRCReadValM;
(* mark_debug = "true" *)  logic [`XLEN-1:0] CSRReadValM;  
(* mark_debug = "true" *)  logic [`XLEN-1:0] CSRSrcM;
  logic [`XLEN-1:0] CSRRWM, CSRRSM, CSRRCM;  
(* mark_debug = "true" *)  logic [`XLEN-1:0] CSRWriteValM;
 
(* mark_debug = "true" *)  logic [`XLEN-1:0] MSTATUS_REGW, SSTATUS_REGW, MSTATUSH_REGW;
  logic [`XLEN-1:0] STVEC_REGW, MTVEC_REGW;
  logic [`XLEN-1:0] MEPC_REGW, SEPC_REGW;

  logic [31:0]     MCOUNTINHIBIT_REGW, MCOUNTEREN_REGW, SCOUNTEREN_REGW;
  logic            WriteMSTATUSM, WriteMSTATUSHM, WriteSSTATUSM;
  logic            CSRMWriteM, CSRSWriteM, CSRUWriteM;
  logic            WriteFRMM, WriteFFLAGSM;

  logic [`XLEN-1:0] UnalignedNextEPCM, NextEPCM, NextCauseM, NextMtvalM;

  logic [11:0] CSRAdrM;
  logic        IllegalCSRCAccessM, IllegalCSRMAccessM, IllegalCSRSAccessM, IllegalCSRUAccessM, InsufficientCSRPrivilegeM;
  logic IllegalCSRMWriteReadonlyM;
  logic [`XLEN-1:0] CSRReadVal2M;
  logic [11:0] MIP_REGW_writeable;
  logic [`XLEN-1:0] TVecM, TrapVectorM, NextFaultMtvalM;
  logic MTrapM, STrapM;

  logic [`XLEN-1:0] EPC;
  logic 			RetM;
  logic       SelMtvecM;
  logic [`XLEN-1:0] TVecAlignedM;
  
  logic InstrValidNotFlushedM;
  assign InstrValidNotFlushedM = InstrValidM & ~StallW & ~FlushW;

  ///////////////////////////////////////////
  // MTVAL
  ///////////////////////////////////////////

  always_comb
    if (InterruptM) NextFaultMtvalM = 0;
    else case (CauseM)
      12, 1, 3:               NextFaultMtvalM = PCM;  // Instruction page/access faults, breakpoint
      2:                      NextFaultMtvalM = {{(`XLEN-32){1'b0}}, InstrM}; // Illegal instruction fault
      0, 4, 6, 13, 15, 5, 7:  NextFaultMtvalM = IEUAdrM; // Instruction misaligned, Load/Store Misaligned/page/access faults
      default:                NextFaultMtvalM = 0; // Ecall, interrupts
    endcase

  ///////////////////////////////////////////
  // Trap Vectoring & Returns
  ///////////////////////////////////////////
  //
  // POSSIBLE OPTIMIZATION: 
  // From 20190608 privielegd spec page 27 (3.1.7)
  // > Allowing coarser alignments in Vectored mode enables vectoring to be
  // > implemented without a hardware adder circuit.
  // For example, we could require m/stvec be aligned on 7 bits to let us replace the adder directly below with
  // [untested] TrapVectorM = {TVec[`XLEN-1:7], CauseM[3:0], 4'b0000}
  // However, this is program dependent, so not implemented at this time.

  // Select trap vector from STVEC or MTVEC and word-align
  assign SelMtvecM = (NextPrivilegeModeM == `M_MODE);
  mux2 #(`XLEN) tvecmux(STVEC_REGW, MTVEC_REGW, SelMtvecM, TVecM);
  assign TVecAlignedM = {TVecM[`XLEN-1:2], 2'b00};

  // Support vectored interrupts
  if(`VECTORED_INTERRUPTS_SUPPORTED) begin:vec
    logic VectoredM;
    logic [`XLEN-1:0] TVecPlusCauseM;
    assign VectoredM = InterruptM & (TVecM[1:0] == 2'b01);
	// *** Would like you use concat version, but breaks uart test wally64priv when
	// mtvec is aligned to 64 bytes.
    assign TVecPlusCauseM = TVecAlignedM + {{(`XLEN-2-`LOG_XLEN){1'b0}}, CauseM, 2'b00};
	//assign TVecPlusCauseM = {TVecAlignedM[`XLEN-1:6], CauseM[3:0], 2'b00};
    mux2 #(`XLEN) trapvecmux(TVecAlignedM, TVecPlusCauseM, VectoredM, TrapVectorM);
  end else 
    assign TrapVectorM = TVecAlignedM;

  // Trap Returns
  // A trap sets the PC to TrapVector
  // A return sets the PC to MEPC or SEPC
  assign RetM = mretM | sretM;
  mux2 #(`XLEN) epcmux(SEPC_REGW, MEPC_REGW, mretM, EPC);
  mux3 #(`XLEN) pcmux3(PCNext2F, EPC, TrapVectorM, {TrapM, RetM}, UnalignedPCNextF);

  ///////////////////////////////////////////
  // CSRWriteValM
  ///////////////////////////////////////////
  always_comb begin
    // Choose either rs1 or uimm[4:0] as source
    CSRSrcM = InstrM[14] ? {{(`XLEN-5){1'b0}}, InstrM[19:15]} : SrcAM;

    // CSR set and clear for MIP/SIP should only touch internal state, not interrupt inputs
    if (CSRAdrM == MIP | CSRAdrM == SIP) CSRReadVal2M = {{(`XLEN-12){1'b0}}, MIP_REGW_writeable};
    else                                 CSRReadVal2M = CSRReadValM;

    // Compute AND/OR modification
    CSRRWM = CSRSrcM;
    CSRRSM = CSRReadVal2M | CSRSrcM;
    CSRRCM = CSRReadVal2M & ~CSRSrcM;
    case (InstrM[13:12])
      2'b01:  CSRWriteValM = CSRRWM;
      2'b10:  CSRWriteValM = CSRRSM;
      2'b11:  CSRWriteValM = CSRRCM;
      default: CSRWriteValM = CSRReadValM;
    endcase
  end

  ///////////////////////////////////////////
  // CSR Write values
  ///////////////////////////////////////////
  assign CSRAdrM = InstrM[31:20];
  assign UnalignedNextEPCM = TrapM ? ((wfiM & IntPendingM) ? PCM+4 : PCM) : CSRWriteValM;
  assign NextEPCM = `C_SUPPORTED ? {UnalignedNextEPCM[`XLEN-1:1], 1'b0} : {UnalignedNextEPCM[`XLEN-1:2], 2'b00}; // 3.1.15 alignment
  assign NextCauseM = TrapM ? {InterruptM, {(`XLEN-`LOG_XLEN-1){1'b0}}, CauseM}: CSRWriteValM;
  assign NextMtvalM = TrapM ? NextFaultMtvalM : CSRWriteValM;
  assign CSRMWriteM = CSRWriteM & (PrivilegeModeW == `M_MODE);
  assign CSRSWriteM = CSRWriteM & (|PrivilegeModeW);
  assign CSRUWriteM = CSRWriteM;  
  assign MTrapM = TrapM & (NextPrivilegeModeM == `M_MODE);
  assign STrapM = TrapM & (NextPrivilegeModeM == `S_MODE) & `S_SUPPORTED;

  ///////////////////////////////////////////
  // CSRs
  ///////////////////////////////////////////

  csri   csri(.clk, .reset, .InstrValidNotFlushedM,  
              .CSRMWriteM, .CSRSWriteM, .CSRWriteValM, .CSRAdrM, 
              .MExtInt, .SExtInt, .MTimerInt, .MSwInt,
              .MIP_REGW, .MIE_REGW, .MIP_REGW_writeable);
  csrsr csrsr(.clk, .reset, .StallW, 
              .WriteMSTATUSM, .WriteMSTATUSHM, .WriteSSTATUSM, 
              .TrapM, .FRegWriteM, .NextPrivilegeModeM, .PrivilegeModeW,
              .mretM, .sretM, .WriteFRMM, .WriteFFLAGSM, .CSRWriteValM, .SelHPTW,
              .MSTATUS_REGW, .SSTATUS_REGW, .MSTATUSH_REGW,
              .STATUS_MPP, .STATUS_SPP, .STATUS_TSR, .STATUS_TW,
              .STATUS_MIE, .STATUS_SIE, .STATUS_MXR, .STATUS_SUM, .STATUS_MPRV, .STATUS_TVM,
              .STATUS_FS, .BigEndianM);
  csrc  counters(.clk, .reset,
              .StallE, .StallM, .FlushM,
              .InstrValidNotFlushedM, .LoadStallD, .CSRMWriteM,
              .DirPredictionWrongM, .BTBPredPCWrongM, .RASPredPCWrongM, .PredictionInstrClassWrongM,
              .InstrClassM, .DCacheMiss, .DCacheAccess, .ICacheMiss, .ICacheAccess,
              .CSRAdrM, .PrivilegeModeW, .CSRWriteValM,
              .MCOUNTINHIBIT_REGW, .MCOUNTEREN_REGW, .SCOUNTEREN_REGW,
              .MTIME_CLINT,  .CSRCReadValM, .IllegalCSRCAccessM);
  csrm  csrm(.clk, .reset, .InstrValidNotFlushedM, 
              .CSRMWriteM, .MTrapM, .CSRAdrM,
              .NextEPCM, .NextCauseM, .NextMtvalM, .MSTATUS_REGW, .MSTATUSH_REGW,
              .CSRWriteValM, .CSRMReadValM, .MTVEC_REGW,
              .MEPC_REGW, .MCOUNTEREN_REGW, .MCOUNTINHIBIT_REGW, 
              .MEDELEG_REGW, .MIDELEG_REGW,.PMPCFG_ARRAY_REGW, .PMPADDR_ARRAY_REGW,
              .MIP_REGW, .MIE_REGW, .WriteMSTATUSM, .WriteMSTATUSHM,
              .IllegalCSRMAccessM, .IllegalCSRMWriteReadonlyM);
  csrs  csrs(.clk, .reset,  .InstrValidNotFlushedM,
              .CSRSWriteM, .STrapM, .CSRAdrM,
              .NextEPCM, .NextCauseM, .NextMtvalM, .SSTATUS_REGW, 
              .STATUS_TVM, .CSRWriteValM, .PrivilegeModeW,
              .CSRSReadValM, .STVEC_REGW, .SEPC_REGW,      
              .SCOUNTEREN_REGW,
              .SATP_REGW, .MIP_REGW, .MIE_REGW, .MIDELEG_REGW,
              .WriteSSTATUSM, .IllegalCSRSAccessM);
  csru  csru(.clk, .reset, .InstrValidNotFlushedM, 
              .CSRUWriteM, .CSRAdrM, .CSRWriteValM, .STATUS_FS, .CSRUReadValM,  
              .SetFflagsM, .FRM_REGW, .WriteFRMM, .WriteFFLAGSM,
              .IllegalCSRUAccessM);

  // merge CSR Reads
  assign CSRReadValM = CSRUReadValM | CSRSReadValM | CSRMReadValM | CSRCReadValM; 
  flopenrc #(`XLEN) CSRValWReg(clk, reset, FlushW, ~StallW, CSRReadValM, CSRReadValW);

  // merge illegal accesses: illegal if none of the CSR addresses is legal or privilege is insufficient
  assign InsufficientCSRPrivilegeM = (CSRAdrM[9:8] == 2'b11 & PrivilegeModeW != `M_MODE) |
                                     (CSRAdrM[9:8] == 2'b01 & PrivilegeModeW == `U_MODE);
  assign IllegalCSRAccessM = ((IllegalCSRCAccessM & IllegalCSRMAccessM & 
    IllegalCSRSAccessM & IllegalCSRUAccessM |
    InsufficientCSRPrivilegeM) & CSRReadM) | IllegalCSRMWriteReadonlyM;
endmodule
