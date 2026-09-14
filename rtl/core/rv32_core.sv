//Represents the completed processor pipeline for the RV32I architecture. This module instantiates the IF, ID, EX, MEM, and WB stages of the pipeline and connects them together to form a complete processor.
module rv32_core #(
 parameter logic [31:0] RESET_PC = rv32_pkg::RESET_VECTOR //Selects the first instruction address after reset, parameter allows wrapper to change the reset PC address
) (
    input logic clk, //advance state
    input logic reset, //clear PC, regs

    //Instruction memory
    //Core continously req instruction at PC, only accepts if imem_ready is high
    input logic imem_ready, //memory has returned requested instruction
    input logic [31:0] imem_rdata, //the requested mem aka 32 bit instruction

    output logic imem_valid, //CPU is requesting a new instruction
    output logic [31:0] imem_addr, //requested instruction address
    
    //Data memory
    input logic dmem_ready, //memory transaction is completed
    input logic [31:0] dmem_rdata, //data read from memory
    
    output logic dmem_valid, //a memory transaction exists
    output logic dmem_write, //1 for store, 0 for load
    output logic [3:0] dmem_wstrb, //selects which bytes will be written, 4 byte lanes e.g wstrb[0] = bits 0 to 7
    output logic [31:0] dmem_addr, //byte address
    output logic [31:0] dmem_wdata, //data being stored
   
    //Retirement/Debugs
    output logic retire_valid, //Instruction was complete
    output logic [31:0] retire_pc, //address
    output logic [31:0] retire_instr, //encoding
    output logic [4:0] retire_rd, //destination reg
    output logic [31:0] retire_rd_value //value written to reg
);
    //Makes package definition available, w/o having to write out the prefix
    import rv32_pkg::*; 

    logic [31:0] pc;
    logic [31:0] regs [0:31]; //The reg file, 0x0-0x31

    //Pipeline registers, stores info in those stages
    if_id_t if_id;
    id_ex_t id_ex;
    ex_mem_t ex_mem;
    mem_wb_t mem_wb;

    //Decode stage signals
    control_t dec_ctrl;
    logic [4:0] dec_rs1, dec_rs2, dec_rd;
    logic [31:0] dec_imm, dec_rs1_value, dec_rs2_value;

    //Execute stage signals
    logic[31:0] ex_a, ex_b_reg, ex_b, ex_alu_result; //The execute_b is the final ALU operand B

    //Forwarding Signals
    logic [31:0] ex_mem_forward_value, mem_wb_forward_value; //Allows us to pipeline dependent instructions effectively without stalling

    //Branching signals
    logic ex_branch_taken; //Tells pipeline to redirect
    logic [31:0] ex_branch_target; //New PC after redirect

    //Hazards
    logic load_use_hazard; //Next instruction need unfinished load, insert NOP and hold instruction
    logic memory_stall; //Memory has not completed request, freeze pipeline

    logic [31:0] load_value;
    logic [31:0] memory_wb_value;
    integer i; //Loop index useful for resets

    assign imem_valid = 1'b1;
    assign imem_addr = pc;

    assign dmem_valid = ex_mem.valid && (ex_mem.mem_read || ex_mem.mem_write); //Valid request for memory request if the EX/MEM contains real instruction and it is a LOAD/STORE instruction
    assign dmem_write = ex_mem.mem_write; 
    assign dmem_addr = ex_mem.alu_result; //Address is ALU calculated as rs1 + imm
    assign dmem_wdata = ex_mem.store_data << (8 * ex_mem.alu_result[1:0]); //ex_mem.store_data is value from rs2, shift to left by 8 * address offset. Used for when storing words, bytes, halfbytes,etc

    always_comb begin
        //Data memory write strobe
        //dmem_wstrb[3] -> dmem_wdata[31:24]
        //dmem_wstrb[2] -> dmem_wdata[23:16]
        //dmem_wstrb[1] -> dmem_wdata[15:8]
        //dmem_wstrb[0] -> dmem_wdata[7:0]
        dmem_wstrb = 4'b0000; //Default strobe, disable all four byte lanes
        if(ex_mem.mem_write) begin //Only generate strobes for stores
            unique case(ex_mem.funct3) //Funct3 selects the store size
                //000 -> SB = 1 byte, this uses 1 lane, notice only 1/4 is binary 1 in the starting strobe value
                //001 -> SH = 2 byte, this uses 2 lanes, notice 2/4 is binary 1 in the starting strobe value
                //010 -> SW = 4 byte, this uses all 4 lanes, notice 4/4 is binary 1 in the starting strobe value
                3'b000: dmem_wstrb = 4'b0001 << ex_mem.alu_result[1:0]; //e.g start with 0001 and if offset is 2 -> strobe is 0100, lane 2
                3'b001: dmem_wstrb = 4'b0011 << ex_mem.alu_result[1:0]; 
                3'b010: dmem_wstrb = 4'b1111; 
                //Complete example: given sb x5, 1(x1) || x5 = 0x000000AA, offset = 1
                //dmem_wdata alligns write data, shift 8 * 1 = 0x0000AA00
                //Byte lane is selected 0001 << 1 = 0010, memory only updates byte lane 1
                //Written Memory: 0xXXXXAAXX

                default: dmem_wstrb = 4'b0000;
            endcase
        end
    end

    assign memory_stall = dmem_valid && !dmem_ready; //Detect if theres a memory stall, a valid memory req exists and memory has not completed yet, will stall pipeline

    //Decode block
    always_comb begin
        //Extract register indices
        dec_rs1 = if_id.instr[19:15];
        dec_rs2 = if_id.instr[24:20];
        dec_rd = if_id.instr[11:7];

        //Decode the rs1 and rs2 register values, if x0, then simply = 32bit 0. Else, if (WB is writing to the same register, then return the WB value, else return the normal reg file value
        //This added complication checking for WBs will be useful for Writeback to Decode forwarding/bypassing
        dec_rs1_value = (dec_rs1 == 0) ? 32'b0 : (mem_wb.valid && mem_wb.reg_write && mem_wb.rd != 0 && mem_wb.rd == dec_rs1) ? mem_wb.wb_value : regs[dec_rs1];
        dec_rs2_value = (dec_rs2 == 0) ? 32'b0 : (mem_wb.valid && mem_wb.reg_write && mem_wb.rd != 0 && mem_wb.rd == dec_rs2) ? mem_wb.wb_value : regs[dec_rs2];

        dec_ctrl = '0; //Set all instruction control signals to 0, safe default
        dec_ctrl.alu_op = ALU_ADD;
        dec_ctrl.branch_op = BR_NONE;
        dec_ctrl.wb_sel = WB_ALU; //Default WB source is ALU result
        dec_ctrl.funct3 = if_id.instr[14:12];
        dec_imm = 32'b0;

        //Opcode decode
        unique case (if_id.instr[6:0])
            7'b0110011: begin //R type or OP type
                dec_ctrl.legal = 1'b1;
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.uses_rs2 = 1'b1;
                dec_ctrl.reg_write = 1'b1; //writes to rd
                unique case(if_id.instr[14:12])
                    3'b000: dec_ctrl.alu_op = if_id.instr[30] ? ALU_SUB : ALU_ADD; //for func3 = 000, bit 30 distinguishes ADD or SUB
                    3'b001: dec_ctrl.alu_op = ALU_SLL;
                    3'b010: dec_ctrl.alu_op = ALU_SLT;
                    3'b011: dec_ctrl.alu_op = ALU_SLTU;
                    3'b100: dec_ctrl.alu_op = ALU_XOR;
                    3'b101: dec_ctrl.alu_op = if_id.instr[30] ? ALU_SRA : ALU_SRL; //if bit 30 = 0, SRL, else SRA
                    3'b110: dec_ctrl.alu_op = ALU_OR;
                    3'b111: dec_ctrl.alu_op = ALU_AND;
                endcase
            end

            7'b0010011: begin //I type or OP-IMM
                dec_ctrl.legal = 1'b1;
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.reg_write = 1'b1; //writes to rd
                dec_ctrl.alu_b_imm = 1'b1;
                dec_imm = {{20{if_id.instr[31]}}, if_id.instr[31:20]}; //Signed extended
                unique case(if_id.instr[14:12])
                    3'b000: dec_ctrl.alu_op = ALU_ADD; //Basically same as R type
                    3'b001: dec_ctrl.alu_op = ALU_SLL;
                    3'b010: dec_ctrl.alu_op = ALU_SLT;
                    3'b011: dec_ctrl.alu_op = ALU_SLTU;
                    3'b100: dec_ctrl.alu_op = ALU_XOR;
                    3'b101: dec_ctrl.alu_op = if_id.instr[30] ? ALU_SRA : ALU_SRL;
                    3'b110: dec_ctrl.alu_op = ALU_OR;
                    3'b111: dec_ctrl.alu_op = ALU_AND;
                endcase
            end

            7'b0000011: begin //Load type
                dec_ctrl.legal = 1'b1;
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.reg_write = 1'b1;
                dec_ctrl.alu_b_imm = 1'b1;
                dec_ctrl.mem_read = 1'b1;
                dec_ctrl.wb_sel = WB_MEM; //Write the value into rd, loaded memory value 
                dec_imm = {{20{if_id.instr[31]}}, if_id.instr[31:20]}; //Sign extended
            end

            7'b0100011: begin //Store type
                dec_ctrl.legal = 1'b1;
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.uses_rs2 = 1'b1;
                dec_ctrl.alu_b_imm = 1'b1;
                dec_ctrl.mem_write = 1'b1;
                dec_imm = {{20{if_id.instr[31]}}, if_id.instr[31:25], if_id.instr[11:7]}; //Sign extended
            end

            7'b1100011: begin //Branch
                dec_ctrl.legal = 1'b1;
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.uses_rs2 = 1'b1;
                dec_imm = {{19{if_id.instr[31]}}, if_id.instr[31], if_id.instr[7], if_id.instr[30:25], if_id.instr[11:8], 1'b0};
                unique case (if_id.instr[14:12])
                    3'b000: dec_ctrl.branch_op = BR_EQ; //Equal
                    3'b001: dec_ctrl.branch_op = BR_NE; //Not equal
                    3'b100: dec_ctrl.branch_op = BR_LT;
                    3'b101: dec_ctrl.branch_op = BR_GE;
                    3'b110: dec_ctrl.branch_op = BR_LTU; //Less than unsigned
                    3'b111: dec_ctrl.branch_op = BR_GEU; //Greater or equal unsigned
                    default: dec_ctrl.legal = 1'b0;
                endcase
            end

            7'b1101111: begin //Jal
                dec_ctrl.legal = 1'b1;
                dec_ctrl.reg_write = 1'b1;
                dec_ctrl.branch_op = BR_JUMP;
                dec_ctrl.wb_sel = WB_PC4;
                dec_imm = {{11{if_id.instr[31]}}, if_id.instr[31], if_id.instr[19:12], if_id.instr[20], if_id.instr[30:21], 1'b0};
            end
            7'b1100111: begin //Jalr
                dec_ctrl.legal = (if_id.instr[14:12] == 3'b000); //Only legal when funct3 is 0
                dec_ctrl.uses_rs1 = 1'b1;
                dec_ctrl.reg_write = 1'b1;
                dec_ctrl.jalr = 1'b1;
                dec_ctrl.branch_op = BR_JUMP;
                dec_ctrl.wb_sel = WB_PC4;
                dec_imm = {{20{if_id.instr[31]}}, if_id.instr[31:20]};
            end

            7'b0110111: begin //Load upper immediate, U type
                dec_ctrl.legal = 1'b1;
                dec_ctrl.reg_write = 1'b1; //writes rd, supplying rd as ALU operand B
                dec_ctrl.alu_b_imm = 1'b1;
                dec_imm = {if_id.instr[31:12], 12'b0};
            end
            7'b0010111: begin // Add Upper Immediate to PC (AUIPC)
                dec_ctrl.legal = 1'b1;
                dec_ctrl.reg_write = 1'b1;
                dec_ctrl.alu_a_pc = 1'b1; //Operand A = PC
                dec_ctrl.alu_b_imm = 1'b1;
                dec_imm = {if_id.instr[31:12], 12'b0};
            end        
            default: dec_ctrl.legal = 1'b0; //anything else is illegal 
        endcase
    end

    assign mem_wb_forward_value = mem_wb.wb_value; //The final value set for register writeback, could be a PC4, memory data, or ALU result
    assign ex_mem_forward_value = (ex_mem.wb_sel == WB_PC4) ? ex_mem.pc4 : ex_mem.alu_result; //if wb source is PC+4, then forward that value, else forward ALU result

    //The EX Block
    always_comb begin
        ex_a = id_ex.ctrl.alu_a_pc ? id_ex.pc : (id_ex.ctrl.uses_rs1 ? id_ex.rs1_value : 32'b0); //Choose intial value for ALU operand A, could be either instruction PC (for AUIPC), rs1, or 0
        ex_b_reg = id_ex.rs2_value; //Initial value for operand B, could turn out to be rs2 or immediate

        if (id_ex.ctrl.uses_rs1 && id_ex.rs1 != 0) begin //Forwarding operand A, consider if current instruction uses rs1 and rs1 is not x0
        if (ex_mem.valid && ex_mem.reg_write && !ex_mem.mem_read && ex_mem.rd == id_ex.rs1) //If EX/MEM contain real instruction, that instruction writes to a register, it is not a load instruction waiting for memory, the destination is rs1, then forward from EX/MEM
            ex_a = ex_mem_forward_value; //E.g ex_mem.rd = x5, and id_ex.rs1 = x5 for consecutive instructions, forward
        else if (mem_wb.valid && mem_wb.reg_write && mem_wb.rd == id_ex.rs1) //If EX/MEM does not have needed result, check for MEM/WB
            ex_a = mem_wb_forward_value;
        end
        if (id_ex.ctrl.uses_rs2 && id_ex.rs2 != 0) begin //Forwarding operand B, if actually uses rs2 and rs2 is not 0 
        if (ex_mem.valid && ex_mem.reg_write && !ex_mem.mem_read && ex_mem.rd == id_ex.rs2) //Same process as operand A
            ex_b_reg = ex_mem_forward_value;
        else if (mem_wb.valid && mem_wb.reg_write && mem_wb.rd == id_ex.rs2)
            ex_b_reg = mem_wb_forward_value;
        end
        ex_b = id_ex.ctrl.alu_b_imm ? id_ex.imm : ex_b_reg; //Chooses between immediate versus the current forwarded rs2 value

        //The actual ALU operation
        unique case (id_ex.ctrl.alu_op)
            ALU_ADD: ex_alu_result = ex_a + ex_b;
            ALU_SUB: ex_alu_result = ex_a - ex_b;
            ALU_AND: ex_alu_result = ex_a & ex_b;
            ALU_OR: ex_alu_result = ex_a | ex_b;
            ALU_XOR: ex_alu_result = ex_a ^ ex_b;
            ALU_SLT: ex_alu_result = {31'b0, $signed(ex_a) < $signed(ex_b)}; //Concatenate 31 leading 0s, 1 if exA < exB
            ALU_SLTU: ex_alu_result = {31'b0, ex_a < ex_b}; //Treats both as unsigned
            ALU_SLL: ex_alu_result = ex_a << ex_b[4:0]; //Shift left 0-31
            ALU_SRL: ex_alu_result = ex_a >> ex_b[4:0]; //Shift right 0-31
            ALU_SRA: ex_alu_result = $signed(ex_a) >>> ex_b[4:0]; //Preserves sign
            default: ex_alu_result = 32'b0; //Default
        endcase
    end

    always_comb begin
        ex_branch_taken = 1'b0; //Default do not redirect

        unique case (id_ex.ctrl.branch_op)
            BR_EQ: ex_branch_taken = (ex_a == ex_b_reg);
            BR_NE: ex_branch_taken = (ex_a != ex_b_reg);
            BR_LT: ex_branch_taken = ($signed(ex_a) < $signed(ex_b_reg));
            BR_GE: ex_branch_taken = ($signed(ex_a) >= $signed(ex_b_reg));
            BR_LTU: ex_branch_taken = (ex_a < ex_b_reg);
            BR_GEU: ex_branch_taken = (ex_a >= ex_b_reg);
            BR_JUMP: ex_branch_taken = 1'b1; //Unconditional
            default: ex_branch_taken = 1'b0;
        endcase
        ex_branch_target = id_ex.ctrl.jalr ? ((ex_a + id_ex.imm) & 32'hffff_fffe) : (id_ex.pc + id_ex.imm); //If Jalr, compute rs1 + imm and sets bit 0 to 0. Else PC + immediate
    end
    //Load use hazard, Used when instruction in ID needs a value being loaded by a previous instruction
    assign load_use_hazard = id_ex.valid && id_ex.ctrl.mem_read && (id_ex.rd != 0) && if_id.valid && dec_ctrl.legal &&((dec_ctrl.uses_rs1 && dec_rs1 == id_ex.rd) ||(dec_ctrl.uses_rs2 && dec_rs2 == id_ex.rd));

    always_comb begin
        unique case (ex_mem.alu_result[1:0]) //Selecting addressed load bytes, as it may request a byte or halfword
            2'd0: load_value = dmem_rdata; //Offset 0
            2'd1: load_value = dmem_rdata >> 8; //Offset 1, shift right by 8
            2'd2: load_value = dmem_rdata >> 16; //Offset 2, shift right by 16
            default: load_value = dmem_rdata >> 24; //Else, shift by 24
        endcase
        unique case (ex_mem.funct3) //Interprets funct3
            3'b000: load_value = {{24{load_value[7]}}, load_value[7:0]}; //LB, sign extend from bits 8 - 32
            3'b001: load_value = {{16{load_value[15]}}, load_value[15:0]}; //LH, 16 bit halfword extend to 32 bits
            3'b010: load_value = dmem_rdata; //Regular load word
            3'b100: load_value = {24'b0, load_value[7:0]}; //Load upper 24 bits as 0
            3'b101: load_value = {16'b0, load_value[15:0]}; //Load upper 16 bits as 0
            default: load_value = 32'b0; 
        endcase
        unique case (ex_mem.wb_sel) //Selecting writeback value
            WB_MEM: memory_wb_value = load_value; //Load, eg lw x5, 0x(x1) writes loaded value into x5
            WB_PC4: memory_wb_value = ex_mem.pc4; //JAL or JALR, e.g jal x1, function, writes PC+4 into x1
            default: memory_wb_value = ex_mem.alu_result; //Default ALU result
        endcase
    end

    //Instruction at end of pipeline, committed already so useful for debugs
    assign retire_valid = mem_wb.valid && !memory_stall; //MEM/WB contains real instruction
    assign retire_pc = mem_wb.pc; //PC of finished instruction
    assign retire_instr = mem_wb.instr; //raw 32 encoding of instruction
    assign retire_rd = mem_wb.reg_write ? mem_wb.rd : 5'b0; //does destination register exist? 
    assign retire_rd_value = mem_wb.reg_write ? mem_wb.wb_value : 32'b0; //what value in destination register

    always_ff @(posedge clk) begin
        if(reset) begin
            //Reset registers and PC
            pc <= RESET_PC;
            if_id <= '0;
            id_ex <= '0;
            ex_mem <= '0;
            mem_wb <= '0;
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        end

        else begin //Register writeback
            if (mem_wb.valid && mem_wb.reg_write && mem_wb.rd != 0 && !memory_stall) //Register is written when conditions are met
                //Instruction is real, writes a register, destination is not x0, no memory stall
                regs[mem_wb.rd] <= mem_wb.wb_value;
            regs[0] <= 32'b0; //x0 = 0

            if(!memory_stall) begin

                //Advance EX/MEM into MEM/WB
                mem_wb.valid <= ex_mem.valid;
                mem_wb.pc <= ex_mem.pc;
                mem_wb.instr <= ex_mem.instr;
                mem_wb.rd <= ex_mem.rd;
                mem_wb.wb_value <= memory_wb_value;
                mem_wb.reg_write <= ex_mem.reg_write;

                //Advance ID/EX into EX/MEM
                ex_mem.valid <= id_ex.valid;
                ex_mem.pc <= id_ex.pc;
                ex_mem.pc4 <= id_ex.pc4;
                ex_mem.instr <= id_ex.instr;
                ex_mem.rd <= id_ex.rd;
                ex_mem.alu_result <= ex_alu_result;
                ex_mem.store_data <= ex_b_reg;
                //Control signals into MEM
                ex_mem.reg_write <= id_ex.ctrl.reg_write;
                ex_mem.mem_read <= id_ex.ctrl.mem_read;
                ex_mem.mem_write <= id_ex.ctrl.mem_write;
                ex_mem.funct3 <= id_ex.ctrl.funct3;
                ex_mem.wb_sel <= id_ex.ctrl.wb_sel;

                //Branching and Jumping
                if (id_ex.valid && ex_branch_taken) begin //Ex is a real instruction and is a branching
                    pc <= ex_branch_target;
                    if_id.valid <= 1'b0; //Flush younger instructions as they were from wrong path
                    id_ex.valid <= 1'b0;
                end 
                else if (load_use_hazard) begin //If hazard, load NOP into EX stage
                    id_ex.valid <= 1'b0;
                end 
                else begin
                    id_ex.valid <= if_id.valid && dec_ctrl.legal; //If instruction is real and decoder says legal, then send to EX
                    id_ex.pc <= if_id.pc;
                    id_ex.pc4 <= if_id.pc4;
                    id_ex.instr <= if_id.instr;
                    id_ex.rs1 <= dec_rs1;
                    id_ex.rs2 <= dec_rs2;
                    id_ex.rd <= dec_rd;
                    id_ex.rs1_value <= dec_rs1_value;
                    id_ex.rs2_value <= dec_rs2_value;
                    id_ex.imm <= dec_imm;
                    id_ex.ctrl <= dec_ctrl;

                    if (imem_ready) begin //Fetch next instruction
                        if_id.valid <= 1'b1;
                        if_id.pc <= pc;
                        if_id.pc4 <= pc + 32'd4;
                        if_id.instr <= imem_rdata;
                        pc <= pc + 32'd4; //Advance PC by 4 bytes
                    end 
                    else begin
                        if_id.valid <= 1'b0; //If instruction memory did not respond, no new instructions will be added
                    end
                end
            end
        end
    end
endmodule
