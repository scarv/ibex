// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the “License”); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Renzo Andri - andrire@student.ethz.ch                      //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                                                                            //
// Design Name:    Instruction Decode Stage                                   //
// Project Name:   zero-riscy                                                 //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Decode stage of the core. It decodes the instructions      //
//                 and hosts the register file.                               //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

`include "zeroriscy_config.sv"

import zeroriscy_defines::*;


// Source/Destination register instruction index
`define REG_S1 19:15
`define REG_S2 24:20
`define REG_S3 29:25
`define REG_D  11:07


module zeroriscy_id_stage
#(
  parameter REG_ADDR_WIDTH      = 5
)
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        test_en_i,

    input  logic        fetch_enable_i,
    output logic        ctrl_busy_o,
    output logic        is_decoding_o,

    // Interface to IF stage
    input  logic              instr_valid_i,
    input  logic       [31:0] instr_rdata_i,      // comes from pipeline of IF stage
    output logic              instr_req_o,

    // Jumps and branches
    output logic        branch_in_ex_o,
    input  logic        branch_decision_i,

    // IF and ID stage signals
    output logic        clear_instr_valid_o,
    output logic        pc_set_o,
    output logic [2:0]  pc_mux_o,
    output logic [1:0]  exc_pc_mux_o,

    input  logic        illegal_c_insn_i,
    input  logic        is_compressed_i,

    input  logic [31:0] pc_if_i,
    input  logic [31:0] pc_id_i,

    // Stalls
    output logic        halt_if_o,      // controller requests a halt of the IF stage

    input  logic        if_ready_i,     // IF stage is done
    output logic        id_ready_o,     // ID stage is ready for the next instruction
    input  logic        lsu_ready_ex_i,
    input  logic        data_valid_lsu_i,
    input  logic        wb_ready_i,

    input  logic        if_valid_i,     // IF stage is done
    output logic        id_valid_o,     // ID stage is done
    input  logic        wb_valid_i,     // WB stage is done

    // ALU
    output logic [ALU_OP_WIDTH-1:0] alu_operator_ex_o,
    output logic [31:0] alu_operand_a_ex_o,
    output logic [31:0] alu_operand_b_ex_o,
    output logic [31:0] alu_operand_c_ex_o, // Still needed if 2r1w reg file used
    output logic [4:0]  shifter_amt_ex_o,

    // MUL
    output logic        mult_en_ex_o,
    output logic [31:0] mult_operand_a_ex_o,
    output logic [31:0] mult_operand_b_ex_o,

    // CSR ID
    output logic        csr_access_ex_o,
    output logic [1:0]  csr_op_ex_o,

    // Interface to load store unit
    output logic        data_req_ex_o,
    output logic        data_we_ex_o,
    output logic [1:0]  data_type_ex_o,
    output logic        data_sign_ext_ex_o,
    output logic [1:0]  data_reg_offset_ex_o,
    output logic        data_load_event_ex_o,

    input  logic        data_misaligned_i,
    input  logic [31:0] misaligned_addr_i,

    // Interrupt signals
    input  logic        irq_i,
    input  logic [4:0]  irq_id_i,
    input  logic        irq_enable_i,
    output logic        irq_ack_o,

    output logic [5:0]  exc_cause_o,
    output logic        save_exc_cause_o,

    output logic        exc_save_if_o,
    output logic        exc_save_id_o,
    output logic        exc_save_takenbranch_o,
    output logic        exc_restore_id_o,

    input  logic        lsu_load_err_i,
    input  logic        lsu_store_err_i,

    // Debug Unit Signals
    input  logic [DBG_SETS_W-1:0] dbg_settings_i,
    input  logic        dbg_req_i,
    output logic        dbg_ack_o,
    input  logic        dbg_stall_i,
    output logic        dbg_trap_o,

    input  logic        dbg_reg_rreq_i,
    input  logic [(REG_ADDR_WIDTH-1):0] dbg_reg_raddr_i,
    output logic [31:0] dbg_reg_rdata_o,

    input  logic        dbg_reg_wreq_i,
    input  logic [(REG_ADDR_WIDTH-1):0] dbg_reg_waddr_i,
    input  logic [31:0] dbg_reg_wdata_i,

    input  logic        dbg_jump_req_i,

    // Write back signal
    input  logic [31:0] regfile_wdata_wb_i,
    input  logic [31:0] regfile_wdata_ex_i,
    input  logic [31:0] csr_rdata_i,

    // Performance Counters
    output logic        perf_jump_o,          // we are executing a jump instruction
    output logic        perf_jr_stall_o,      // jump-register-hazard
    output logic        perf_ld_stall_o       // load-use-hazard
);

  logic [31:0] instr;

  // Decoder/Controller ID stage internal signals
  logic        deassert_we;

  logic        illegal_insn_dec;
  logic        ebrk_insn;
  logic        eret_insn_dec;
  logic        ecall_insn_dec;
  logic        pipe_flush_dec;
  logic        rega_used_dec;
  logic        regb_used_dec;

  logic        branch_taken_ex;
  logic [1:0]  jump_in_id;
  logic [1:0]  jump_in_dec;

  logic        branch_2nd_stage;
  logic        jr_stall;
  logic        load_stall;
  logic        mult_stall;

  logic        halt_id;
  //FSM signals to write back multi cycles instructions
  logic        regfile_we, regfile_we_q;
  logic        select_data_lsu;


  // Immediate decoding and sign extension
  logic [31:0] imm_i_type;
  logic [31:0] imm_iz_type;
  logic [31:0] imm_s_type;
  logic [31:0] imm_sb_type;
  logic [31:0] imm_u_type;
  logic [31:0] imm_uj_type;
  logic [31:0] imm_z_type;
  logic [31:0] imm_s2_type;
  logic [31:0] imm_bi_type;
  logic [31:0] imm_s3_type;
  logic [31:0] imm_vs_type;
  logic [31:0] imm_vu_type;

  logic [31:0] imm_a;       // contains the immediate for operand b
  logic [31:0] imm_b;       // contains the immediate for operand b


  // Signals running between controller and exception controller
  logic        int_req, ext_req, exc_ack;  // handshake

  // Register file interface
  logic [(REG_ADDR_WIDTH-1):0]  regfile_addr_ra_id;
  logic [(REG_ADDR_WIDTH-1):0]  regfile_addr_rb_id;

  logic [(REG_ADDR_WIDTH-1):0]  regfile_alu_waddr_id;
  logic        regfile_alu_we_id;

  logic [31:0] regfile_data_ra_id;
  logic [31:0] regfile_data_rb_id;

  // ALU Control
  logic [ALU_OP_WIDTH-1:0] alu_operator;
  logic [2:0]  alu_op_a_mux_sel;
  logic [2:0]  alu_op_b_mux_sel;
  logic [1:0]  alu_op_c_mux_sel;

  logic [0:0]  imm_a_mux_sel;
  logic [3:0]  imm_b_mux_sel;

  // Multiplier Control
  logic        mult_int_en;      // use integer multiplier

  // Register Write Control
  logic        regfile_mem_we_id;

  // Data Memory Control
  logic        data_we_id;
  logic [1:0]  data_type_id;
  logic        data_sign_ext_id;
  logic [1:0]  data_reg_offset_id;
  logic        data_req_id;
  logic        data_load_event_id;

  // CSR control
  logic        csr_access;
  logic [1:0]  csr_op;

  // Forwarding
  logic [1:0]  operand_a_fw_mux_sel;

  logic [31:0] operand_a_fw_id;
  logic [31:0] operand_b_fw_id;

  logic [31:0] operand_b;

  logic [31:0] alu_operand_a;
  logic [31:0] alu_operand_b;
  logic [31:0] alu_operand_c; // Still needed if 2r1w reg file used

  assign instr = instr_rdata_i;

  // immediate extraction and sign extension
  assign imm_i_type  = { {20 {instr[31]}}, instr[31:20] };
  assign imm_iz_type = {            20'b0, instr[31:20] };
  assign imm_s_type  = { {20 {instr[31]}}, instr[31:25], instr[11:7] };
  assign imm_sb_type = { {19 {instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };
  assign imm_u_type  = { instr[31:12], 12'b0 };
  assign imm_uj_type = { {12 {instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0 };

  // immediate for CSR manipulatin (zero extended)
  assign imm_z_type = { 27'b0, instr[`REG_S1] };

  assign imm_s2_type = { 27'b0, instr[24:20] };
  assign imm_bi_type = { {27{instr[24]}}, instr[24:20] };
  assign imm_s3_type = { 27'b0, instr[29:25] };
  assign imm_vs_type = { {26 {instr[24]}}, instr[24:20], instr[25] };
  assign imm_vu_type = { 26'b0, instr[24:20], instr[25] };

  //---------------------------------------------------------------------------
  // source register selection
  //---------------------------------------------------------------------------
  assign regfile_addr_ra_id = instr[`REG_S1];
  assign regfile_addr_rb_id = instr[`REG_S2];

  //---------------------------------------------------------------------------
  // destination registers
  //---------------------------------------------------------------------------
  assign regfile_alu_waddr_id = instr[`REG_D];

  // kill instruction in the IF/ID stage by setting the instr_valid_id control
  // signal to 0 for instructions that are done
  assign clear_instr_valid_o = id_ready_o | halt_id;

  assign branch_taken_ex = branch_in_ex_o & (branch_decision_i | branch_2nd_stage);

  ////////////////////////////////////////////////////////
  //   ___                                 _      _     //
  //  / _ \ _ __   ___ _ __ __ _ _ __   __| |    / \    //
  // | | | | '_ \ / _ \ '__/ _` | '_ \ / _` |   / _ \   //
  // | |_| | |_) |  __/ | | (_| | | | | (_| |  / ___ \  //
  //  \___/| .__/ \___|_|  \__,_|_| |_|\__,_| /_/   \_\ //
  //       |_|                                          //
  ////////////////////////////////////////////////////////

  // ALU_Op_a Mux
  always_comb
  begin : alu_operand_a_mux
    case (alu_op_a_mux_sel)
      OP_A_REGA_OR_FWD:  alu_operand_a = operand_a_fw_id;
      //OP_A_REGB_OR_FWD:  alu_operand_a = regfile_data_rb_id;
      OP_A_CURRPC:       alu_operand_a = pc_id_i;
      OP_A_IMM:          alu_operand_a = imm_a;
      default:           alu_operand_a = operand_a_fw_id;
    endcase; // case (alu_op_a_mux_sel)
  end

  always_comb
    begin : immediate_a_mux
      unique case (imm_a_mux_sel)
        IMMA_Z:      imm_a = imm_z_type;
        IMMA_ZERO:   imm_a = '0;
        default:     imm_a = '0;
      endcase
    end

 // Operand a forwarding mux used with LSU instructions
 always_comb
   begin : operand_a_fw_mux
     case (operand_a_fw_mux_sel)
       SEL_MISALIGNED:    operand_a_fw_id = misaligned_addr_i;
       SEL_REGFILE:       operand_a_fw_id = regfile_data_ra_id;
       default:           operand_a_fw_id = regfile_data_ra_id;
     endcase; // case (operand_a_fw_mux_sel)
   end


  //////////////////////////////////////////////////////
  //   ___                                 _   ____   //
  //  / _ \ _ __   ___ _ __ __ _ _ __   __| | | __ )  //
  // | | | | '_ \ / _ \ '__/ _` | '_ \ / _` | |  _ \  //
  // | |_| | |_) |  __/ | | (_| | | | | (_| | | |_) | //
  //  \___/| .__/ \___|_|  \__,_|_| |_|\__,_| |____/  //
  //       |_|                                        //
  //////////////////////////////////////////////////////

  // Immediate Mux for operand B
  always_comb
    begin : immediate_b_mux
      unique case (imm_b_mux_sel)
        IMMB_I:      imm_b = imm_i_type;
        IMMB_S:      imm_b = imm_s_type;
        IMMB_U:      imm_b = imm_u_type;
        IMMB_PCINCR: imm_b = (is_compressed_i && (~data_misaligned_i)) ? 32'h2 : 32'h4;
        IMMB_S2:     imm_b = imm_s2_type;
        IMMB_BI:     imm_b = imm_bi_type;
        IMMB_S3:     imm_b = imm_s3_type;
        IMMB_VS:     imm_b = imm_vs_type;
        IMMB_VU:     imm_b = imm_vu_type;
        IMMB_UJ:     imm_b = imm_uj_type;
        IMMB_SB:     imm_b = imm_sb_type;
        default:     imm_b = imm_i_type;
      endcase
    end

  // ALU_Op_b Mux
  always_comb
    begin : alu_operand_b_mux
      case (alu_op_b_mux_sel)
        //OP_B_REGA_OR_FWD:  operand_b = regfile_data_ra_id;
        OP_B_REGB_OR_FWD:  operand_b = regfile_data_rb_id;
        OP_B_IMM:          operand_b = imm_b;
        OP_B_ZERO:         operand_b = '0;
        default:           operand_b = regfile_data_rb_id;
      endcase // case (alu_op_b_mux_sel)
    end

  assign alu_operand_b   = operand_b;
  assign operand_b_fw_id = operand_b;

  //////////////////////////////////////////////////////
  //   ___                                 _    ____  //
  //  / _ \ _ __   ___ _ __ __ _ _ __   __| |  / ___| //
  // | | | | '_ \ / _ \ '__/ _` | '_ \ / _` | | |     //
  // | |_| | |_) |  __/ | | (_| | | | | (_| | | |___  //
  //  \___/| .__/ \___|_|  \__,_|_| |_|\__,_|  \____| //
  //       |_|                                        //
  //////////////////////////////////////////////////////

  // ALU OP C Mux, jump or store. TODO: Change it
/*
  always_comb
    begin : alu_operand_c_mux
      case (alu_op_c_mux_sel)
        OP_C_REGB_OR_FWD:  alu_operand_c = regfile_data_rb_id;
        OP_C_RA:           alu_operand_c = pc_if_i; // this is the return address
        default:           alu_operand_c = regfile_data_rb_id;
      endcase // case (alu_op_c_mux_sel)
    end
*/
  assign alu_operand_c = regfile_data_rb_id;

  /////////////////////////////////////////////////////////
  //  ____  _____ ____ ___ ____ _____ _____ ____  ____   //
  // |  _ \| ____/ ___|_ _/ ___|_   _| ____|  _ \/ ___|  //
  // | |_) |  _|| |  _ | |\___ \ | | |  _| | |_) \___ \  //
  // |  _ <| |__| |_| || | ___) || | | |___|  _ < ___) | //
  // |_| \_\_____\____|___|____/ |_| |_____|_| \_\____/  //
  //                                                     //
  /////////////////////////////////////////////////////////

  logic [31:0] regfile_wdata_mux;
  logic        regfile_we_mux;
  logic  [4:0] regfile_waddr_mux;
  //TODO: add assertion
  // Register File mux
  always_comb
  begin
    if(dbg_reg_wreq_i) begin
      regfile_wdata_mux   = dbg_reg_wdata_i;
      regfile_waddr_mux   = dbg_reg_waddr_i;
      regfile_we_mux      = 1'b1;
    end else begin
      regfile_we_mux      = regfile_we;
      regfile_waddr_mux   = regfile_alu_waddr_id;
      if (select_data_lsu)
        regfile_wdata_mux = regfile_wdata_wb_i;
      else
        if (csr_access)
          regfile_wdata_mux = csr_rdata_i;
        else
        //TODO: modify this
        if ((jump_in_id == BRANCH_JALR) || (jump_in_id == BRANCH_JAL))
          regfile_wdata_mux   = pc_if_i;
        else
          regfile_wdata_mux   = regfile_wdata_ex_i;
    end
  end

  zeroriscy_register_file  registers_i
  (
    .clk          ( clk                ),
    .rst_n        ( rst_n              ),

    .test_en_i    ( test_en_i          ),

    // Read port a
    .raddr_a_i    ( regfile_addr_ra_id ),
    .rdata_a_o    ( regfile_data_ra_id ),
    // Read port b
    .raddr_b_i    ( (dbg_reg_rreq_i == 1'b0) ? regfile_addr_rb_id : dbg_reg_raddr_i ),
    .rdata_b_o    ( regfile_data_rb_id ),
    // write port
    .waddr_a_i    ( regfile_waddr_mux ),
    .wdata_a_i    ( regfile_wdata_mux ),
    .we_a_i       ( regfile_we_mux    )
  );

  assign dbg_reg_rdata_o = regfile_data_rb_id;


  ///////////////////////////////////////////////
  //  ____  _____ ____ ___  ____  _____ ____   //
  // |  _ \| ____/ ___/ _ \|  _ \| ____|  _ \  //
  // | | | |  _|| |  | | | | | | |  _| | |_) | //
  // | |_| | |__| |__| |_| | |_| | |___|  _ <  //
  // |____/|_____\____\___/|____/|_____|_| \_\ //
  //                                           //
  ///////////////////////////////////////////////

  zeroriscy_decoder decoder_i
  (
    // controller related signals
    .deassert_we_i                   ( deassert_we               ),
    .data_misaligned_i               ( data_misaligned_i         ),
    .branch_2nd_stage_i              ( branch_2nd_stage          ),

    .illegal_insn_o                  ( illegal_insn_dec          ),
    .ebrk_insn_o                     ( ebrk_insn                 ),
    .eret_insn_o                     ( eret_insn_dec             ),
    .ecall_insn_o                    ( ecall_insn_dec            ),
    .pipe_flush_o                    ( pipe_flush_dec            ),

    .rega_used_o                     ( rega_used_dec             ),
    .regb_used_o                     ( regb_used_dec             ),


    // from IF/ID pipeline
    .instr_rdata_i                   ( instr                     ),
    .illegal_c_insn_i                ( illegal_c_insn_i          ),

    // ALU signals
    .alu_operator_o                  ( alu_operator              ),
    .alu_op_a_mux_sel_o              ( alu_op_a_mux_sel          ),
    .alu_op_b_mux_sel_o              ( alu_op_b_mux_sel          ),
    .alu_op_c_mux_sel_o              ( alu_op_c_mux_sel          ),

    .imm_a_mux_sel_o                 ( imm_a_mux_sel             ),
    .imm_b_mux_sel_o                 ( imm_b_mux_sel             ),
    .mult_int_en_o                   ( mult_int_en               ),

    // Register file control signals
    .regfile_mem_we_o                ( regfile_mem_we_id         ),
    .regfile_alu_we_o                ( regfile_alu_we_id         ),

    // CSR control signals
    .csr_access_o                    ( csr_access                ),
    .csr_op_o                        ( csr_op                    ),

    // Data bus interface
    .data_req_o                      ( data_req_id               ),
    .data_we_o                       ( data_we_id                ),
    .data_type_o                     ( data_type_id              ),
    .data_sign_extension_o           ( data_sign_ext_id          ),
    .data_reg_offset_o               ( data_reg_offset_id        ),
    .data_load_event_o               ( data_load_event_id        ),

    // jump/branches
    .jump_in_dec_o                   ( jump_in_dec               ),
    .jump_in_id_o                    ( jump_in_id                )
  );

  ////////////////////////////////////////////////////////////////////
  //    ____ ___  _   _ _____ ____   ___  _     _     _____ ____    //
  //   / ___/ _ \| \ | |_   _|  _ \ / _ \| |   | |   | ____|  _ \   //
  //  | |  | | | |  \| | | | | |_) | | | | |   | |   |  _| | |_) |  //
  //  | |__| |_| | |\  | | | |  _ <| |_| | |___| |___| |___|  _ <   //
  //   \____\___/|_| \_| |_| |_| \_\\___/|_____|_____|_____|_| \_\  //
  //                                                                //
  ////////////////////////////////////////////////////////////////////

  zeroriscy_controller controller_i
  (
    .clk                            ( clk                    ),
    .rst_n                          ( rst_n                  ),

    .fetch_enable_i                 ( fetch_enable_i         ),
    .ctrl_busy_o                    ( ctrl_busy_o            ),
    .is_decoding_o                  ( is_decoding_o          ),

    // decoder related signals
    .deassert_we_o                  ( deassert_we            ),
    .illegal_insn_i                 ( illegal_insn_dec       ),
    .eret_insn_i                    ( eret_insn_dec          ),
    .pipe_flush_i                   ( pipe_flush_dec         ),

    // from IF/ID pipeline
    .instr_valid_i                  ( instr_valid_i          ),
    .instr_rdata_i                  ( instr                  ),

    // from prefetcher
    .instr_req_o                    ( instr_req_o            ),

    // to prefetcher
    .pc_set_o                       ( pc_set_o               ),
    .pc_mux_o                       ( pc_mux_o               ),

    // LSU
    .data_req_ex_i                  ( data_req_ex_o          ),
    .data_misaligned_i              ( data_misaligned_i      ),
    .data_load_event_i              ( data_load_event_ex_o   ),

    // jump/branch control
    .branch_taken_ex_i              ( branch_taken_ex        ),
    .jump_in_id_i                   ( jump_in_id             ),
    .jump_in_dec_i                  ( jump_in_dec            ),

    // Exception Controller Signals
    .int_req_i                      ( int_req                ),
    .ext_req_i                      ( ext_req                ),
    .exc_ack_o                      ( exc_ack                ),
    .irq_ack_o                      ( irq_ack_o              ),
    .exc_save_if_o                  ( exc_save_if_o          ),
    .exc_save_id_o                  ( exc_save_id_o          ),
    .exc_save_takenbranch_o         ( exc_save_takenbranch_o ),
    .exc_restore_id_o               ( exc_restore_id_o       ),

    // Debug Unit Signals
    .dbg_req_i                      ( dbg_req_i              ),
    .dbg_ack_o                      ( dbg_ack_o              ),
    .dbg_stall_i                    ( dbg_stall_i            ),
    .dbg_jump_req_i                 ( dbg_jump_req_i         ),

    // Forwarding signals
    .operand_a_fw_mux_sel_o         ( operand_a_fw_mux_sel   ),

    // Stall signals
    .halt_if_o                      ( halt_if_o              ),
    .halt_id_o                      ( halt_id                ),

    .branch_2nd_stage_o             ( branch_2nd_stage       ),
    .jr_stall_o                     ( jr_stall               ),

    .id_ready_i                     ( id_ready_o             ),

    .if_valid_i                     ( if_valid_i             ),
    .wb_valid_i                     ( wb_valid_i             ),

    // Performance Counters
    .perf_jump_o                    ( perf_jump_o            ),
    .perf_jr_stall_o                ( perf_jr_stall_o        ),
    .perf_ld_stall_o                ( perf_ld_stall_o        )
  );

  ///////////////////////////////////////////////////////////////////////
  //  _____               ____            _             _ _            //
  // | ____|_  _____     / ___|___  _ __ | |_ _ __ ___ | | | ___ _ __  //
  // |  _| \ \/ / __|   | |   / _ \| '_ \| __| '__/ _ \| | |/ _ \ '__| //
  // | |___ >  < (__ _  | |__| (_) | | | | |_| | | (_) | | |  __/ |    //
  // |_____/_/\_\___(_)  \____\___/|_| |_|\__|_|  \___/|_|_|\___|_|    //
  //                                                                   //
  ///////////////////////////////////////////////////////////////////////

  zeroriscy_exc_controller exc_controller_i
  (
    .clk                  ( clk              ),
    .rst_n                ( rst_n            ),

    // to controller
    .int_req_o            ( int_req          ),
    .ext_req_o            ( ext_req          ),
    .ack_i                ( exc_ack          ),

    .trap_o               ( dbg_trap_o       ),

    // to IF stage
    .pc_mux_o             ( exc_pc_mux_o     ),

    // Interrupt signals
    .irq_i                ( irq_i            ),
    .irq_id_i             ( irq_id_i         ),
    .irq_enable_i         ( irq_enable_i     ),

    .ebrk_insn_i          ( is_decoding_o & ebrk_insn        ),
    .illegal_insn_i       ( is_decoding_o & illegal_insn_dec ),
    .ecall_insn_i         ( is_decoding_o & ecall_insn_dec   ),
    .eret_insn_i          ( is_decoding_o & eret_insn_dec    ),

    .lsu_load_err_i       ( lsu_load_err_i   ),
    .lsu_store_err_i      ( lsu_store_err_i  ),

    .cause_o              ( exc_cause_o      ),
    .save_cause_o         ( save_exc_cause_o ),

    .dbg_settings_i       ( dbg_settings_i   )
  );



  /////////////////////////////////////
  //   ___ ____        _______  __   //
  //  |_ _|  _ \      | ____\ \/ /   //
  //   | || | | |_____|  _|  \  /    // - merging network
  //   | || |_| |_____| |___ /  \    //
  //  |___|____/      |_____/_/\_\   //
  //                                 //
  /////////////////////////////////////

  always_comb
  begin

    data_we_ex_o                = data_we_id;
    data_type_ex_o              = data_type_id;
    data_sign_ext_ex_o          = data_sign_ext_id;

    data_reg_offset_ex_o        = 2'b0;

    alu_operator_ex_o           = alu_operator;
    alu_operand_a_ex_o          = alu_operand_a;
    alu_operand_b_ex_o          = alu_operand_b;
    alu_operand_c_ex_o          = alu_operand_c;

//    mult_en_ex_o                = mult_int_en;

    csr_access_ex_o             = csr_access;
    csr_op_ex_o                 = id_ready_o ? csr_op : CSR_OP_NONE;

    data_req_ex_o               = data_req_id;

    data_reg_offset_ex_o        = data_reg_offset_id;
    data_load_event_ex_o        = ((data_req_id & (~halt_id)) ? data_load_event_id : 1'b0);

    branch_in_ex_o              = (jump_in_dec == BRANCH_COND);
  end

  logic [4:0] mult_cycle_n, mult_cycle_q;

  always_ff @(posedge clk or negedge rst_n) begin : proc_mult_en_ex_o
    if(~rst_n) begin
      mult_cycle_q <= '0;
    end else begin
      if(mult_int_en) begin
        mult_cycle_q <= mult_cycle_n;
      end
    end
  end

  assign mult_en_ex_o = mult_int_en;
  assign mult_operand_a_ex_o = alu_operand_a;
  assign mult_operand_b_ex_o = alu_operand_b;

  enum logic { IDLE, WAIT_LSU } id_wb_fsm_cs, id_wb_fsm_ns;

  ///////////////////////////////////////
  // ID-EX/WB Pipeline Register        //
  ///////////////////////////////////////
  always_ff @(posedge clk, negedge rst_n)
  begin : EX_WB_Pipeline_Register
    if (~rst_n)
    begin
      regfile_we_q    <= 1'b0;
      id_wb_fsm_cs    <= IDLE;
    end
    else begin
      regfile_we_q    <= regfile_mem_we_id & (load_stall | mult_stall);
      id_wb_fsm_cs    <= id_wb_fsm_ns;
    end
  end

  ///////////////////////////////////////
  // ID-EX/WB FMS                      //
  ///////////////////////////////////////

  always_comb
  begin
    id_wb_fsm_ns    = id_wb_fsm_cs;
    regfile_we      = regfile_alu_we_id & (~halt_id);
    load_stall      = 1'b0;
    mult_stall      = 1'b0;
    select_data_lsu = 2'b0;
    shifter_amt_ex_o = alu_operand_b_ex_o[4:0];
    mult_cycle_n  = mult_cycle_q + 5'd1;

    unique case (id_wb_fsm_cs)

      IDLE:
      begin
	    //if instr not valid, deassert and so it is 0
        if(data_req_ex_o) begin
          //LSU operation
          regfile_we    = 1'b0;
          id_wb_fsm_ns  = WAIT_LSU;
          load_stall    = 1'b1;
        end
        if(mult_int_en) begin
          //MUL operation
          regfile_we    = 1'b0;
          id_wb_fsm_ns  = WAIT_LSU;
          mult_stall    = 1'b1;
          shifter_amt_ex_o = mult_cycle_q;
        end
      end

      WAIT_LSU:
      begin
        shifter_amt_ex_o = mult_cycle_q;
        if(data_valid_lsu_i) begin
          //LSU operation
          regfile_we    = regfile_we_q;
          id_wb_fsm_ns  = IDLE;
          load_stall    = 1'b0;
          select_data_lsu = 1'b1;
        end
        else
          load_stall    = 1'b1;
        if(mult_cycle_q==5'd31) begin
          //MUL operation
            regfile_we    = regfile_we_q;
            id_wb_fsm_ns  = IDLE;
            mult_stall    = 1'b0;
            mult_cycle_n  = 5'd0;
        end
     end
    endcase
  end

  // stall control
  assign id_ready_o = (~jr_stall) & (~load_stall) & (~mult_stall);
  
  assign id_valid_o = (~halt_id) & id_ready_o;


  //----------------------------------------------------------------------------
  // Assertions
  //----------------------------------------------------------------------------

  // make sure that branch decision is valid when jumping
  assert property (
    @(posedge clk) (branch_in_ex_o) |-> (branch_decision_i !== 1'bx) ) else $display("Branch decision is X");

`ifdef CHECK_MISALIGNED
  assert property (
    @(posedge clk) (~data_misaligned_i) ) else $display("Misaligned memory access at %x",pc_id_i);
`endif

  // the instruction delivered to the ID stage should always be valid
  assert property (
    @(posedge clk) (instr_valid_i & (~illegal_c_insn_i)) |-> (!$isunknown(instr_rdata_i)) ) else $display("Instruction is valid, but has at least one X");

endmodule