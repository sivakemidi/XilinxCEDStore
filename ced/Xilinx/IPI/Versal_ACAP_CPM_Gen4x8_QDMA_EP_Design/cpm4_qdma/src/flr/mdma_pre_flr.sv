`ifndef MDMA_PRE_FLR_SV
`define MDMA_PRE_FLR_SV

`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// $Id: 
//-----------------------------------------------------------------------------
// mdma_flr.sv 
//-----------------------------------------------------------------------------
// (c) Copyright 2010 - 2016 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and 
// international copyright and other intellectual property
// laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//-----------------------------------------------------------------------------
// Filename:        mdma_pre_flr.sv 
//
// Description:     Pre-FLR clean up
//                   
// Verilog-Standard:  Verilog 2001
//-----------------------------------------------------------------------------
// Structure:   
//              mdma_pre_flr.sv 
//
//-----------------------------------------------------------------------------
// Revision:        v1.0
// Date:            2018/02/16
// Author:          Xiyue Xiang
//-----------------------------------------------------------------------------

`include "qdma_defines.vh"
`include "qdma_defines.svh"
`include "mdma_defines.svh"
`include "mdma_reg.svh"
// Chris remove temp `include "qdma_axidma_fifo.vh"
`include "qdma_pcie_dma_attr_defines.vh"
`include "mailbox_defines.svh"
`include "cpm_axi4mm_axi_bridge.vh"

module mdma_pre_flr #( 
    ) (
    input                                   user_clk,
    input                                   reset,
   
    input    attr_dma_pf_t    [3:0]         attr_dma_pf,

    // User FLR request 
    output    usr_flr_if_in_t               usr_flr_in,  // Output to dma5_flr_cntl.sv  (Used by Everest)
    input     usr_flr_if_out_t              usr_flr_out, // Input from dma5_flr_cntl.sv 
                                                         // signal done bit until both user and mgmt FLR complete

    // FLR request from AXIL (forwarded by mailbox)
    input   mailbox_mb2flr_data_t           mb2flr_data,
    input                                   mb2flr_push,

    // Struct holding the flr request
    output  logic  [255:0]                  flr_state_reg,
    
    // Status of MDMA FLR
    output  logic  [255:0]                  pre_flr_done, // A per function one-cycle pulse for debugging 

    // Management Interface to perform FLR on register space         
    output  dma_mgmt_req_t                  mgmt_req,
    output  logic                           mgmt_req_vld,
    input                                   mgmt_req_rdy,

    input   dma_mgmt_cpl_t                  mgmt_cpl, 
    input                                   mgmt_cpl_vld,
    output  logic                           mgmt_cpl_rdy, //  set to 1 to always ready to accept completion packet

    // FLR to mailbox
    output logic                            mb_flr_set,
    output logic [7:0]                      mb_flr_fnc,
    input                                   mb_flr_done_vld,
 
    // FLR to user logic
    output logic [7:0]                      usr_flr_fnc, // user function to do FLR
    output logic                            usr_flr_set, // one-cycle pulse to start the user FLR
    output                                  usr_flr_clr,
    input  [7:0]                            usr_flr_done_fnc, 
    input                                   usr_flr_done_vld // end-triggered. expect a one cycle pulse indicating user FLR completion 
    );

// MDMA_MGMT_PRE_FLR:
//   [0]:   RW  Start
//              SW set this bit to kicl off the FLR
//              SW must poll this bit to check the status of FLR; 
//              It is cleared when both user FLR and MDMA FLR complete
//   [31:1]     Reserved
localparam MDMA_IND_CTXT_CMD_A = MDMA_CMN_IND_START_A + 'h24;
`ifdef FLR_USE_CLR
  localparam FLR_CTXT_IND_CMD = MDMA_CTXT_CMD_CLR;
`else
  localparam FLR_CTXT_IND_CMD = MDMA_CTXT_CMD_INV;
`endif
localparam USR_FLR_TIMEOUT_LIMIT = 25'd25000000; // 100 ms / 25M cycle

/************************************************
* Gather FLR events
*************************************************/
// For Diablo, FLR comes from AXIL Master I/F. 
// For Everest, FLR comes from usr_flr_out fom flr controller

logic [7:0] flr_fn_in_captured;
logic [1:0] flr_pfn_in_captured;
logic       flr_from_pcie;
logic       flr_from_axil;
logic [3:0] fn2pfn;

