///////////////////////////////////////////
// SDC.sv
//
// Written: Ross Thompson September 22, 2021
// Modified: 
//
// Purpose: SDC interface to AHBLite BUS.
// 
// A component of the CORE-V-WALLY configurable RISC-V project.
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

`define SDCCLKDIV -8'd3

module SDC (
  input  logic             HCLK, 
  input  logic 		         HRESETn,
  input  logic 		         HSELSDC,
  input  logic [4:0] 	     HADDR,
  input  logic 		         HWRITE,
  input  logic 		         HREADY,
  input  logic [1:0] 	     HTRANS,
  input  logic [`XLEN-1:0] HWDATA,
  output logic [`XLEN-1:0] HREADSDC,
  output logic 	           HRESPSDC, 
  output logic 	           HREADYSDC,

  //sd card interface
  // place the tristate drivers at the top.  this level
  // will use dedicated 1 direction ports.
  output logic 	           SDCCmdOut,
  input  logic 		         SDCCmdIn,
  output logic 	           SDCCmdOE,
  input  logic [3:0] 	     SDCDatIn,
  output logic 	           SDCCLK,
  // interrupt to PLIC
  output logic 	           SDCIntM
);

  logic 		               InitTrans;
  logic 		               RegRead;
  logic 		               RegWrite;
  logic [4:0] 		         HADDRDelay;


  // Register outputs
  logic signed [7:0] 		   CLKDiv;
  logic [2:0] 		         Command;
  logic [63:9] 		         Address;
  

  logic 		               SDCDone;
  
  logic [2:0] 		    ErrorCode;
  logic 		    InvalidCommand;
  logic 		    SDCBusy;

  logic 		    StartCLKDivUpdate;
  logic 		    CLKDivUpdateEn;
  logic 		    SDCCLKEN;
  logic 		    CLKGate;
  logic 		    SDCCLKIn;
  
  
  logic 		    SDCDataValid;
  logic [`XLEN-1:0] 	    SDCReadData;
  logic [`XLEN-1:0] 	    SDCReadDataPreNibbleSwap;
  logic [`XLEN-1:0] 	    SDCWriteData;
  logic 		    FatalError;
  
  logic [4095:0] 	    ReadData512Byte;
  logic [`XLEN-1:0] 	    ReadData512ByteWords [4096/`XLEN-1:0] ;
  logic 		    SDCInitialized;
  logic 		    SDCRestarting;
  logic 		    SDCLast;

  logic [$clog2(4096/`XLEN)-1:0] WordCount;
  logic WordCountRst;
  logic [5:0] Status;
  logic       CommandCompleted;
  logic       ReadDone;
  
  

  genvar 			 index;
  
  assign HRESPSDC = 1'b0;

  // registers
  //| Offset | Name    | Size   | Purpose                                        |
  //|--------+---------+--------+------------------------------------------------|
  //|    0x0 | CLKDiv  |    4   | Divide HCLK to produce SDCLK                   |
  //|    0x4 | Status  |    4   | Provide status to software                     |
  //|    0x8 | Control |    4   | Send commands to SDC                           |
  //|    0xC | Size    |    4   | Size of data command (only 512 byte supported) |
  //|   0x10 | address |    8   | address of operation                           |
  //|   0x18 | data    | XLEN/8 | Data Bus interface                             |

  // Status contains
  // Status[0] initialized
  // Status[1] Busy on read
  // Status[2] invalid command
  // Status[5:3] error code
  
  // control contains 3 bit command
  // control[2:0]
  // 000 nop op
  // xx1 initialize
  // 010 Write  no implemented
  // 100 Read
  // 110 Atomic read/write not implemented

  // size is fixed to 512. Read only
  
  
  // Currently using a mailbox style interface.   Data is passed through the Data register (0x10)
  // The card will support 3 operations
  // 1. initialize
  // 2. read
  // 3. write
  // all read and write operations will occur on 512 bytes (4096 bits) of data
  // starting at the 512 byte aligned address in the address register  This register
  // is the byte address.

  // currently does not support writes

  assign InitTrans = HREADY & HSELSDC & HTRANS[1];
  //assign RegRead = InitTrans & ~HWRITE;
  // register resolve combo loop
  flopr #(1) RegReadReg(HCLK, ~HRESETn, InitTrans & ~HWRITE, RegRead);
  // AHBLite Spec has write data 1 cycle after write command
  flopr #(1) RegWriteReg(HCLK, ~HRESETn, InitTrans & HWRITE, RegWrite);
  
  flopenr #(5) HADDRReg(HCLK, ~HRESETn, InitTrans, HADDR, HADDRDelay);
  
  assign StartCLKDivUpdate = HADDRDelay == '0 & RegWrite;
  
  flopenl #(8) CLKDivReg(HCLK, ~HRESETn, CLKDivUpdateEn, HWDATA[7:0], `SDCCLKDIV, CLKDiv);

  // Control reg
  flopenl #(3) CommandReg(HCLK, ~HRESETn, (HADDRDelay == 'h8 & RegWrite) | (CommandCompleted), 
			   CommandCompleted ? '0 : HWDATA[2:0], '0, Command);

  if (`XLEN == 64) begin  
    flopenr #(64-9) AddressReg(HCLK, ~HRESETn, (HADDRDelay == 'h10 & RegWrite),
        HWDATA[`XLEN-1:9], Address);
  end else begin
    flopenr #(32-9) AddressLowReg(HCLK, ~HRESETn, (HADDRDelay == 'h10 & RegWrite),
          HWDATA[`XLEN-1:9], Address[31:9]);
    flopenr #(32) AddressHighReg(HCLK, ~HRESETn, (HADDRDelay == 'h14 & RegWrite),
          HWDATA, Address[63:32]);
  end
  
  flopen #(`XLEN) DataReg(HCLK, (HADDRDelay == 'h18 & RegWrite),
			  HWDATA, SDCWriteData);

  assign InvalidCommand = (Command[2] | Command[1]) & Command[0];
  
  assign Status = {ErrorCode, InvalidCommand, SDCBusy, SDCInitialized};
  
    if(`XLEN == 64) begin
      always_comb
	case(HADDRDelay[4:0]) 
	  'h0: HREADSDC = {24'b0, CLKDiv, 26'b0, Status};
	  'h4: HREADSDC = {26'b0, Status, 29'b0, Command};
	  'h8: HREADSDC = {29'b0, Command, 32'h200};
	  'hC: HREADSDC = {32'h200, Address[31:9], 9'b0};
	  'h10: HREADSDC = {Address, 9'b0};
	  'h18: HREADSDC = SDCReadData;
	  default: HREADSDC = {24'b0, CLKDiv, 26'b0, Status};
	endcase // case (HADDRDelay[4:0])
    end  else begin
      always_comb
	case(HADDRDelay[4:0]) 
	  'h0: HREADSDC = {24'b0, CLKDiv};
	  'h4: HREADSDC = {26'b0, Status};
	  'h8: HREADSDC = {29'b0, Command};
	  'hC: HREADSDC = 'h200;
	  'h10: HREADSDC = {Address[31:9], 9'b0};
	  'h14: HREADSDC = Address[63:32];	  
	  'h18: HREADSDC = SDCReadData[31:0];
	  default: HREADSDC = {24'b0, CLKDiv};
	endcase
    end
 
  
  for(index = 0; index < 4096/`XLEN; index++) begin
    assign ReadData512ByteWords[index] = ReadData512Byte[(index+1)*`XLEN-1:index*`XLEN];
  end

  assign SDCReadDataPreNibbleSwap = ReadData512ByteWords[WordCount];
 	if(`XLEN == 64) begin
	  assign SDCReadData = {SDCReadDataPreNibbleSwap[59:56], SDCReadDataPreNibbleSwap[63:60],
							SDCReadDataPreNibbleSwap[51:48], SDCReadDataPreNibbleSwap[55:52],
							SDCReadDataPreNibbleSwap[43:40], SDCReadDataPreNibbleSwap[47:44],
							SDCReadDataPreNibbleSwap[35:32], SDCReadDataPreNibbleSwap[39:36],
							SDCReadDataPreNibbleSwap[27:24], SDCReadDataPreNibbleSwap[31:28],
							SDCReadDataPreNibbleSwap[19:16], SDCReadDataPreNibbleSwap[23:20],
							SDCReadDataPreNibbleSwap[11:8], SDCReadDataPreNibbleSwap[15:12],
							SDCReadDataPreNibbleSwap[3:0], SDCReadDataPreNibbleSwap[7:4]};
	end else begin
	  assign SDCReadData = {SDCReadDataPreNibbleSwap[27:24], SDCReadDataPreNibbleSwap[31:28],
							SDCReadDataPreNibbleSwap[19:16], SDCReadDataPreNibbleSwap[23:20],
							SDCReadDataPreNibbleSwap[11:8], SDCReadDataPreNibbleSwap[15:12],
							SDCReadDataPreNibbleSwap[3:0], SDCReadDataPreNibbleSwap[7:4]};
	end

  flopenr #($clog2(4096/`XLEN)) WordCountReg
    (.clk(HCLK),
     .reset(~HRESETn | WordCountRst),
     .en(HADDRDelay[4:0] == 'h18 & ReadDone),
     .d(WordCount + 1'b1),
     .q(WordCount));
  
  

  typedef enum {STATE_READY,

		// clock update states
		STATE_CLK_DIV1,
		STATE_CLK_DIV2,
		STATE_CLK_DIV3,
		STATE_CLK_DIV4,

		// restart SDC
		STATE_RESTART,

		// SDC operation
		STATE_PROCESS_CMD,

		STATE_READ
		} statetype;


  statetype CurrState, NextState;
  
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn)    CurrState <=  STATE_READY;
    else CurrState <= NextState;

  always_comb begin
    CLKDivUpdateEn = 1'b0;
    HREADYSDC = 1'b0;
    SDCCLKEN = 1'b1;
    WordCountRst = 1'b0;
    SDCBusy = 1'b0;
    CommandCompleted = 1'b0;
    ReadDone = 1'b0;

    case (CurrState)
      STATE_READY : begin
	if (StartCLKDivUpdate)begin
	  NextState = STATE_CLK_DIV1;
	  HREADYSDC = 1'b0;
	end else if (Command[2] | Command[1]) begin
	  NextState = STATE_PROCESS_CMD;
	  HREADYSDC = 1'b0;
	end else if(HADDRDelay[4:0] == 'h18 & RegRead) begin
	  NextState = STATE_READ;
	  HREADYSDC = 1'b0;
	end else begin
	  NextState = STATE_READY;
	  HREADYSDC = 1'b1;
	end
      end
      STATE_CLK_DIV1: begin
	NextState = STATE_CLK_DIV2;
	SDCCLKEN = 1'b0;
      end
      STATE_CLK_DIV2: begin
	NextState = STATE_CLK_DIV3;
	CLKDivUpdateEn = 1'b1;
	SDCCLKEN = 1'b0;
      end
      STATE_CLK_DIV3: begin
	NextState = STATE_CLK_DIV4;
	SDCCLKEN = 1'b0;
      end
      STATE_CLK_DIV4: begin
	NextState = STATE_READY;
      end
      STATE_PROCESS_CMD: begin
	HREADYSDC = 1'b1;
	WordCountRst = 1'b1;
	SDCBusy = 1'b1;
	if(SDCDataValid) begin
	  NextState = STATE_READY;
	  CommandCompleted = 1'b1;
	end else begin
	  NextState = STATE_PROCESS_CMD;
	  CommandCompleted = 1'b0;
	end
      end
      STATE_READ: begin
	NextState = STATE_READY;
	HREADYSDC = 1'b1;
	ReadDone = 1'b1;
      end
      default: begin
	NextState = STATE_READY;
      end
    endcase
  end

  // clock generation divider

  clockgater clockgater(.E(SDCCLKEN),
			.SE(1'b0),
			.CLK(HCLK),
			.ECLK(CLKGate));


  clkdivider #(8) clkdivider(.i_COUNT_IN_MAX(CLKDiv),
			     .i_EN(CLKDiv <= 0), // enable if < 0 (msb is 1)
			     .i_CLK(CLKGate),
			     .i_RST(~HRESETn | CLKDivUpdateEn),
			     .o_CLK(SDCCLKIn));

//  assign SDCCLKIn = CLKGate;
  

  // should always be 0 for real implementation, but for simulation set to 1.
  logic LimitTimers;
  assign LimitTimers = '0;
  
  sd_top sd_top(.CLK(SDCCLKIn),
		.a_RST(~HRESETn),
		.i_SD_CMD(SDCCmdIn),
		.o_SD_CMD(SDCCmdOut),
		.o_SD_CMD_OE(SDCCmdOE),
		.i_SD_DAT(SDCDatIn),
		.o_SD_CLK(SDCCLK),
		.i_BLOCK_ADDR(Address[32:9]),
		.o_READY_FOR_READ(SDCInitialized),
		.o_SD_RESTARTING(SDCRestarting),
		.i_READ_REQUEST(Command[2]),
		.o_DATA_TO_CORE(),
		.ReadData(ReadData512Byte),
		.o_DATA_VALID(SDCDataValid),
		.o_LAST_NIBBLE(SDCLast),
		.o_ERROR_CODE_Q(ErrorCode),
		.o_FATAL_ERROR(FatalError),
		.i_COUNT_IN_MAX(-8'd62),
		.LIMIT_SD_TIMERS(LimitTimers)); // *** must change this to 0 for real hardware.

  
endmodule
	    
