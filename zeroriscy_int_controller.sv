////////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2017 ETH Zurich, University of Bologna                       //
// All rights reserved.                                                       //
//                                                                            //
// This code is under development and not yet released to the public.         //
// Until it is released, the code is under the copyright of ETH Zurich        //
// and the University of Bologna, and may contain unpublished work.           //
// Any reuse/redistribution should only be under explicit permission.         //
//                                                                            //
// Bug fixes and contributions will eventually be released under the          //
// SolderPad open hardware license and under the copyright of ETH Zurich      //
// and the University of Bologna.                                             //
//                                                                            //
// Engineer:       Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                                                                            //
// Additional contributions by:                                               //
//                                                                            //
// Design Name:    Interrupt Controller                                       //
// Project Name:   zero-riscy                                                 //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Interrupt Controller of the pipelined processor            //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

import zeroriscy_defines::*;

module zeroriscy_int_controller
(
  input  logic        clk,
  input  logic        rst_n,

  // irq_req for controller
  output logic        irq_req_ctrl_o,
  output logic  [4:0] irq_id_ctrl_o,

  // handshake signals to controller
  input  logic        ctrl_ack_i,
  input  logic        ctrl_kill_i,

  // external interrupt lines
  input  logic        irq_i,          // level-triggered interrupt inputs
  input  logic  [4:0] irq_id_i,       // interrupt id [0,1,....31]

  input  logic        m_IE_i          // interrupt enable bit from CSR (M mode)
);

  enum logic [1:0] { IDLE, IRQ_PENDING, IRQ_DONE} exc_ctrl_cs;

  logic irq_enable_ext;
  logic [4:0] irq_id_q;

  assign irq_enable_ext =  m_IE_i;
  assign irq_req_ctrl_o = exc_ctrl_cs == IRQ_PENDING;
  assign irq_id_ctrl_o  = irq_id_q;

  always_ff @(posedge clk, negedge rst_n)
  begin
    if (rst_n == 1'b0) begin

      irq_id_q    <= '0;
      exc_ctrl_cs <= IDLE;

    end else begin

      unique case (exc_ctrl_cs)

        IDLE:
        begin
          if(irq_enable_ext & irq_i) begin
            exc_ctrl_cs <= IRQ_PENDING;
            irq_id_q    <= irq_id_i;
          end
        end

        IRQ_PENDING:
        begin
          unique case(1'b1)
            ctrl_ack_i:
              exc_ctrl_cs <= IRQ_DONE;
            ctrl_kill_i:
              exc_ctrl_cs <= IDLE;
            default:
              exc_ctrl_cs <= IRQ_PENDING;
          endcase
        end

        IRQ_DONE:
        begin
          exc_ctrl_cs <= IDLE;
        end

      endcase

    end
  end

`ifndef SYNTHESIS
  // synopsys translate_off
  // evaluate at falling edge to avoid duplicates during glitches
  // Removed this message as it pollutes too much the output and makes tests fail
  //always_ff @(negedge clk)
  //begin
  //  if (rst_n && exc_ctrl_cs == IRQ_DONE)
  //    $display("%t: Entering interrupt service routine. [%m]", $time);
  //end
  // synopsys translate_on
`endif

endmodule