assign flr_from_axil        = mb2flr_push && mb2flr_data.data[0];
assign flr_from_pcie        = usr_flr_out.set;
assign flr_fn_in_captured   = flr_from_pcie ? usr_flr_out.fnc : flr_from_axil ? mb2flr_data.func : 'h0;
assign flr_pfn_in_captured  = flr_from_pcie ? fn2pfn : (flr_from_axil ? ((mb2flr_data.func < 4) ? mb2flr_data.func : mb2flr_data.vfg) : 'h0); 

// Get PF owning the VF (fn2pfn)
//   Parse the vector to find the first asserted bit
//   fn2pfn is only valid when the FLR is generated by PCIe 
logic [7:0] pf_vf_start [3:0];
logic [7:0] pf_vf_end   [3:0];
logic [3:0] pf_sel;
logic [3:0] find_one    [0:4];

genvar pfn_i;
generate
  for (pfn_i=0; pfn_i<4; pfn_i=pfn_i+1)
  begin : vf_map2_pf
    assign pf_vf_start [pfn_i] = attr_dma_pf[pfn_i].firstvf_offset + pfn_i;
    assign pf_vf_end   [pfn_i] = attr_dma_pf[pfn_i].firstvf_offset + pfn_i + attr_dma_pf[pfn_i].num_vfs - 1'b1; 
    assign pf_sel      [pfn_i] = (usr_flr_out.fnc <= pf_vf_end[pfn_i] && usr_flr_out.fnc >= pf_vf_start[pfn_i]) ? 1'b1 : 1'b0; // set bit [i] to 1 if a VF is associated with PF[i]
    assign find_one  [pfn_i+1] = pf_sel[pfn_i] ? pfn_i : find_one[pfn_i]; 
  end
endgenerate
assign find_one [0] = ~0; // desired default output if no bits set
assign fn2pfn       = (usr_flr_out.fnc < 4) ? usr_flr_out.fnc : find_one[4]; // no need to use the translated func number for PF


/************************************************
* Record FLR events
*************************************************/

logic       wr_fifo_empty;
logic [9:0] wr_fifo_data_o;
logic       flr_start;  // Trigger the FLR FSM
logic       flr_done;   // Remain high when FLR state machine stays in IDLE 
logic       flr_done_reg;
logic       flr_is_pf;
logic       flr_req_rd_en;
logic         flr_req_rd_en_reg; 
logic   [7:0] flr_fn_fifo_out;
logic   [1:0] req_pf_reg;
logic         new_flr_sel;

// Write the function number into FIFO
qdma_v2_0_1_GenericFIFO #(
  .BUF_DATAWIDTH(10),
  .BUF_DEPTH(256)
) flr_req_fifo (
  .clkin        (user_clk),
  .reset_n      (~reset),
  .sync_reset_n (1'b1),
  .WrEn         (flr_from_axil | flr_from_pcie),
  .DataIn       ({flr_pfn_in_captured, flr_fn_in_captured}), // [9:8]-pfn; [7:0]-fn
  .DataOut      (wr_fifo_data_o), // [9:8]-pfn; [7:0]-fn
  .empty        (wr_fifo_empty),
  .RdEn         (flr_req_rd_en),
  .full         (),
  .almost_empty (),
  .almost_full  ()
);

// Rd an pending FLR request from the FIFO
always_ff @ (posedge user_clk)
if (reset) begin
  flr_fn_fifo_out        <= 'h0;
  req_pf_reg        <= 'h0;
  flr_start         <= 'b0;
  new_flr_sel       <= 'b0;
  flr_req_rd_en_reg <= 'h0;
end
else begin
  if (flr_req_rd_en && ~flr_start) begin
    flr_fn_fifo_out <= wr_fifo_data_o[7:0];
    req_pf_reg      <= wr_fifo_data_o[9:8];
    new_flr_sel     <= 1'b1;
    flr_start       <= 1'b1;
  end
  else if (flr_start && flr_done) begin
    flr_start       <= 'b0;
    new_flr_sel     <= 'b0;
    req_pf_reg      <= req_pf_reg;
    flr_fn_fifo_out      <= flr_fn_fifo_out;
  end
  else begin
    flr_start       <= flr_start;
    new_flr_sel     <= new_flr_sel;
    req_pf_reg      <= req_pf_reg;
    flr_fn_fifo_out      <= flr_fn_fifo_out;

  end
  flr_req_rd_en_reg <= flr_req_rd_en;
end

assign flr_req_rd_en = ~wr_fifo_empty && ~new_flr_sel;
assign flr_is_pf     = (flr_fn_fifo_out < 4) ? 1'b1 : 1'b0;

always_ff @ (posedge user_clk)
if (reset) begin
  flr_state_reg <= 'h0;
end
else begin
  if (flr_req_rd_en_reg)
    // If FLR is VF, only set the state bit of the corresponding VF 
    flr_state_reg[flr_fn_fifo_out] <= 1'b1;
  else if (flr_done)
    // Clear the status bit after FLR finishes
    flr_state_reg[flr_fn_fifo_out] <= 1'b0;
  else 
    flr_state_reg <= flr_state_reg;
end


/************************************************
* Generate FLR to MDMA
*************************************************/

typedef enum bit [4:0] { 
  FLR_IDLE,
  FLR_USR,
  FLR_MAILBOX,
  FLR_PER_FUNC_INIT,
  FLR_GET_QUEUE,
  FLR_PER_Q_INIT,
  FLR_SEL_FMAP,     
  FLR_IND_STATUS_RD, 
  FLR_IND_STATUS_CPL, 
  FLR_PROG_IND_CTXT_CMD,
  FLR_RD_IND_CTXT_DATA_2,
  FLR_CTXT_SEL_DSC_SW_H2C,
  FLR_CTXT_SEL_DSC_HW_H2C,
  FLR_CTXT_SEL_DSC_CR_H2C,
  FLR_CTXT_SEL_DSC_SW_C2H,
  FLR_CTXT_SEL_PFTCH,
  FLR_CTXT_SEL_DSC_HW_C2H,
  FLR_CTXT_SEL_DSC_CR_C2H,
  FLR_CTXT_SEL_WRB,
  FLR_CTXT_SEL_INT_COAL,
//  FLR_C2H_QID2VEC_MAP_QID,
//  FLR_C2H_QID2VEC_MAP,
  FLR_INTR_IND_CTXT_DATA,
  FLR_PER_FUNC_DONE,
  FLR_DONE,
  FLR_ERROR     
} flr_state_t;

logic [11:0] qid;
logic [1:0]  flr_req_pf, flr_req_pf_reg;          // PF number of the targeted VF
logic [10:0]   qid_base, qid_base_reg;
logic [11:0]   q_count, q_count_reg;
logic [11:0]   q_index_reg, q_index;
logic [7:0]    vf_index_reg, vf_index;
logic          vf_flr_done_reg, vf_flr_done;
logic          pf_flr_done_reg, pf_flr_done;
logic          pf_flr_started, pf_flr_started_reg;
logic          ind_ctxt_busy, ind_ctxt_busy_reg; // 1: Busy; 0: DONE
logic [4:0]  ind_ctxt_sel, ind_ctxt_sel_reg;
flr_state_t  flr_cur_state, flr_nxt_state;
logic        mgmt_rd_pnd_reg, mgmt_rd_pnd;
logic [1:0]  mgmt_req_cmd_o;
logic [7:0]  mgmt_req_fnc_o;
logic [31:0] mgmt_req_adr_o;
logic [6:0]  mgmt_req_msc_o;
logic [31:0] mgmt_req_dat_o;
logic        mgmt_req_vld_o;
logic        mgmt_cpl_rdy_o;
logic [255:0] pre_flr_done_o;
logic         usr_flr_in_vld_o, usr_flr_in_vld_o_reg;
logic [7:0]   usr_flr_in_fnc_o;
logic            usr_flr_set_o, usr_flr_set_reg, usr_flr_set_reg_reg;
logic    [7:0]   usr_flr_fnc_o, usr_flr_fnc_reg;
logic            usr_flr_done_vld_reg; // capture and convert each usr_flr_done_vld pulse to level
logic            usr_flr_init_reg, usr_flr_init; // User FLR has been initiated
logic            usr_flr_timeout;
logic [24:0]     usr_flr_counter;
logic            mb_flr_set_o, mb_flr_set_reg, mb_flr_set_reg_reg; // Outbound signal to kick of FLR in mailbox
logic            mb_flr_done_vld_reg; // capture and convert each usr_flr_done_vld pulse to level
logic            mb_flr_init_reg, mb_flr_init; // User FLR can be initiated to mailbox; Internal signal
logic    [7:0]   mb_flr_fnc_o, mb_flr_fnc_reg;
logic            idl_stp_b_reg, idl_stp_b; 
logic  [7:0]   flr_fn_sel, flr_fn_sel_reg;      // The selected function number doing FLR. Can be either VF or PF

assign qid = qid_base_reg + q_index - 1'b1;
 
// There is only one state machine for all functions.
// Procedure of clearing Context Register
//    1) Assign initial ind_ctxt_sel to FMAP
//    2) Check status of ind reg
//    3) If ind reg is not busy, jump to invalidate the selected ctx.
//    4) Perform invalidation; Assign ind_ctxt_sel to next state; Jump to (2)
always @ (*) 
begin
  flr_nxt_state = flr_cur_state;
  case (flr_cur_state)

    // Waiting to initiate PER-FLR
    FLR_IDLE : 
      if (flr_start)  flr_nxt_state = FLR_USR;
      else            flr_nxt_state = flr_cur_state;

    // Start user FLR and wait until user FLR complete or timeout 
    FLR_USR :
      if (usr_flr_set_reg && usr_flr_done_vld_reg && ~usr_flr_timeout)  
        flr_nxt_state = FLR_MAILBOX;  
      else if (usr_flr_set_reg && ~usr_flr_done_vld_reg && usr_flr_timeout)  
        flr_nxt_state = FLR_ERROR;  
      else  
        flr_nxt_state = flr_cur_state; 

    // Start Mailbox FLR
    FLR_MAILBOX :
      flr_nxt_state = FLR_PER_FUNC_INIT;

    // Select a function and initiate FLR for QDMA
    //   For PF, we will do FLR iteratively to all it VFs first. Then perform FLR to PF itself.
    //   When both VF and PF FLR completes, go to FLR_IDLE to terminate FLR
    FLR_PER_FUNC_INIT :
      if (pf_flr_done_reg && vf_flr_done_reg)  flr_nxt_state = FLR_DONE;
      else                                     flr_nxt_state = FLR_GET_QUEUE;

    // Read FMAP register: Fetch the queue base and queue count from FMAP 
    FLR_GET_QUEUE :
      if (mgmt_rd_pnd_reg && mgmt_cpl_vld)  flr_nxt_state = FLR_PER_Q_INIT; 
      else                                  flr_nxt_state = flr_cur_state;

    // Nuke the context structure and config space registers of each queue
    // After nuking the context of each queue (q_index_reg==q_count_reg), FMAP will be destroted. 
    FLR_PER_Q_INIT :
      if (q_count_reg == 0 || (q_index_reg == q_count_reg)) flr_nxt_state = FLR_SEL_FMAP; // Destroy FMAP
      else                                                  flr_nxt_state = FLR_IND_STATUS_RD;

    // Nuke FMAP
    // Per function FLR process will be completed after zeroing out FMAP
    FLR_SEL_FMAP :  
      if (mgmt_req_rdy) flr_nxt_state = FLR_PER_FUNC_DONE;
      else              flr_nxt_state = flr_cur_state;

    // Before and after each RD/Wr on context, we need to wait until the busy bit in in the 
    // MDMA_IND_CTXT_CMD_A register is deasserted
    FLR_IND_STATUS_RD : 
      if (mgmt_rd_pnd_reg && mgmt_cpl_vld) flr_nxt_state = FLR_IND_STATUS_CPL;
      else                                 flr_nxt_state = flr_cur_state;

    // If the context is busy, we will keep polling MDMA_IND_CTXT_CMD_A
    // If the context is not busy, we will start nuking each queue context
    FLR_IND_STATUS_CPL : 
      if (~ind_ctxt_busy_reg) begin
        case (ind_ctxt_sel_reg)
          MDMA_CTXT_SEL_DSC_SW_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_SW_H2C;
          MDMA_CTXT_SEL_DSC_HW_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_HW_H2C;
          MDMA_CTXT_SEL_DSC_CR_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_CR_H2C;
          MDMA_CTXT_SEL_DSC_SW_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_SW_C2H;
          MDMA_CTXT_SEL_PFTCH      : flr_nxt_state = FLR_CTXT_SEL_PFTCH;
          MDMA_CTXT_SEL_DSC_HW_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_HW_C2H;
          MDMA_CTXT_SEL_DSC_CR_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_CR_C2H;
          MDMA_CTXT_SEL_WRB        : flr_nxt_state = FLR_CTXT_SEL_WRB;
          MDMA_CTXT_SEL_INT_COAL   : flr_nxt_state = FLR_CTXT_SEL_INT_COAL;
          default                  : flr_nxt_state = FLR_ERROR;
        endcase
      end
      else flr_nxt_state = FLR_IND_STATUS_RD;

    // Program MDMA_IND_CTXT_CMD register to RD/WR a context
    FLR_PROG_IND_CTXT_CMD :
      if (mgmt_req_rdy) flr_nxt_state = FLR_RD_IND_CTXT_DATA_2; 
      else              flr_nxt_state = flr_cur_state;

    // RD IND_CTXT_DATA_2 register  
    //   We are only interested in the idl_stp_b of the Hardware Descriptor Context Structures 
    FLR_RD_IND_CTXT_DATA_2 :
      if (mgmt_rd_pnd_reg && mgmt_cpl_vld) flr_nxt_state = (ind_ctxt_sel_reg == MDMA_CTXT_SEL_DSC_HW_H2C) ? FLR_CTXT_SEL_DSC_HW_H2C : 
                                                           (ind_ctxt_sel_reg == MDMA_CTXT_SEL_DSC_HW_C2H) ? FLR_CTXT_SEL_DSC_HW_C2H : FLR_ERROR;
      else                                 flr_nxt_state = flr_cur_state;

    // RD CTXT_SEL_DSC_HW_H2C or CTXT_SEL_DSC_HW_C2H, and wait on idl_stp_b = 1
    // If idl_stp_b is 1, keep polling IND_CTXT_DATA_2
    FLR_CTXT_SEL_DSC_HW_H2C, FLR_CTXT_SEL_DSC_HW_C2H :
      if      (idl_stp_b)     flr_nxt_state = FLR_PROG_IND_CTXT_CMD;
      else if (mgmt_req_rdy)  flr_nxt_state = FLR_IND_STATUS_RD;
      else                    flr_nxt_state = flr_cur_state; 

    // before clearing the next context, go to FLR_IND_STATUS_RD state to polling
    // the MDMA_IND_CTXT_CMD_A register to make sure the status is not busy. 
    FLR_CTXT_SEL_DSC_SW_H2C, FLR_CTXT_SEL_DSC_CR_H2C, FLR_CTXT_SEL_DSC_SW_C2H, 
    FLR_CTXT_SEL_DSC_CR_C2H, FLR_CTXT_SEL_PFTCH, FLR_CTXT_SEL_WRB :
      if (mgmt_req_rdy) flr_nxt_state = FLR_IND_STATUS_RD; 
      else              flr_nxt_state = flr_cur_state;

    // This is the last context of a queue being cleared
    // The next state will start clearing the config space register
    FLR_CTXT_SEL_INT_COAL : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_C2H_QID2VEC_MAP_QID; 
      if (mgmt_req_rdy) flr_nxt_state = FLR_PER_Q_INIT;
      else              flr_nxt_state = flr_cur_state;

//    // Clear C2H_QID2VEC_MAP_QID register
//    FLR_C2H_QID2VEC_MAP_QID : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_C2H_QID2VEC_MAP; 
//      else              flr_nxt_state = flr_cur_state;
//
//    // Clear C2H_QID2VEC_MAP register
//    // This is the latest state of the per queue FLR process
//    FLR_C2H_QID2VEC_MAP : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_PER_Q_INIT;
//      else              flr_nxt_state = flr_cur_state;
//
//    // Reset proecess of a function is completed
//    // FLR is not complete as FLR on PF needs to reset all its associated VFs 
    FLR_PER_FUNC_DONE : 
      flr_nxt_state = FLR_PER_FUNC_INIT;

    // Wait until FLR in usr logic and mailbox complete
    FLR_DONE : 
      if ((usr_flr_set_reg && usr_flr_done_vld_reg) && (mb_flr_set_reg && mb_flr_done_vld_reg)) flr_nxt_state = FLR_IDLE;  
      else                                                                                      flr_nxt_state = flr_cur_state;

    // FLR errors detected
    //   DMA will not be blocked by user FLR. But user FLR timeout will be logged.
    FLR_ERROR :
      if (usr_flr_timeout) flr_nxt_state = FLR_SEL_FMAP; 
      else  flr_nxt_state = flr_cur_state;

    default: flr_nxt_state = flr_cur_state;
  endcase
end

always_ff @ (posedge user_clk) 
  if (reset) flr_cur_state <= FLR_IDLE;
  else       flr_cur_state <= flr_nxt_state;

always_comb
begin 
    flr_req_pf          = flr_req_pf_reg;
    qid_base            = qid_base_reg;
    q_count             = q_count_reg;
    q_index             = q_index_reg;
    mgmt_req_cmd_o      = 'h0;
    mgmt_req_fnc_o      = 'h0;
    mgmt_req_adr_o      = 'h0;
    mgmt_req_dat_o      = 'h0;
    mgmt_req_msc_o      = 'h0;
    mgmt_req_vld_o      = 'h0;
    mgmt_cpl_rdy_o      = 'h1;
    ind_ctxt_sel        = ind_ctxt_sel_reg;
    ind_ctxt_busy       = ind_ctxt_busy_reg;
    vf_index            = vf_index_reg;
    usr_flr_init        = usr_flr_init_reg;
    pf_flr_started      = pf_flr_started_reg;
    pre_flr_done_o      = pre_flr_done;
    pf_flr_done         = pf_flr_done_reg;
    vf_flr_done         = vf_flr_done_reg;
    flr_done            = flr_done_reg;
    flr_fn_sel          = flr_fn_sel_reg;
    usr_flr_in_fnc_o    = usr_flr_in.fnc;
    usr_flr_in_vld_o    = usr_flr_in_vld_o_reg;
    usr_flr_set_o       = usr_flr_set_reg;
    usr_flr_fnc_o       = usr_flr_fnc_reg;
    mb_flr_init         = mb_flr_init_reg;
    mb_flr_set_o        = mb_flr_set_reg;
    mb_flr_fnc_o        = mb_flr_fnc_reg;
    mgmt_rd_pnd         = mgmt_rd_pnd_reg;
    idl_stp_b           = idl_stp_b_reg;

  case (flr_cur_state)
  FLR_IDLE: begin
    flr_req_pf          = flr_req_pf_reg;
    qid_base            = qid_base_reg;
    q_count             = q_count_reg;
    q_index             = q_index_reg;
    mgmt_req_cmd_o      = 'h0;
    mgmt_req_fnc_o      = 'h0;
    mgmt_req_adr_o      = 'h0;
    mgmt_req_vld_o      = 'h0;
    mgmt_req_dat_o      = 'h0;
    mgmt_req_msc_o      = 'h0;
    mgmt_cpl_rdy_o      = 1'b1;
    ind_ctxt_sel        = ind_ctxt_sel_reg;
    vf_index            = vf_index_reg;
    usr_flr_init        = usr_flr_init_reg;
    flr_fn_sel          = flr_fn_sel_reg;
    usr_flr_in_fnc_o    = usr_flr_in.fnc;
    usr_flr_in_vld_o    = 1'b0;
    pf_flr_started      = 1'b1;
    pf_flr_done         = 1'b0;
    vf_flr_done         = 1'b0;
    pre_flr_done_o      = 'h0; 
    flr_done            = 1'b0;
    usr_flr_set_o       = 1'b0;
    usr_flr_fnc_o       = usr_flr_fnc_reg;
    mb_flr_init         = mb_flr_init_reg;
    mb_flr_set_o        = mb_flr_set_reg;
    mb_flr_fnc_o        = mb_flr_fnc_reg;
    mgmt_rd_pnd         = mgmt_rd_pnd_reg;
    ind_ctxt_busy       = ind_ctxt_busy_reg;
  end
  FLR_USR : begin
    // Kick off user FLR
    usr_flr_init     = 'b1;
    usr_flr_set_o    = 1'b1;  
    usr_flr_fnc_o  = req_pf_reg;
  end
  FLR_MAILBOX : begin
    // Kick off mailbox FLR
    mb_flr_init      = 'b1;
    mb_flr_set_o     = 1'b1;  // kick off mailbox FLR
    mb_flr_fnc_o     = req_pf_reg;   
  end
  FLR_PER_FUNC_INIT : begin
    flr_req_pf       = req_pf_reg;
    q_index          = 'h0; // start from the first Q 
    mgmt_req_vld_o   = 'h0;
    mgmt_rd_pnd      = 'b0;
    pre_flr_done_o [flr_fn_sel_reg] = 1'b0; // generate a one-cycle pulse
    // FLR is from PF and pick a VF
    if (flr_is_pf && ~vf_flr_done_reg && ~pf_flr_done_reg) begin
      flr_fn_sel     = attr_dma_pf[req_pf_reg].firstvf_offset + vf_index_reg;
      if (vf_index_reg < attr_dma_pf[req_pf_reg].num_vfs)
        vf_index     = vf_index_reg + 1'b1; 
      else
        vf_index     = 'h0; 
    end
    // Do FLR to PF itself
    else if (flr_is_pf && vf_flr_done_reg && ~pf_flr_done_reg) begin
      pf_flr_started = 1'b1;
      flr_fn_sel     = req_pf_reg;
    end
    // Do FLR to VF
    else if (~flr_is_pf && (~vf_flr_done_reg)) begin
      flr_fn_sel     = flr_fn_fifo_out;
    end
    else begin
      flr_fn_sel     = flr_fn_sel_reg;
    end
  end
  FLR_GET_QUEUE : begin
    // use flr_req_pf_reg to access FMAP
    if (~mgmt_rd_pnd_reg) begin
      mgmt_req_cmd_o  = 1'b0;
      mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;  // Must use pfn of the targeted VF
      mgmt_req_adr_o  = MDMA_CMN_FMAP_START_A+flr_fn_sel_reg*4;  
      mgmt_req_vld_o  = 1'b1;
      if (mgmt_req_rdy)
        mgmt_rd_pnd   = 1'b1;
      else
        mgmt_rd_pnd   = 1'b0;
    end
    // find out queues owned by this function  
    else begin
      mgmt_req_vld_o  = 1'b0;
      if (mgmt_cpl_vld) begin
        qid_base      = mgmt_cpl.dat[10:0];
        q_count       = mgmt_cpl.dat[22:11];
        mgmt_rd_pnd = 1'b0;
        ind_ctxt_sel  = MDMA_CTXT_SEL_DSC_SW_H2C; 
      end
      else begin
        qid_base      = qid_base_reg;
        q_count       = q_count_reg;
        mgmt_rd_pnd   = mgmt_rd_pnd_reg;
        ind_ctxt_sel  = ind_ctxt_sel_reg;
      end
    end
  end
  FLR_PER_Q_INIT: begin
    mgmt_req_vld_o  = 1'b0; // Must deassert the request
    if (q_count_reg == 0) begin
      q_index = 'h0;
    end
    else if (q_index_reg <= q_count_reg - 1'b1) begin
      q_index  = q_index_reg + 1'b1;
      ind_ctxt_sel = MDMA_CTXT_SEL_DSC_SW_H2C;
    end
    else begin
      q_index  = q_index_reg;
      ind_ctxt_sel = ind_ctxt_sel_reg;
    end
  end
  FLR_SEL_FMAP: begin        
    // Destroy the Q associated with this function
    // This is the last step of FLR for each function
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_CMN_FMAP_START_A+flr_fn_sel_reg*4;  
    mgmt_req_dat_o  = 'h0;
    mgmt_req_vld_o  = 1'b1;
  end
  FLR_IND_STATUS_RD: begin
    // Mgmt i/f does not have a pending read and ready is high, issue a RD to MDMA_IND_CTXT_CMD
    if (~mgmt_rd_pnd_reg) begin
      mgmt_req_vld_o = 1'b1;
      mgmt_req_fnc_o = flr_req_pf_reg | 8'h0;
      mgmt_req_cmd_o = 1'b0;
      mgmt_req_adr_o = MDMA_IND_CTXT_CMD_A;  
      ind_ctxt_busy  = 1'b1;
      if (mgmt_req_rdy)  mgmt_rd_pnd = 1'b1;
      else               mgmt_rd_pnd = 1'b0; 
    end
    // IF there is a pending RD on Mgmt i/f, wait for the completion and extract the status bit
    else begin
      mgmt_req_vld_o  = 1'b0;
      if (mgmt_cpl_vld) begin
        ind_ctxt_busy = mgmt_cpl.dat[0];
        mgmt_rd_pnd   = 1'b0;
      end
      else begin
        ind_ctxt_busy = 1'b1;
        mgmt_rd_pnd = mgmt_rd_pnd_reg; 
      end
    end
  end
  FLR_IND_STATUS_CPL : begin
    // only state change
  end
  FLR_PROG_IND_CTXT_CMD : begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A;
    mgmt_req_dat_o  = 'h0 | {qid, MDMA_CTXT_CMD_RD, MDMA_CTXT_SEL_DSC_HW_H2C, 1'b1};   
    mgmt_req_vld_o  = 1'b1;
  end
  FLR_RD_IND_CTXT_DATA_2 : begin
    if (~mgmt_rd_pnd_reg) begin
      mgmt_req_vld_o = 1'b1;
      mgmt_req_fnc_o = flr_req_pf_reg | 8'h0;
      mgmt_req_cmd_o = 1'b0;
      mgmt_req_adr_o = MDMA_IND_CTXT_DATA_A2; 
      ind_ctxt_busy  = 1'b1;
      if (mgmt_req_rdy)  mgmt_rd_pnd = 1'b1;
      else               mgmt_rd_pnd = 1'b0; 
    end
    else begin
      mgmt_req_vld_o  = 1'b0;
      if (mgmt_cpl_vld) begin
        idl_stp_b = mgmt_cpl.dat[9];
        mgmt_rd_pnd   = 1'b0;
      end
      else begin
        ind_ctxt_busy = 1'b1;
        mgmt_rd_pnd = mgmt_rd_pnd_reg; 
      end
    end
  end
  FLR_CTXT_SEL_DSC_SW_H2C: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A;
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_SW_H2C, 1'b1};   
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_HW_H2C; 
    // This will enable polling on idl_stop_b before reseting CTXT_SEL_DSC_HW_H2C
    idl_stp_b       = 1'b1;
  end
  FLR_CTXT_SEL_DSC_HW_H2C: begin
    if (~idl_stp_b) begin
      mgmt_req_cmd_o  = 1'b1;
      mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
      mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
      mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_HW_H2C, 1'b1};  
      mgmt_req_vld_o  = 1'b1;
      // Set command and select ctxt for the next state
      ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_CR_H2C;   
    end
  end
  FLR_CTXT_SEL_DSC_CR_H2C: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_CR_H2C, 1'b1}; 
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_SW_C2H;  
  end
  FLR_CTXT_SEL_DSC_SW_C2H: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_SW_C2H, 1'b1};  
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_PFTCH;  
    // This will enable polling on idl_stop_b before reseting CTXT_SEL_DSC_HW_C2H
    idl_stp_b       = 1'b1;
  end
  FLR_CTXT_SEL_PFTCH: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_PFTCH, 1'b1};  
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_HW_C2H;  
  end
  FLR_CTXT_SEL_DSC_HW_C2H: begin
    if (~idl_stp_b) begin
      mgmt_req_cmd_o  = 1'b1;
      mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
      mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
      mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_HW_C2H, 1'b1};  
      mgmt_req_vld_o  = 1'b1;
      // Set command and select ctxt for the next state
      ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_CR_C2H;  
    end
  end
  FLR_CTXT_SEL_DSC_CR_C2H: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_DSC_CR_C2H, 1'b1};  
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_WRB;  
  end
  FLR_CTXT_SEL_WRB: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
    mgmt_req_dat_o  = 'h0 | {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_WRB, 1'b1}; 
    mgmt_req_vld_o  = 1'b1;
    // Set command and select ctxt for the next state
    ind_ctxt_sel    = MDMA_CTXT_SEL_INT_COAL;  
  end
  FLR_CTXT_SEL_INT_COAL: begin
    mgmt_req_cmd_o  = 1'b1;
    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A;
    mgmt_req_dat_o  = {qid, FLR_CTXT_IND_CMD, MDMA_CTXT_SEL_INT_COAL, 1'b1} | 'h0;  
    mgmt_req_vld_o  = 1'b1;
  end
//  FLR_C2H_QID2VEC_MAP_QID: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_C2H_QID2VEC_MAP_QID;
//    mgmt_req_dat_o  = 'h0 | qid; 
//    mgmt_req_vld_o  = 1'b1;
//  end
//  FLR_C2H_QID2VEC_MAP: begin
//    // Clear the QID2VEC mapping
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_C2H_QID2VEC_MAP;  
//    mgmt_req_dat_o  = 'h0;
//    mgmt_req_vld_o  = 1'b1;
//  end
  FLR_PER_FUNC_DONE: begin
    // set the state to idle for this function
    pre_flr_done_o [flr_fn_sel_reg] = 1'b1;
    mgmt_req_vld_o  = 1'b0; // generate only a one-cycle pulse
    if (flr_is_pf && ~vf_flr_done_reg) begin
      if (vf_index_reg == attr_dma_pf[req_pf_reg].num_vfs)
        vf_flr_done = 1'b1;
      else
        vf_flr_done = 1'b0;
    end
    else if (flr_is_pf && pf_flr_started_reg) begin
      pf_flr_done    = 1'b1;
      pf_flr_started = 1'b0;
    end
    else if (~flr_is_pf && ~vf_flr_done_reg) begin
      pf_flr_done = 1'b1;  // MUST assert both pf_flr_done and vf_flr_done
      vf_flr_done = 1'b1;
    end
    else begin
      pf_flr_done = 1'b0;
      vf_flr_done = 1'b0;
    end
  end
  FLR_DONE: begin
    usr_flr_in_fnc_o = flr_fn_sel_reg;

    // Wait for completion of FLR done in both mailbox and user logic
    if ((usr_flr_set_reg && usr_flr_done_vld_reg) && (mb_flr_set_reg && mb_flr_done_vld_reg)) begin
      usr_flr_init        = 'b0;
      mb_flr_init         = 'b0;
      usr_flr_in_vld_o    = 1'b1;
      mb_flr_set_o        = 1'b0;
      usr_flr_set_o       = 1'b0;
      flr_done            = 1'b1;
    end
    else begin
      usr_flr_init        = usr_flr_init_reg;
      mb_flr_init         = mb_flr_init_reg; 
      usr_flr_in_vld_o    = 1'b0;
      mb_flr_set_o        = mb_flr_set_reg;
      usr_flr_set_o       = usr_flr_set_reg;
      flr_done            = flr_done_reg;
    end
  end
  endcase
end


/************************************************
* Generate FLR to user logic
*************************************************/
// Generate a one-cycle pulse usr_flr_set to kick off FLR in user logic
// User should reply usr_flr_done_vld when finish

logic [255:0] usr_flr_err;

always_ff @ (posedge user_clk) begin
  if (reset) usr_flr_err <= '0;
  else if (usr_flr_timeout) usr_flr_err[flr_fn_sel_reg] <= 1'b1;
  else usr_flr_err <= usr_flr_err;
end

always_ff @ (posedge user_clk) begin
  if (reset) begin
    usr_flr_done_vld_reg  <= 'b0;
    usr_flr_counter       <= '0;
    usr_flr_timeout       <= 'b0;
  end
  else begin

    // usr_flr_init_* is used for FSM control 
    // usr_flr_init_reg will be high during the course of user logic FLR
    // Capture user logic FLR done here
    if (usr_flr_init_reg) 
      usr_flr_done_vld_reg  <= usr_flr_done_vld_reg ? 1'b1 : (usr_flr_done_vld && (usr_flr_done_fnc == usr_flr_fnc_reg)); // retain usr_flr_done_vld HIGH 
    else
      usr_flr_done_vld_reg  <= 'b0;

    // Check User FLR timeout
    if (usr_flr_init_reg && ~usr_flr_done_vld_reg)                         
      usr_flr_counter <= usr_flr_counter + 1'b1;
    else if ((usr_flr_counter == USR_FLR_TIMEOUT_LIMIT) || usr_flr_done_vld_reg) 
      usr_flr_counter <= '0;    
    else                                               
      usr_flr_counter <= usr_flr_counter;

    // Assert usr flr timeout
    if (usr_flr_counter == USR_FLR_TIMEOUT_LIMIT) usr_flr_timeout <= 1'b1;    
    else if (usr_flr_done_vld_reg)                usr_flr_timeout <= 1'b0;
    else                                          usr_flr_timeout <= usr_flr_timeout;

  end
end
assign usr_flr_set = usr_flr_set_reg && ~usr_flr_set_reg_reg; // generate a one-cycle pulse to user logic 
assign usr_flr_fnc = usr_flr_set_reg ? usr_flr_fnc_reg : 'h0; 
assign usr_flr_clr = flr_done && ~flr_done_reg;


/************************************************
* Generate FLR to mailbox
*************************************************/

always_ff @ (posedge user_clk) begin
  if (reset) begin
    mb_flr_done_vld_reg  <= 'b0;
  end
  else begin
    if (mb_flr_init_reg) begin // Must remain high for the duration of Pre-FLR
      mb_flr_done_vld_reg <= mb_flr_done_vld_reg ? 1'b1 : mb_flr_done_vld; // retain mb_flr_done_vld HIGH 
    end
    else begin
      mb_flr_done_vld_reg <= 'b0;
    end
  end
end
assign mb_flr_set = mb_flr_set_reg & ~mb_flr_set_reg_reg; // generate a one-cycle pulse to user logic 
assign mb_flr_fnc = mb_flr_set_reg ? mb_flr_fnc_reg : 'h0; 


/************************************************
* Pre-FLR state machine output register  
*************************************************/

always_ff @ (posedge user_clk) 
begin
  if (reset) begin
    flr_req_pf_reg        <= 'h0;
    mgmt_rd_pnd_reg       <= 1'b0;
    q_index_reg           <= 'h0;
    pf_flr_started_reg    <= 'b0;
    pf_flr_done_reg       <= 1'b0;
    vf_flr_done_reg       <= 1'b0;
    vf_index_reg          <= 'h0;
    qid_base_reg          <= 'h0;
    q_count_reg           <= 'h0;
    ind_ctxt_sel_reg      <= 'h0;
    usr_flr_init_reg      <= 'h0;
    mb_flr_init_reg       <= 'h0;
    flr_done_reg          <= 'h0;
    flr_fn_sel_reg        <= 'h0;
    ind_ctxt_busy_reg     <= 'h1;
    mb_flr_set_reg_reg    <= 'b0;
    usr_flr_set_reg_reg   <= 'b0;
    pre_flr_done          <= 'h0;
    usr_flr_in.fnc        <= 'h0;
    usr_flr_fnc_reg       <= 'h0;
    mb_flr_fnc_reg        <= 'h0;
    usr_flr_in_vld_o_reg  <= 'h0;
    idl_stp_b_reg         <= 1'b1;
    usr_flr_set_reg       <= 'b0;
    mb_flr_set_reg        <= 'b0;
  end
  else begin
    flr_req_pf_reg        <= flr_req_pf;
    mgmt_rd_pnd_reg       <= mgmt_rd_pnd;
    q_index_reg           <= q_index;
    pf_flr_started_reg    <= pf_flr_started;
    pf_flr_done_reg       <= pf_flr_done; 
    vf_flr_done_reg       <= vf_flr_done; 
    vf_index_reg          <= vf_index;
    qid_base_reg          <= qid_base;
    q_count_reg           <= q_count;
    ind_ctxt_sel_reg      <= ind_ctxt_sel;
    usr_flr_init_reg      <= usr_flr_init;
    mb_flr_init_reg       <= mb_flr_init;
    flr_done_reg          <= flr_done;
    flr_fn_sel_reg        <= flr_fn_sel;
    ind_ctxt_busy_reg     <= ind_ctxt_busy;
    mb_flr_set_reg        <= mb_flr_set_o;
    mb_flr_set_reg_reg    <= mb_flr_set_reg;
    usr_flr_set_reg       <= usr_flr_set_o;
    usr_flr_set_reg_reg   <= usr_flr_set_reg;
    pre_flr_done          <= pre_flr_done_o;
    usr_flr_in.fnc        <= usr_flr_in_fnc_o;
    usr_flr_fnc_reg       <= usr_flr_fnc_o;
    mb_flr_fnc_reg        <= mb_flr_fnc_o;
    usr_flr_in_vld_o_reg  <= usr_flr_in_vld_o;
    idl_stp_b_reg         <= idl_stp_b;
  end
end
//    ) (
//    input                                   user_clk,
//    input                                   reset,
   
//    input    attr_dma_pf_t    [3:0]         attr_dma_pf,

//    // User FLR request 
//    output    usr_flr_if_in_t               usr_flr_in,  // Output to dma_flr_cntl.sv  (Used by Everest)
//    input     usr_flr_if_out_t              usr_flr_out, // Input from dma_flr_cntl.sv 
//                                                         // signal done bit until both user and mgmt FLR complete

//    // FLR request from AXIL (forwarded by mailbox)
//    input   mailbox_mb2flr_data_t           mb2flr_data,
//    input                                   mb2flr_push,

//    // Struct holding the flr request
//    output  logic  [255:0]                  flr_state_reg,
    
//    // Status of MDMA FLR
//    output  logic  [255:0]                  pre_flr_done, // A per function one-cycle pulse for debugging 

//    // Management Interface to perform FLR on register space         
//    output  dma_mgmt_req_t                  mgmt_req,
//    output  logic                           mgmt_req_vld,
//    input                                   mgmt_req_rdy,

//    input   dma_mgmt_cpl_t                  mgmt_cpl, 
//    input                                   mgmt_cpl_vld,
//    output  logic                           mgmt_cpl_rdy, //  set to 1 to always ready to accept completion packet

//    // FLR to mailbox
//    output logic                            mb_flr_set,
//    output logic [7:0]                      mb_flr_fnc,
//    input                                   mb_flr_done_vld,
 
//    // FLR to user logic
//    output logic [7:0]                      usr_flr_fnc, // user function to do FLR
//    output logic                            usr_flr_set, // one-cycle pulse to start the user FLR
//    output                                  usr_flr_clr,
//    input  [7:0]                            usr_flr_done_fnc, 
//    input                                   usr_flr_done_vld // end-triggered. expect a one cycle pulse indicating user FLR completion 
//    );

//// MDMA_MGMT_PRE_FLR:
////   [0]:   RW  Start
////              SW set this bit to kicl off the FLR
////              SW must poll this bit to check the status of FLR; 
////              It is cleared when both user FLR and MDMA FLR complete
////   [31:1]     Reserved
//localparam MDMA_IND_CTXT_CMD_A = MDMA_CMN_IND_START_A + 'h24;
//`ifdef FLR_USE_CLR
//  localparam FLR_CTXT_IND_CMD = MDMA_CTXT_CMD_CLR;
//`else
//  localparam FLR_CTXT_IND_CMD = MDMA_CTXT_CMD_INV;
//`endif

///************************************************
//* Buffer mgmt i/f
//*************************************************/
///*logic          mgmt_req_rdy_reg;
//dma_mgmt_cpl_t mgmt_cpl_reg;
//logic          mgmt_cpl_vld_reg;

//always_ff @ (posedge user_clk)
//begin
//  if (reset) begin
//    mgmt_req_rdy_reg <= 1'b0;
//    mgmt_cpl_reg.dat <= 'h0;
//    mgmt_cpl_vld_reg <= 'h0;
//  end
//  else begin
//    mgmt_req_rdy_reg <= mgmt_req_rdy;
//    mgmt_cpl_reg.dat <= mgmt_cpl.dat;
//    mgmt_cpl_vld_reg <= mgmt_cpl_vld;

//  end
//end
//*/

///************************************************
//* Gather FLR events
//*************************************************/
//// For Diablo, FLR comes from AXIL Master I/F. 
//// For Everest, FLR comes from usr_flr_out fom flr controller

//logic [7:0] flr_fn_in_captured;
//logic [1:0] flr_pfn_in_captured;
//logic       flr_from_pcie;
//logic       flr_from_axil;
//logic [3:0] fn2pfn;

//assign flr_from_axil        = mb2flr_push && mb2flr_data.data[0];
//assign flr_from_pcie        = usr_flr_out.set;
//assign flr_fn_in_captured   = flr_from_pcie ? usr_flr_out.fnc : flr_from_axil ? mb2flr_data.func : 'h0;
//assign flr_pfn_in_captured  = flr_from_pcie ? fn2pfn : (flr_from_axil ? ((mb2flr_data.func < 4) ? mb2flr_data.func : mb2flr_data.vfg) : 'h0); 

//// Get PF owning the VF (fn2pfn)
////   Parse the vector to find the first asserted bit
////   fn2pfn is only valid when the FLR is generated by PCIe 
//logic [7:0] pf_vf_start [3:0];
//logic [7:0] pf_vf_end   [3:0];
//logic [3:0] pf_sel;
//logic [3:0] find_one    [0:4];

//genvar pfn_i;
//generate
//  for (pfn_i=0; pfn_i<4; pfn_i=pfn_i+1)
//  begin : vf_map2_pf
//    assign pf_vf_start [pfn_i] = attr_dma_pf[pfn_i].firstvf_offset + pfn_i;
//    assign pf_vf_end   [pfn_i] = attr_dma_pf[pfn_i].firstvf_offset + pfn_i + attr_dma_pf[pfn_i].num_vfs - 1'b1; 
//    assign pf_sel      [pfn_i] = (usr_flr_out.fnc <= pf_vf_end[pfn_i] && usr_flr_out.fnc >= pf_vf_start[pfn_i]) ? 1'b1 : 1'b0; // set bit [i] to 1 if a VF is associated with PF[i]
//    assign find_one  [pfn_i+1] = pf_sel[pfn_i] ? pfn_i : find_one[pfn_i]; 
//  end
//endgenerate
//assign find_one [0] = ~0; // desired default output if no bits set
//assign fn2pfn       = (usr_flr_out.fnc < 4) ? usr_flr_out.fnc : find_one[4]; // no need to use the translated func number for PF


///************************************************
//* Record FLR events
//*************************************************/

//logic       wr_fifo_empty;
//logic [9:0] wr_fifo_data_o;
//logic       flr_start;  // Trigger the FLR FSM
//logic       flr_done;   // Remain high when FLR state machine stays in IDLE 
//logic       flr_done_reg;
//logic       flr_is_pf;
//logic       flr_req_rd_en;
//reg         flr_req_rd_en_reg; 
//reg   [7:0] req_fn_reg;
//reg   [1:0] req_pf_reg;
// reg         new_flr_sel;

//// Write the function number into FIFO
//qdma_v2_0_1_GenericFIFO #(
//  .BUF_DATAWIDTH(10),
//  .BUF_DEPTH(256)
//) flr_req_fifo (
//  .clkin        (user_clk),
//  .reset_n      (~reset),
//  .sync_reset_n (1'b1),
//  .WrEn         (flr_from_axil | flr_from_pcie),
//  .DataIn       ({flr_pfn_in_captured, flr_fn_in_captured}), // [9:8]-pfn; [7:0]-fn
//  .DataOut      (wr_fifo_data_o), // [9:8]-pfn; [7:0]-fn
//  .empty        (wr_fifo_empty),
//  .RdEn         (flr_req_rd_en),
//  .full         (),
//  .almost_empty (),
//  .almost_full  ()
//);

//// Rd an pending FLR request from the FIFO
//always_ff @ (posedge user_clk)
//if (reset) begin
//  req_fn_reg        <= 'h0;
//  req_pf_reg        <= 'h0;
//  flr_start         <= 'b0;
//  new_flr_sel       <= 'b0;
//  flr_req_rd_en_reg <= 'h0;
//end
//else begin
//  if (flr_req_rd_en && ~flr_start) begin
//    req_fn_reg      <= wr_fifo_data_o[7:0];
//    req_pf_reg      <= wr_fifo_data_o[9:8];
//    new_flr_sel     <= 1'b1;
//    flr_start       <= 1'b1;
//  end
//  else if (flr_start && flr_done_reg) begin
//    flr_start       <= 'b0;
//    new_flr_sel     <= 'b0;
//    req_pf_reg      <= req_pf_reg;
//    req_fn_reg      <= req_fn_reg;
//  end
//  else begin
//    flr_start       <= flr_start;
//    new_flr_sel     <= new_flr_sel;
//    req_pf_reg      <= req_pf_reg;
//    req_fn_reg      <= req_fn_reg;

//  end
//  flr_req_rd_en_reg <= flr_req_rd_en;
//end

//assign flr_req_rd_en = ~wr_fifo_empty && flr_done_reg && ~new_flr_sel;
//assign flr_is_pf     = (req_fn_reg < 4) ? 1'b1 : 1'b0;

// logic  [7:0]   flr_req_fn;          // The selected function number doing FLR. Can be either VF or PF
// logic  [7:0]   flr_req_fn_reg;          // The selected function number doing FLR. Can be either VF or PF
// logic  [255:0] vf_mask_by_pf;


//always_ff @ (posedge user_clk)
//if (reset) begin
//  flr_state_reg <= 'h0;
//end
//else begin
//  if (flr_req_rd_en_reg)
//    // If FLR is VF, only set the state bit of the corresponding VF 
//    flr_state_reg[req_fn_reg] <= 1'b1;
//  else if (flr_done)
//    // Clear the status bit after FLR finishes
//    flr_state_reg[req_fn_reg] <= 1'b0;
//  else 
//    flr_state_reg <= flr_state_reg;
//end


///************************************************
//* Generate FLR to MDMA
//*************************************************/

//typedef enum bit [4:0] { 
//  FLR_IDLE = 0,
//  FLR_PER_FUNC_INIT = 1,
//  FLR_SEL_FMAP = 2,     
//  FLR_PER_Q_INIT = 3,
//  FLR_IND_STATUS_RD = 4, 
//  FLR_IND_STATUS_CPL = 5, 
//  FLR_CTXT_SEL_DSC_SW_H2C = 6,
//  FLR_CTXT_SEL_DSC_HW_H2C = 7,
//  FLR_CTXT_SEL_DSC_CR_H2C = 8,
//  FLR_CTXT_SEL_DSC_SW_C2H = 9,
//  FLR_CTXT_SEL_PFTCH = 10,
//  FLR_CTXT_SEL_DSC_HW_C2H = 11,
//  FLR_CTXT_SEL_DSC_CR_C2H = 12,
//  FLR_CTXT_SEL_WRB = 13,
//  FLR_CTXT_SEL_INT_COAL = 14,
//  FLR_C2H_QID2VEC_MAP_QID = 15,
//  FLR_C2H_QID2VEC_MAP = 16,
//  FLR_INTR_IND_CTXT_DATA = 17,
//  FLR_PER_FUNC_DONE = 18,
//  FLR_DONE = 19     
//} flr_state_t;
//logic [11:0] qid;
//logic [1:0]  flr_req_pf;          // PF number of the targeted VF
//logic [1:0]  flr_req_pf_reg;          // PF number of the targeted VF
//reg [10:0]   qid_base;
//reg [10:0]   qid_base_reg;
//reg [11:0]   q_count;
//reg [11:0]   q_count_reg;
//reg [11:0]   q_index_reg;
//reg [11:0]   q_index;
//reg [7:0]    vf_index_reg;
//reg [7:0]    vf_index;
//reg          vf_flr_done_reg;
//reg          vf_flr_done;
//reg          pf_flr_done_reg;
//reg          pf_flr_started;
//reg          pf_flr_started_reg;
//reg          pf_flr_done;
//reg          ind_ctxt_busy; // 1: Busy; 0: DONE
//reg          ind_ctxt_busy_reg; // 1: Busy; 0: DONE
//reg          rd_wr_sel;     // 0: RD: 1: WR
//reg          rd_wr_sel_reg;     // 0: RD: 1: WR
//logic [4:0]  ind_ctxt_sel;
//logic [4:0]  ind_ctxt_sel_reg;
//logic [1:0]  ind_ctxt_cmd;
//logic [1:0]  ind_ctxt_cmd_reg;
//flr_state_t  flr_cur_state;
//flr_state_t  flr_nxt_state;
//logic        mgmt_rd_pnd_reg;
//logic        mgmt_rd_pnd;
//logic [1:0]  mgmt_req_cmd_o;
//logic [7:0]  mgmt_req_fnc_o;
//logic [31:0] mgmt_req_adr_o;
//logic [6:0]  mgmt_req_msc_o;
//logic [31:0] mgmt_req_dat_o;
//logic        mgmt_req_vld_o;
//logic        mgmt_cpl_rdy_o;
//logic [255:0] pre_flr_done_o;
//logic         usr_flr_in_vld_o;
//logic         usr_flr_in_vld_o_reg;
//logic [7:0]   usr_flr_in_fnc_o;
//reg            usr_flr_set_o;
//reg            usr_flr_set_reg;
//reg            usr_flr_set_reg_reg;
//reg    [7:0]   usr_flr_fnc_o;
//reg    [7:0]   usr_flr_fnc_reg;
//reg            usr_flr_done_vld_reg; // capture and convert each usr_flr_done_vld pulse to level
//reg            usr_flr_init; // User FLR has been initiated
//reg            usr_flr_init_reg; 
//reg            mb_flr_set_o; // Outbound signal to kick of FLR in mailbox
//reg            mb_flr_set_reg;
//reg            mb_flr_set_reg_reg;
//reg            mb_flr_done_vld_reg; // capture and convert each usr_flr_done_vld pulse to level
//reg            mb_flr_init; // User FLR can be initiated to mailbox; Internal signal
//reg            mb_flr_init_reg; 
//reg    [7:0]   mb_flr_fnc_o;
//reg    [7:0]   mb_flr_fnc_reg;

//assign qid = qid_base_reg + q_index - 1'b1;
 
//// There is only one state machine for all functions.
//// Procedure of clearing Context Register
////    1) Assign initial ind_ctxt_sel to FMAP
////    2) Check status of ind reg
////    3) If ind reg is not busy, jump to invalidate the selected ctx.
////    4) Perform invalidation; Assign ind_ctxt_sel to next state; Jump to (2)
//always @ (*) 
//begin
//  flr_nxt_state = flr_cur_state;
//  case (flr_cur_state)
//    // Waiting to initiate PER-FLR
//    FLR_IDLE                       : if (flr_start)  flr_nxt_state = FLR_PER_FUNC_INIT;
//                                     else            flr_nxt_state = flr_cur_state;
//    // Select a function and initiate FLR for both QDMA and logic of user function
//    //   For PF, we will do FLR iteratively to all it VFs first. Then perform FLR to PF itself.
//    //   When both VF and PF FLR completes, go to FLR_IDLE to terminate FLR
//    FLR_PER_FUNC_INIT :
//      if (pf_flr_done_reg && vf_flr_done_reg)   flr_nxt_state = FLR_DONE;
//      else                                      flr_nxt_state = FLR_SEL_FMAP; 
//    FLR_SEL_FMAP :  
//      if (~rd_wr_sel_reg && mgmt_rd_pnd_reg && mgmt_cpl_vld)  flr_nxt_state = FLR_PER_Q_INIT; 
//      else if (rd_wr_sel_reg && mgmt_req_rdy)                 flr_nxt_state = FLR_PER_FUNC_DONE;
//      else                                                    flr_nxt_state = flr_cur_state;
//    FLR_PER_Q_INIT :
//      if (q_count_reg == 0 || (q_index_reg == q_count_reg)) flr_nxt_state = FLR_SEL_FMAP; // Destroy FMAP
//      else                                   flr_nxt_state = FLR_IND_STATUS_RD;
//    FLR_IND_STATUS_RD : 
//      if (mgmt_rd_pnd_reg && mgmt_cpl_vld) flr_nxt_state = FLR_IND_STATUS_CPL;
//      else                                 flr_nxt_state = flr_cur_state;
//    FLR_IND_STATUS_CPL : 
//      if (~ind_ctxt_busy_reg) begin
//        case (ind_ctxt_sel_reg)
//          MDMA_CTXT_SEL_DSC_SW_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_SW_H2C;
//          MDMA_CTXT_SEL_DSC_HW_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_HW_H2C;
//          MDMA_CTXT_SEL_DSC_CR_H2C : flr_nxt_state = FLR_CTXT_SEL_DSC_CR_H2C;
//          MDMA_CTXT_SEL_DSC_SW_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_SW_C2H;
//          MDMA_CTXT_SEL_PFTCH      : flr_nxt_state = FLR_CTXT_SEL_PFTCH;
//          MDMA_CTXT_SEL_DSC_HW_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_HW_C2H;
//          MDMA_CTXT_SEL_DSC_CR_C2H : flr_nxt_state = FLR_CTXT_SEL_DSC_CR_C2H;
//          MDMA_CTXT_SEL_WRB        : flr_nxt_state = FLR_CTXT_SEL_WRB;
//          MDMA_CTXT_SEL_INT_COAL   : flr_nxt_state = FLR_CTXT_SEL_INT_COAL;
//          default                  : flr_nxt_state = flr_cur_state;
//        endcase
//      end
//      else flr_nxt_state = FLR_IND_STATUS_RD;
//    FLR_CTXT_SEL_DSC_SW_H2C, FLR_CTXT_SEL_DSC_HW_H2C, FLR_CTXT_SEL_DSC_CR_H2C, 
//    FLR_CTXT_SEL_DSC_SW_C2H, FLR_CTXT_SEL_DSC_HW_C2H, FLR_CTXT_SEL_DSC_CR_C2H, 
//    FLR_CTXT_SEL_PFTCH, FLR_CTXT_SEL_WRB :
//      if (mgmt_req_rdy) flr_nxt_state = FLR_IND_STATUS_RD; 
//      else              flr_nxt_state = flr_cur_state;
//    FLR_CTXT_SEL_INT_COAL : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_C2H_QID2VEC_MAP_QID; 
//      else              flr_nxt_state = flr_cur_state;
//    FLR_C2H_QID2VEC_MAP_QID : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_C2H_QID2VEC_MAP; 
//      else              flr_nxt_state = flr_cur_state;
//    FLR_C2H_QID2VEC_MAP : 
//      if (mgmt_req_rdy) flr_nxt_state = FLR_PER_Q_INIT;
//      else              flr_nxt_state = flr_cur_state;
//    FLR_PER_FUNC_DONE : 
//      flr_nxt_state = FLR_PER_FUNC_INIT;
//    FLR_DONE : 
//      // Wait until FLR in usr logic and mailbox complete
//      if ((usr_flr_set_reg && usr_flr_done_vld_reg) && (mb_flr_set_reg && mb_flr_done_vld_reg)) flr_nxt_state = FLR_IDLE;  
//      else                                                                                      flr_nxt_state = flr_cur_state;
//    default: flr_nxt_state = flr_cur_state;
//  endcase
//end

//always_ff @ (posedge user_clk) 
//  if (reset) flr_cur_state <= FLR_IDLE;
//  else       flr_cur_state <= flr_nxt_state;

//always_comb
//begin 
//    flr_req_pf          = flr_req_pf_reg;
//    qid_base            = qid_base_reg;
//    q_count             = q_count_reg;
//    q_index             = q_index_reg;
//    rd_wr_sel           = rd_wr_sel_reg; 
//    mgmt_req_cmd_o      = 'h0;
//    mgmt_req_fnc_o      = 'h0;
//    mgmt_req_adr_o      = 'h0;
//    mgmt_req_dat_o      = 'h0;
//    mgmt_req_msc_o      = 'h0;
//    mgmt_req_vld_o      = 'h0;
//    mgmt_cpl_rdy_o      = 'h1;
//    ind_ctxt_sel        = ind_ctxt_sel_reg;
//    ind_ctxt_cmd        = ind_ctxt_cmd_reg;
//    ind_ctxt_busy       = ind_ctxt_busy_reg;
//    vf_index            = vf_index_reg;
//    usr_flr_init        = usr_flr_init_reg;
//    pf_flr_started      = pf_flr_started_reg;
//    pre_flr_done_o      = pre_flr_done;
//    pf_flr_done         = pf_flr_done_reg;
//    vf_flr_done         = vf_flr_done_reg;
//    flr_done            = flr_done_reg;
//    flr_req_fn          = flr_req_fn_reg;
//    usr_flr_in_fnc_o    = usr_flr_in.fnc;
//    usr_flr_in_vld_o    = usr_flr_in_vld_o_reg;
//    usr_flr_set_o       = usr_flr_set_reg;
//    usr_flr_fnc_o       = usr_flr_fnc_reg;
//    mb_flr_init         = mb_flr_init_reg;
//    mb_flr_set_o        = mb_flr_set_reg;
//    mb_flr_fnc_o        = mb_flr_fnc_reg;
//    mgmt_rd_pnd         = mgmt_rd_pnd_reg;
//  case (flr_cur_state)
//  FLR_IDLE: begin
//    flr_req_pf          = flr_req_pf_reg;
//    qid_base            = qid_base_reg;
//    q_count             = q_count_reg;
//    q_index             = q_index_reg;
//    rd_wr_sel           = rd_wr_sel_reg; 
//    mgmt_req_cmd_o      = 'h0;
//    mgmt_req_fnc_o      = 'h0;
//    mgmt_req_adr_o      = 'h0;
//    mgmt_req_vld_o      = 'h0;
//    mgmt_req_dat_o      = 'h0;
//    mgmt_req_msc_o      = 'h0;
//    mgmt_cpl_rdy_o      = 1'b1;
//    ind_ctxt_sel        = ind_ctxt_sel_reg;
//    ind_ctxt_cmd        = ind_ctxt_cmd_reg;
//    vf_index            = vf_index_reg;
//    usr_flr_init        = usr_flr_init_reg;
//    flr_req_fn          = flr_req_fn_reg;
//    usr_flr_in_fnc_o    = usr_flr_in.fnc;
//    usr_flr_in_vld_o    = 1'b0;
//    pf_flr_started      = 1'b1;
//    pf_flr_done         = 1'b0;
//    vf_flr_done         = 1'b0;
//    pre_flr_done_o      = 'h0; 
//    flr_done            = 1'b1;
//    usr_flr_set_o       = usr_flr_set_reg;
//    usr_flr_fnc_o       = usr_flr_fnc_reg;
//    mb_flr_init         = mb_flr_init_reg;
//    mb_flr_set_o        = mb_flr_set_reg;
//    mb_flr_fnc_o        = mb_flr_fnc_reg;
//    mgmt_rd_pnd         = mgmt_rd_pnd_reg;
//    ind_ctxt_busy       = ind_ctxt_busy_reg;
//  end
//  FLR_PER_FUNC_INIT: begin
//    flr_req_pf       = req_pf_reg;
//    q_index          = 'h0; // start from the first Q 
//    rd_wr_sel        = 'h0; 
//    mgmt_req_vld_o   = 'h0;
//    mgmt_rd_pnd      = 'b0;
//    pre_flr_done_o [flr_req_fn_reg] = 1'b0; // generate a one-cycle pulse
//    flr_done         = 'b0;
//    // Kick off mailbox FLR
//    mb_flr_init      = 'b1;
//    mb_flr_set_o     = 1'b1;  // kick off mailbox FLR
//    mb_flr_fnc_o     = req_pf_reg;   
//    // Kick off user FLR
//    usr_flr_init     = 'b1;
//    usr_flr_set_o    = 1'b1;  
//    usr_flr_fnc_o  = req_pf_reg;
//    // FLR is from PF and pick a VF
//    if (flr_is_pf && ~vf_flr_done_reg && ~pf_flr_done_reg) begin
//      flr_req_fn     = attr_dma_pf[req_pf_reg].firstvf_offset + vf_index_reg;
//      if (vf_index_reg < attr_dma_pf[req_pf_reg].num_vfs)
//        vf_index     = vf_index_reg + 1'b1; 
//      else
//        vf_index     = 'h0; 
//    end
//    // Do FLR to PF itself
//    else if (flr_is_pf && vf_flr_done_reg && ~pf_flr_done_reg) begin
//      pf_flr_started = 1'b1;
//      flr_req_fn     = req_pf_reg;
//    end
//    // Do FLR to VF
//    else if (~flr_is_pf && (~vf_flr_done_reg)) begin
//      flr_req_fn     = req_fn_reg;
//    end
//    else begin
//      flr_req_fn     = flr_req_fn_reg;
//    end
//  end
//  FLR_SEL_FMAP: begin        
//    // use flr_req_pf_reg to access FMAP
//    if ((rd_wr_sel_reg == 1'b0) && ~mgmt_rd_pnd_reg) begin
//      mgmt_req_cmd_o  = rd_wr_sel_reg;
//      mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;  // Must use pfn of the targeted VF
//      mgmt_req_adr_o  = MDMA_CMN_FMAP_START_A+flr_req_fn_reg*4;  
//      mgmt_req_vld_o  = 1'b1;
//      if (mgmt_req_rdy)
//        mgmt_rd_pnd   = 1'b1;
//      else
//        mgmt_rd_pnd   = 1'b0;
//    end
//    // find out queues owned by this function  
//    else if ((rd_wr_sel_reg == 1'b0) && mgmt_rd_pnd_reg) begin
//      mgmt_req_vld_o  = 1'b0;
//      if (mgmt_cpl_vld) begin
//        qid_base      = mgmt_cpl.dat[10:0];
//        q_count       = mgmt_cpl.dat[22:11];
//        mgmt_rd_pnd = 1'b0;
//        ind_ctxt_cmd  = FLR_CTXT_IND_CMD;
//        ind_ctxt_sel  = MDMA_CTXT_SEL_DSC_SW_H2C; 
//      end
//      else begin
//        qid_base      = qid_base_reg;
//        q_count       = q_count_reg;
//        mgmt_rd_pnd   = mgmt_rd_pnd_reg;
//        ind_ctxt_cmd  = ind_ctxt_cmd_reg;
//        ind_ctxt_sel  = ind_ctxt_sel_reg;
//      end
//    end
//    // Destroy the Q associated with this function
//    // This is the last step of FLR for each function
//    else if (rd_wr_sel_reg == 1'b1)begin
//      mgmt_req_cmd_o  = rd_wr_sel_reg;
//      mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//      mgmt_req_adr_o  = MDMA_CMN_FMAP_START_A+flr_req_fn_reg*4;  
//      mgmt_req_dat_o  = 'h0;
//      mgmt_req_vld_o  = 1'b1;
//    end
//    else begin
//      mgmt_req_cmd_o  = 'h0;
//      mgmt_req_fnc_o  = 'h0;
//      mgmt_req_adr_o  = 'h0;  
//      mgmt_req_dat_o  = 'h0;
//      mgmt_req_vld_o  = 'h0;
//    end
//  end
//  FLR_PER_Q_INIT: begin
//    mgmt_req_vld_o  = 1'b0; // Must deassert the request
//    if (q_count_reg == 0) begin
//      q_index = 'h0;
//      rd_wr_sel = 'h1;
//    end
//    else if (q_index_reg < q_count_reg - 1'b1) begin
//      q_index  = q_index_reg + 1'b1;
//      ind_ctxt_cmd = FLR_CTXT_IND_CMD;
//      ind_ctxt_sel = MDMA_CTXT_SEL_DSC_SW_H2C;
//      rd_wr_sel    = 1'b0;
//    end
//    else if (q_index_reg == q_count_reg - 1'b1) begin
//      q_index  = q_index_reg + 1'b1;
//      ind_ctxt_cmd = FLR_CTXT_IND_CMD;
//      ind_ctxt_sel = MDMA_CTXT_SEL_DSC_SW_H2C;
//      rd_wr_sel    = 1'b1;
//    end
//    else begin
//      rd_wr_sel    = 1'b1; // This will change state to FLR_SEL_FMAP to destoy FMAP
//      q_index  = q_index_reg;
//      ind_ctxt_cmd = ind_ctxt_cmd_reg;
//      ind_ctxt_sel = ind_ctxt_sel_reg;
//    end
//  end
//  FLR_IND_STATUS_RD: begin
//    // Check if ctxt is busy
//    if (~mgmt_rd_pnd_reg) begin
//      mgmt_req_vld_o = 1'b1;
//      mgmt_req_fnc_o = flr_req_pf_reg | 8'h0;
//      mgmt_req_cmd_o = 1'b0;
//      mgmt_req_adr_o = MDMA_IND_CTXT_CMD_A;  
//      ind_ctxt_busy  = 1'b1;
//      if (mgmt_req_rdy)
//        mgmt_rd_pnd = 1'b1;
//      else
//        mgmt_rd_pnd = 1'b0; 
//    end
//    else begin
//      mgmt_req_vld_o  = 1'b0;
//      if (mgmt_cpl_vld) begin
//        ind_ctxt_busy = mgmt_cpl.dat[0];
//        mgmt_rd_pnd   = 1'b0;
//      end
//      else begin
//        ind_ctxt_busy = 1'b1;
//        mgmt_rd_pnd = mgmt_rd_pnd_reg; 
//      end
//    end
//  end
//  FLR_IND_STATUS_CPL : begin
//    // only state change
//  end
//  FLR_CTXT_SEL_DSC_SW_H2C: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A;
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_SW_H2C, 1'b1};   
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD; 
//    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_HW_H2C; 
//  end
//  FLR_CTXT_SEL_DSC_HW_H2C: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_HW_H2C, 1'b1};  
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_CR_H2C;   
//  end
//  FLR_CTXT_SEL_DSC_CR_H2C: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_CR_H2C, 1'b1}; 
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_SW_C2H;  
//  end
//  FLR_CTXT_SEL_DSC_SW_C2H: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_SW_C2H, 1'b1};  
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_PFTCH;  
//  end
//  FLR_CTXT_SEL_PFTCH: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_PFTCH, 1'b1};  
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_HW_C2H;  
//  end
//  FLR_CTXT_SEL_DSC_HW_C2H: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_HW_C2H, 1'b1};  
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_DSC_CR_C2H;  
//  end
//  FLR_CTXT_SEL_DSC_CR_C2H: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_DSC_CR_C2H, 1'b1};  
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_WRB;  
//  end
//  FLR_CTXT_SEL_WRB: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A; 
//    mgmt_req_dat_o  = 'h0 | {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_WRB, 1'b1}; 
//    mgmt_req_vld_o  = 1'b1;
//    // Set command and select ctxt for the next state
//    ind_ctxt_cmd    = FLR_CTXT_IND_CMD;
//    ind_ctxt_sel    = MDMA_CTXT_SEL_INT_COAL;  
//  end
//  FLR_CTXT_SEL_INT_COAL: begin
//    // ind_ctxt_cmd is set in FLR_C2H_QID2VEC_MAP
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_IND_CTXT_CMD_A;
//    mgmt_req_dat_o  = {qid, ind_ctxt_cmd_reg, MDMA_CTXT_SEL_INT_COAL, 1'b1} | 'h0;  
//    mgmt_req_vld_o  = 1'b1;
//  end
//  FLR_C2H_QID2VEC_MAP_QID: begin
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_C2H_QID2VEC_MAP_QID;
//    mgmt_req_dat_o  = 'h0 | qid; 
//    mgmt_req_vld_o  = 1'b1;
//  end
//  FLR_C2H_QID2VEC_MAP: begin
//    // Clear the QID2VEC mapping
//    mgmt_req_cmd_o  = 1'b1;
//    mgmt_req_fnc_o  = flr_req_pf_reg | 8'h0;
//    mgmt_req_adr_o  = MDMA_C2H_QID2VEC_MAP;  
//    mgmt_req_dat_o  = 'h0;
//    mgmt_req_vld_o  = 1'b1;
//  end
//  FLR_PER_FUNC_DONE: begin
//    // set the state to idle for this function
//    pre_flr_done_o [flr_req_fn_reg] = 1'b1;
//    mgmt_req_vld_o  = 1'b0; // generate only a one-cycle pulse
//    if (flr_is_pf && ~vf_flr_done_reg) begin
//      if (vf_index_reg == attr_dma_pf[req_pf_reg].num_vfs)
//        vf_flr_done = 1'b1;
//      else
//        vf_flr_done = 1'b0;
//    end
//    else if (flr_is_pf && pf_flr_started) begin
//      pf_flr_done    = 1'b1;
//      pf_flr_started = 1'b0;
//    end
//    else if (~flr_is_pf && ~vf_flr_done_reg) begin
//      pf_flr_done = 1'b1;  // MUST assert both pf_flr_done and vf_flr_done
//      vf_flr_done = 1'b1;
//    end
//    else begin
//      pf_flr_done = 1'b0;
//      vf_flr_done = 1'b0;
//    end
//  end
//  FLR_DONE: begin
//    usr_flr_in_fnc_o = flr_req_fn_reg;

//    // Wait for completion of FLR done in both mailbox and user logic
//    if ((usr_flr_set_reg && usr_flr_done_vld_reg) && (mb_flr_set_reg && mb_flr_done_vld_reg)) begin
//      usr_flr_init  = 'b0;
//      mb_flr_init   = 'b0;
//      usr_flr_in_vld_o = 1'b1;
//    end
//    else begin
//      usr_flr_init  = usr_flr_init_reg;
//      mb_flr_init   = mb_flr_init_reg; 
//      usr_flr_in_vld_o = 1'b0;
//    end
//  end
//  default: begin
//    flr_req_pf          = flr_req_pf_reg;
//    qid_base            = qid_base_reg;
//    q_count             = q_count_reg;
//    q_index             = q_index_reg;
//    rd_wr_sel           = rd_wr_sel_reg; 
//    mgmt_req_cmd_o      = 'h0;
//    mgmt_req_fnc_o      = 'h0;
//    mgmt_req_adr_o      = 'h0;
//    mgmt_req_dat_o      = 'h0;
//    mgmt_req_msc_o      = 'h0;
//    mgmt_req_vld_o      = 'h0;
//    mgmt_cpl_rdy_o      = 1'b1;
//    ind_ctxt_sel        = ind_ctxt_sel_reg;
//    ind_ctxt_cmd        = ind_ctxt_cmd_reg;
//    ind_ctxt_busy       = ind_ctxt_busy_reg;
//    vf_index            = vf_index_reg;
//    usr_flr_init        = usr_flr_init_reg;
//    pf_flr_started      = pf_flr_started_reg;
//    flr_done            = flr_done_reg;
//    pre_flr_done_o      = pre_flr_done;
//    pf_flr_done         = pf_flr_done_reg;
//    vf_flr_done         = vf_flr_done_reg;
//    flr_req_fn          = flr_req_fn_reg;
//    usr_flr_in_fnc_o    = usr_flr_in.fnc;
//    usr_flr_in_vld_o    = usr_flr_in_vld_o_reg;
//    usr_flr_set_o       = usr_flr_set_reg;
//    usr_flr_fnc_o       = usr_flr_fnc_reg;
//    mb_flr_init         = mb_flr_init_reg;
//    mb_flr_set_o        = mb_flr_set_reg;
//    mb_flr_fnc_o        = mb_flr_fnc_reg;
//    mgmt_rd_pnd         = mgmt_rd_pnd_reg;
//  end
//  endcase
//end


///************************************************
//* Generate FLR to user logic
//*************************************************/
//// Generate a one-cycle pulse usr_flr_set to kick off FLR in user logic
//// User should reply usr_flr_done_vld when finish

//always_ff @ (posedge user_clk) begin
//  if (reset) begin
//    usr_flr_set_reg       <= 'b0;
//    usr_flr_done_vld_reg  <= 'b0;
//  end
//  else begin
//    if (~usr_flr_set_reg)
//      usr_flr_set_reg       <= usr_flr_set_o;
//    else
//      usr_flr_set_reg       <= ~(usr_flr_done_vld_reg && flr_done); // 1'b0: an iteration finish; Cleared when both ack come back and all DMA Pre-FLR completes for this function
//    if (usr_flr_init_reg)
//      usr_flr_done_vld_reg  <= usr_flr_done_vld_reg ? 1'b1 : (usr_flr_done_vld && (usr_flr_done_fnc == usr_flr_fnc_reg)); // retain usr_flr_done_vld HIGH 
//    else
//      usr_flr_done_vld_reg  <= 'b0;
//  end
//end
//assign usr_flr_set = usr_flr_set_reg & ~usr_flr_set_reg_reg; // generate a one-cycle pulse to user logic 
//assign usr_flr_fnc = usr_flr_set_reg ? usr_flr_fnc_reg : 'h0; 
//assign usr_flr_clr = flr_done && ~flr_done_reg;


///************************************************
//* Generate FLR to mailbox
//*************************************************/
//// Generate a one-cycle pulse usr_flr_set to kick off FLR in user logic
//// User should reply usr_flr_done_vld when finish

//always_ff @ (posedge user_clk) begin
//  if (reset) begin
//    mb_flr_done_vld_reg  <= 'b0;
//    mb_flr_set_reg       <= 'b0;
//  end
//  else begin
//    if (~mb_flr_set_reg) begin
//      mb_flr_set_reg <= mb_flr_set_o;
//    end
//    else begin
//      mb_flr_set_reg <= ~(mb_flr_done_vld_reg && flr_done);
//    end

//    if (mb_flr_init_reg) begin // Must remain high for the duration of Pre-FLR
//      mb_flr_done_vld_reg <= mb_flr_done_vld_reg ? 1'b1 : mb_flr_done_vld; // retain mb_flr_done_vld HIGH 
//    end
//    else begin
//      mb_flr_done_vld_reg <= 'b0;
//    end
//  end
//end
//assign mb_flr_set = mb_flr_set_reg & ~mb_flr_set_reg_reg; // generate a one-cycle pulse to user logic 
//assign mb_flr_fnc = mb_flr_set_reg ? mb_flr_fnc_reg : 'h0; 


//always_ff @ (posedge user_clk) 
//begin
//  if (reset) begin
//    flr_req_pf_reg    <= 'h0;
//    mgmt_rd_pnd_reg   <= 1'b0;
//    q_index_reg       <= 'h0;
//    pf_flr_started_reg<= 'b0;
//    pf_flr_done_reg   <= 1'b0;
//    vf_flr_done_reg   <= 1'b0;
//    vf_index_reg      <= 'h0;
//    qid_base_reg      <= 'h0;
//    q_count_reg       <= 'h0;
//    rd_wr_sel_reg     <= 'h0;
//    ind_ctxt_sel_reg  <= 'h0;
//    ind_ctxt_cmd_reg  <= 'h0;
//    usr_flr_init_reg  <= 'h0;
//    mb_flr_init_reg   <= 'h0;
//    flr_done_reg      <= 'h1;
//    flr_req_fn_reg    <= 'h0;
//    ind_ctxt_busy_reg <= 'h1;
//    mb_flr_set_reg_reg    <= 'b0;
//    usr_flr_set_reg_reg   <= 'b0;
//    pre_flr_done    <= 'h0;
//    usr_flr_in.fnc  <= 'h0;
//    usr_flr_fnc_reg <= 'h0;
//    mb_flr_fnc_reg  <= 'h0;
//    usr_flr_in_vld_o_reg <= 'h0;
//  end
//  else begin
//    flr_req_pf_reg    <= flr_req_pf;
//    mgmt_rd_pnd_reg   <= mgmt_rd_pnd;
//    q_index_reg       <= q_index;
//    pf_flr_started_reg<= pf_flr_started;
//    pf_flr_done_reg   <= pf_flr_done; 
//    vf_flr_done_reg   <= vf_flr_done; 
//    vf_index_reg      <= vf_index;
//    qid_base_reg      <= qid_base;
//    q_count_reg       <= q_count;
//    rd_wr_sel_reg     <= rd_wr_sel;
//    ind_ctxt_sel_reg  <= ind_ctxt_sel;
//    ind_ctxt_cmd_reg  <= ind_ctxt_cmd;
//    usr_flr_init_reg  <= usr_flr_init;
//    mb_flr_init_reg   <= mb_flr_init;
//    flr_done_reg      <= flr_done;
//    flr_req_fn_reg    <= flr_req_fn;
//    ind_ctxt_busy_reg <= ind_ctxt_busy;
//    mb_flr_set_reg_reg    <= mb_flr_set_reg;
//    usr_flr_set_reg_reg   <= usr_flr_set_reg;
//    pre_flr_done    <= pre_flr_done_o;
//    usr_flr_in.fnc  <= usr_flr_in_fnc_o;
//    usr_flr_fnc_reg <= usr_flr_fnc_o;
//    mb_flr_fnc_reg  <= mb_flr_fnc_o;
//    usr_flr_in_vld_o_reg <= usr_flr_in_vld_o;
//  end
//end

assign    usr_flr_in.vld  = usr_flr_in_vld_o && ~usr_flr_in_vld_o_reg; // One-cycle pulse to flr_cntl
assign    mgmt_req.cmd    = mgmt_req_cmd_o;
assign    mgmt_req.adr    = mgmt_req_adr_o;
assign    mgmt_req.msc    = mgmt_req_msc_o;
assign    mgmt_req.dat    = mgmt_req_dat_o;
assign    mgmt_req.fnc    = mgmt_req_fnc_o;
assign    mgmt_req_vld    = mgmt_req_vld_o;
assign    mgmt_cpl_rdy    = mgmt_cpl_rdy_o;

endmodule
`endif

`timescale 1ns/1ps

  module qdma_v2_0_1_GenericFIFO
    #(parameter BUF_DATAWIDTH = 256,
      parameter BUF_WE = BUF_DATAWIDTH/8,
      parameter BUF_DEPTH = 512,
      parameter BUF_PTR = (BUF_DEPTH <=2) ? 1:
                           (BUF_DEPTH <=4)    ? 2:
                           (BUF_DEPTH <=8)    ? 3:
                           (BUF_DEPTH <=16)   ? 4:
                           (BUF_DEPTH <=32)   ? 5:
                           (BUF_DEPTH <=64)   ? 6:
                           (BUF_DEPTH <=128)   ? 7:
                           (BUF_DEPTH <=256)   ? 8:
                           (BUF_DEPTH <=512)   ? 9:
                   (BUF_DEPTH <=1024)   ? 10 : -1,
      parameter AE_THRESHOLD = BUF_DEPTH >> 2,
      parameter AF_THRESHOLD = BUF_DEPTH - 2
    )
    (
        input clkin,
    input reset_n,
    input sync_reset_n,
        input [BUF_DATAWIDTH-1:0] DataIn,
        output [BUF_DATAWIDTH-1:0] DataOut,
    input WrEn,
    input RdEn,
    output almost_empty,
    output almost_full,
    output empty,
    output full
   );
