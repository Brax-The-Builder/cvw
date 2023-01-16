///////////////////////////////////////////
// sd_clk_fsm.sv
//
// Written: Richard Davis
// Modified: Ross Thompson September 19, 2021
//
// Purpose: Controls clock dividers.
// Replaces s_disable_sd_clocks, s_select_hs_clk, s_enable_hs_clk
// in sd_cmd_fsm.vhd. Attempts to correct issues with oversampling and
// under-sampling of control signals (for counter_cmd), that were present in my
// previous design.
// This runs on 50 MHz.
// sd_cmd_fsm will run on SD_CLK_Gated (50 MHz or 400 KHz, selected by this)
// asynchronous reset is used for both sd_cmd_fsm and for this.
// It must be synchronized with 50 MHz and held for a minimum period of a full
// 400 KHz pulse width.
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

module sd_clk_fsm (
  input  logic 	CLK,
  input  logic 	i_RST,
  (* mark_debug = "true" *)output logic o_DONE,
  (* mark_debug = "true" *)input  logic i_START,
  (* mark_debug = "true" *)input  logic i_FATAL_ERROR,
  (* mark_debug = "true" *)output logic o_HS_TO_INIT_CLK_DIVIDER_RST, // resets clock divider that is going from 50 MHz to 400 KHz
  (* mark_debug = "true" *)output logic o_SD_CLK_SELECTED, // which clock is selected ('0'=HS or '1'=init)
  (* mark_debug = "true" *)output logic o_G_CLK_SD_EN // Turns gated clock (G_CLK_SD) off and on
);  


  logic [3:0] 	w_next_state;
  (* mark_debug = "true" *) logic [3:0] 	r_curr_state;
  

  // clock selection
  parameter c_sd_clk_init = 1'b1;
  parameter c_sd_clk_hs = 1'b0;

  // States
  localparam s_reset = 4'b0000;
  localparam s_enable_init_clk = 4'b0001;  // enable 400 KHz
  localparam s_disable_sd_clocks = 4'b0010;
  localparam s_select_hs_clk = 4'b0011;
  localparam s_enable_hs_clk = 4'b0100;
  localparam s_done = 4'b0101;
  localparam s_disable_sd_clocks_2 = 4'b0110;  // if error occurs
  localparam s_select_init_clk = 4'b0111;  // if error occurs
  localparam s_safe_state = 4'b1111;  //always provide a safe state return if all states are not used

  flopenr #(4) stateReg(.clk(CLK),
			.reset(i_RST),
			.en(1'b1),
			.d(w_next_state),
			.q(r_curr_state));

  assign w_next_state = i_RST ? s_reset :
			r_curr_state == s_reset | (r_curr_state == s_enable_init_clk & ~i_START) | (r_curr_state == s_select_init_clk) ? s_enable_init_clk :
			r_curr_state == s_enable_init_clk & i_START ? s_disable_sd_clocks :
			r_curr_state == s_disable_sd_clocks ? s_select_hs_clk :
			r_curr_state == s_select_hs_clk ? s_enable_hs_clk :
			r_curr_state == s_enable_hs_clk | (r_curr_state == s_done & ~i_FATAL_ERROR) ? s_done :
			r_curr_state == s_done & i_FATAL_ERROR ? s_disable_sd_clocks_2 :
			r_curr_state == s_disable_sd_clocks_2 ? s_select_init_clk :
			s_safe_state;


  assign o_HS_TO_INIT_CLK_DIVIDER_RST = r_curr_state == s_reset;

  assign o_SD_CLK_SELECTED = (r_curr_state == s_select_hs_clk) | (r_curr_state == s_enable_hs_clk) | (r_curr_state == s_done) ? c_sd_clk_hs : c_sd_clk_init;

  assign o_G_CLK_SD_EN = (r_curr_state == s_enable_init_clk) | (r_curr_state == s_enable_hs_clk) | (r_curr_state == s_done);
  
  assign o_DONE = r_curr_state == s_done;

endmodule  

