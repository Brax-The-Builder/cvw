///////////////////////////////////////////
// controller.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified: 
//
// Purpose: Top level controller module
// 
// Documentation: RISC-V System on Chip Design Chapter 4 (Section 4.1.4, Figure 4.8, Table 4.5)
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


module controller(
  input  logic		 clk, reset,
  // Decode stage control signals
  input  logic       StallD, FlushD,
  input  logic [31:0] InstrD,
  output logic [2:0] ImmSrcD,
  input  logic       IllegalIEUInstrFaultD, 
  output logic       IllegalBaseInstrFaultD,
  // Execute stage control signals
  input logic 	     StallE, FlushE,  
  input logic  [1:0] FlagsE, 
  input  logic       FWriteIntE,
  output logic       PCSrcE,        // for datapath and Hazard Unit
  output logic [2:0] ALUControlE, 
  output logic 	     ALUSrcAE, ALUSrcBE,
  output logic       ALUResultSrcE,
  output logic       MemReadE, CSRReadE, // for Hazard Unit
  output logic [2:0] Funct3E,
  output logic       IntDivE, MDUE, W64E,
  output logic       JumpE,	
  output logic       SCE,
  output logic       BranchSignedE,
  // Memory stage control signals
  input  logic       StallM, FlushM,
  output logic [1:0] MemRWM,
  output logic       CSRReadM, CSRWriteM, PrivilegedM,
  output logic [1:0] AtomicM,
  output logic [2:0] Funct3M,
  output logic       RegWriteM,     // for Hazard Unit
  output logic       InvalidateICacheM, FlushDCacheM,
  output logic       InstrValidM, 
  output logic       FWriteIntM,
  // Writeback stage control signals
  input  logic       StallW, FlushW,
  output logic 	     RegWriteW, IntDivW,    // for datapath and Hazard Unit
  output logic [2:0] ResultSrcW,
  // Stall during CSRs
  //output logic       CSRWriteFencePendingDEM,
  output logic       CSRWriteFenceM,
  output logic       StoreStallD
);

  logic [6:0] OpD;
  logic [2:0] Funct3D;
  logic [6:0] Funct7D;
  logic [4:0] Rs1D;

  `define CTRLW 23

  // pipelined control signals
  logic 	    RegWriteD, RegWriteE;
  logic [2:0] ResultSrcD, ResultSrcE, ResultSrcM;
  logic [1:0] MemRWD, MemRWE;
  logic		    JumpD;
  logic		    BranchD, BranchE;
  logic	      ALUOpD;
  logic [2:0] ALUControlD;
  logic 	    ALUSrcAD, ALUSrcBD;
  logic       ALUResultSrcD, W64D, MDUD;
  logic       CSRZeroSrcD;
  logic       CSRReadD;
  logic [1:0] AtomicD;
  logic       FenceXD;
  logic       InvalidateICacheD, FlushDCacheD;
  logic       CSRWriteD, CSRWriteE;
  logic       InstrValidD, InstrValidE;
  logic       PrivilegedD, PrivilegedE;
  logic       InvalidateICacheE, FlushDCacheE;
  logic [`CTRLW-1:0] ControlsD;
  logic        SubArithD;
  logic        subD, sraD, sltD, sltuD;
  logic        BranchTakenE;
  logic        eqE, ltE;
  logic        unused;
	logic        BranchFlagE;
  logic        IEURegWriteE;
  logic        IllegalERegAdrD;
  logic [1:0]  AtomicE;
   logic       FenceD, FenceE, FenceM;
  logic        SFenceVmaD;
   logic       IntDivM;
   

  // Extract fields
  assign OpD = InstrD[6:0];
  assign Funct3D = InstrD[14:12];
  assign Funct7D = InstrD[31:25];
  assign Rs1D = InstrD[19:15];

  // Main Instruction Decoder
  always_comb
    case(OpD)
    // RegWrite_ImmSrc_ALUSrc_MemRW_ResultSrc_Branch_ALUOp_Jump_ALUResultSrc_W64_CSRRead_Privileged_Fence_MDU_Atomic_Illegal
      7'b0000000:   ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // illegal instruction
      7'b0000011:   ControlsD = `CTRLW'b1_000_01_10_001_0_0_0_0_0_0_0_0_0_00_0; // lw
      7'b0000111:   ControlsD = `CTRLW'b0_000_01_10_001_0_0_0_0_0_0_0_0_0_00_0; // flw - only legal if FP supported
      7'b0001111: if(`ZIFENCEI_SUPPORTED)
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_1_0_00_0; // fence
              	  else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_0; // fence treated as nop
      7'b0010011:   ControlsD = `CTRLW'b1_000_01_00_000_0_1_0_0_0_0_0_0_0_00_0; // I-type ALU
      7'b0010111:   ControlsD = `CTRLW'b1_100_11_00_000_0_0_0_0_0_0_0_0_0_00_0; // auipc
      7'b0011011: if (`XLEN == 64)
                    ControlsD = `CTRLW'b1_000_01_00_000_0_1_0_0_1_0_0_0_0_00_0; // IW-type ALU for RV64i
                  else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
      7'b0100011:   ControlsD = `CTRLW'b0_001_01_01_000_0_0_0_0_0_0_0_0_0_00_0; // sw
      7'b0100111:   ControlsD = `CTRLW'b0_001_01_01_000_0_0_0_0_0_0_0_0_0_00_0; // fsw - only legal if FP supported
      7'b0101111: if (`A_SUPPORTED) begin
                    if (InstrD[31:27] == 5'b00010)
                      ControlsD = `CTRLW'b1_000_00_10_001_0_0_0_0_0_0_0_0_0_01_0; // lr
                    else if (InstrD[31:27] == 5'b00011)
                      ControlsD = `CTRLW'b1_101_01_01_100_0_0_0_0_0_0_0_0_0_01_0; // sc
                    else 
                      ControlsD = `CTRLW'b1_101_01_11_001_0_0_0_0_0_0_0_0_0_10_0;; // amo
                  end else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
      7'b0110011: if (Funct7D == 7'b0000000 | Funct7D == 7'b0100000)
                    ControlsD = `CTRLW'b1_000_00_00_000_0_1_0_0_0_0_0_0_0_00_0; // R-type 
                  else if (Funct7D == 7'b0000001 & `M_SUPPORTED)
                    ControlsD = `CTRLW'b1_000_00_00_011_0_0_0_0_0_0_0_0_1_00_0; // Multiply/Divide
                  else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
      7'b0110111:   ControlsD = `CTRLW'b1_100_01_00_000_0_0_0_1_0_0_0_0_0_00_0; // lui
      7'b0111011: if ((Funct7D == 7'b0000000 | Funct7D == 7'b0100000) & `XLEN == 64)
                    ControlsD = `CTRLW'b1_000_00_00_000_0_1_0_0_1_0_0_0_0_00_0; // R-type W instructions for RV64i
                  else if (Funct7D == 7'b0000001 & `M_SUPPORTED & `XLEN == 64)
                    ControlsD = `CTRLW'b1_000_00_00_011_0_0_0_0_1_0_0_0_1_00_0; // W-type Multiply/Divide
                  else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
      7'b1100011:   ControlsD = `CTRLW'b0_010_11_00_000_1_0_0_0_0_0_0_0_0_00_0; // branches
      7'b1100111:   ControlsD = `CTRLW'b1_000_01_00_000_0_0_1_1_0_0_0_0_0_00_0; // jalr
      7'b1101111:   ControlsD = `CTRLW'b1_011_11_00_000_0_0_1_1_0_0_0_0_0_00_0; // jal
      7'b1110011: if (`ZICSR_SUPPORTED) begin
                   if (Funct3D == 3'b000)
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_1_0_0_00_0; // privileged; decoded further in priveleged modules
                   else
                    ControlsD = `CTRLW'b1_000_00_00_010_0_0_0_0_0_1_0_0_0_00_0; // csrs
                  end else
                    ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
      default:      ControlsD = `CTRLW'b0_000_00_00_000_0_0_0_0_0_0_0_0_0_00_1; // non-implemented instruction
    endcase

  // unswizzle control bits
  // squash control signals if coming from an illegal compressed instruction
  // On RV32E, can't write to upper 16 registers.  Checking reads to upper 16 is more costly so disregard them.
  assign IllegalERegAdrD = `E_SUPPORTED & `ZICSR_SUPPORTED & ControlsD[`CTRLW-1] & InstrD[11]; 
  assign IllegalBaseInstrFaultD = ControlsD[0] | IllegalERegAdrD;
  assign {RegWriteD, ImmSrcD, ALUSrcAD, ALUSrcBD, MemRWD,
          ResultSrcD, BranchD, ALUOpD, JumpD, ALUResultSrcD, W64D, CSRReadD, 
          PrivilegedD, FenceXD, MDUD, AtomicD, unused} = IllegalIEUInstrFaultD ? `CTRLW'b0 : ControlsD;
  

  assign CSRZeroSrcD = InstrD[14] ? (InstrD[19:15] == 0) : (Rs1D == 0); // Is a CSR instruction using zero as the source?
  assign CSRWriteD = CSRReadD & !(CSRZeroSrcD & InstrD[13]); // Don't write if setting or clearing zeros
  assign SFenceVmaD = PrivilegedD & (InstrD[31:25] ==  7'b0001001);
  assign FenceD = SFenceVmaD | FenceXD; // possible sfence.vma or fence.i

  // ALU Decoding is lazy, only using func7[5] to distinguish add/sub and srl/sra
  assign sltD = (Funct3D == 3'b010);
  assign sltuD = (Funct3D == 3'b011);
  assign subD = (Funct3D == 3'b000 & Funct7D[5] & OpD[5]);  // OpD[5] needed to distinguish sub from addi
  assign sraD = (Funct3D == 3'b101 & Funct7D[5]);
  assign SubArithD = ALUOpD & (subD | sraD | sltD | sltuD); // TRUE for R-type subtracts and sra, slt, sltu
  assign ALUControlD = {W64D, SubArithD, ALUOpD};

  // Fences
  // Ordinary fence is presently a nop
  // FENCE.I flushes the D$ and invalidates the I$ if Zifencei is supported and I$ is implemented
  if (`ZIFENCEI_SUPPORTED & `ICACHE) begin:fencei
    logic FenceID;
    assign FenceID = FenceXD & (Funct3D == 3'b001); // is it a FENCE.I instruction?
    assign InvalidateICacheD = FenceID;
    assign FlushDCacheD = FenceID;
  end else begin:fencei
    assign InvalidateICacheD = 0;
    assign FlushDCacheD = 0;
  end
 
  // Decocde stage pipeline control register
  flopenrc #(1)  controlregD(clk, reset, FlushD, ~StallD, 1'b1, InstrValidD);

  // Execute stage pipeline control register and logic
  flopenrc #(28) controlregE(clk, reset, FlushE, ~StallE,
                           {RegWriteD, ResultSrcD, MemRWD, JumpD, BranchD, ALUControlD, ALUSrcAD, ALUSrcBD, ALUResultSrcD, CSRReadD, CSRWriteD, PrivilegedD, Funct3D, W64D, MDUD, AtomicD, InvalidateICacheD, FlushDCacheD, FenceD, InstrValidD},
                           {IEURegWriteE, ResultSrcE, MemRWE, JumpE, BranchE, ALUControlE, ALUSrcAE, ALUSrcBE, ALUResultSrcE, CSRReadE, CSRWriteE, PrivilegedE, Funct3E, W64E, MDUE, AtomicE, InvalidateICacheE, FlushDCacheE, FenceE, InstrValidE});

  // Branch Logic
  //  The comparator handles both signed and unsigned branches using BranchSignedE
  //  Hence, only eq and lt flags are needed
  assign BranchSignedE = ~(Funct3E[2:1] == 2'b11);
  assign {eqE, ltE} = FlagsE;
  mux2 #(1) branchflagmux(eqE, ltE, Funct3E[2], BranchFlagE);
  assign BranchTakenE = BranchFlagE ^ Funct3E[0];
  assign PCSrcE = JumpE | BranchE & BranchTakenE;

  // Other execute stage controller signals
  assign MemReadE = MemRWE[1];
  assign SCE = (ResultSrcE == 3'b100);
  assign RegWriteE = IEURegWriteE | FWriteIntE; // IRF register writes could come from IEU or FPU controllers
  assign IntDivE = MDUE & Funct3E[2]; // Integer division operation
  
  // Memory stage pipeline control register
  flopenrc #(20) controlregM(clk, reset, FlushM, ~StallM,
                         {RegWriteE, ResultSrcE, MemRWE, CSRReadE, CSRWriteE, PrivilegedE, Funct3E, FWriteIntE, AtomicE, InvalidateICacheE, FlushDCacheE, FenceE, InstrValidE, IntDivE},
                         {RegWriteM, ResultSrcM, MemRWM, CSRReadM, CSRWriteM, PrivilegedM, Funct3M, FWriteIntM, AtomicM, InvalidateICacheM, FlushDCacheM, FenceM, InstrValidM, IntDivM});
  
  // Writeback stage pipeline control register
  flopenrc #(5) controlregW(clk, reset, FlushW, ~StallW,
                         {RegWriteM, ResultSrcM, IntDivM},
                         {RegWriteW, ResultSrcW, IntDivW});  

  // Flush F, D, and E stages on a CSR write or Fence.I or SFence.VMA
  assign CSRWriteFenceM = CSRWriteM | FenceM;
//  assign CSRWriteFencePendingDEM = CSRWriteD | CSRWriteE | CSRWriteM | FenceD | FenceE | FenceM;

  // the synchronous DTIM cannot read immediately after write
  // a cache cannot read or write immediately after a write
  assign StoreStallD = MemRWE[0] & ((MemRWD[1] | (MemRWD[0] & `DCACHE)) | (|AtomicD));
endmodule