(* ram_style = "DISTRIBUTED" *)
   reg [BUF_DATAWIDTH-1:0] MemArray [BUF_DEPTH-1:0];
   reg [BUF_PTR-1:0] WrPtr;
   reg [BUF_PTR-1:0] RdPtr;
   reg [BUF_PTR:0] FifoCntrWr;
   reg [BUF_PTR:0] FifoCntrRd;
   wire WriteQ, RdDeQ;
   reg almost_empty_ff;
   reg almost_full_ff;
   reg empty_ff;
   reg full_ff;
   assign WriteQ = WrEn;
   assign RdDeQ = RdEn;
   assign DataOut = MemArray[RdPtr];
   assign almost_empty = almost_empty_ff;
   assign almost_full = almost_full_ff;
   assign empty = empty_ff;
   assign full = full_ff;
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
         WrPtr <= 'd0;
    else if  (~sync_reset_n || ((WrPtr == (BUF_DEPTH-1)) && WrEn))
         WrPtr <= 'd0;
        else if (WrEn) begin
        WrPtr <= WrPtr + 'd1;
        end
    end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n) 
         RdPtr <= 'd0;
        else if  (~sync_reset_n || ((RdPtr == (BUF_DEPTH-1)) && RdEn))
         RdPtr <= 'd0;
        else if (RdEn) begin
        RdPtr <= RdPtr + 'd1;
        end
    end

`ifdef SOFT_IP
     always @ (posedge clkin) begin
        if (WrEn)
            MemArray[WrPtr] <= DataIn;
    end
`else
    //always @ (posedge clkin) begin
    `XLREG_HARD(clkin, reset_n)
    for (int i = 0; i < BUF_DEPTH; i = i+1)
        MemArray[i] <= 'h0;
    `XLREG_END
    begin
        if (WrEn)
            MemArray[WrPtr] <= DataIn;
    end
`endif



   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
         FifoCntrWr <= 'd0;
        else if (~sync_reset_n) 
         FifoCntrWr <= 'd0;
        else if ((WrEn & RdDeQ) | (~WrEn & ~RdDeQ))begin
        FifoCntrWr <= FifoCntrWr;
        end
    else if (WrEn) begin
        FifoCntrWr <= FifoCntrWr +'d1;
    end
        else begin
        FifoCntrWr <= FifoCntrWr -'d1;
    end
    end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n) 
         FifoCntrRd <= 'd0;
        else if (~sync_reset_n) 
         FifoCntrRd <= 'd0;
        else if ((RdEn & WriteQ) | (~RdEn & ~WriteQ)) begin
        FifoCntrRd <= FifoCntrRd;
        end
    else if (WriteQ) begin
        FifoCntrRd <= FifoCntrRd +'d1;
    end
        else begin
        FifoCntrRd <= FifoCntrRd -'d1;
    end
    end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
        empty_ff <= 1'b1;
        else if (~sync_reset_n)
        empty_ff <= 1'b1;
    else if((FifoCntrRd==0) || ((FifoCntrRd==1) && RdEn))
        empty_ff <= 1'b1;
    else if(FifoCntrRd>0)
        empty_ff <= 1'b0;
   end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
        almost_empty_ff <= 1'b1;
        else if (~sync_reset_n)
        almost_empty_ff <= 1'b1;
    else if(FifoCntrRd>(AE_THRESHOLD))
        almost_empty_ff <= 1'b0;
    else if(FifoCntrRd<=(AE_THRESHOLD))
        almost_empty_ff <= 1'b1;
   end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
        full_ff <= 1'b0;
        else if (~sync_reset_n)
        full_ff <= 1'b0;
    else if((FifoCntrWr==(BUF_DEPTH)) || ((FifoCntrWr==(BUF_DEPTH-1)) && WriteQ))
        full_ff <= 1'b1;
    else if(FifoCntrWr<BUF_DEPTH)
        full_ff <= 1'b0;
   end
   `XLREG_XDMA(clkin, reset_n) begin
        if (~reset_n)
        almost_full_ff <= 1'b0;
        else if (~sync_reset_n)
        almost_full_ff <= 1'b0;
    else if(FifoCntrWr>(AF_THRESHOLD))
        almost_full_ff <= 1'b1;
    else if(FifoCntrWr<=(AF_THRESHOLD)) 
        almost_full_ff <= 1'b0;
   end
   endmodule