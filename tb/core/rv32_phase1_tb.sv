`timescale 1ns/1ps //Defines a timescale with each timeunit being roughly 1 ns with a precision of 1 ps

module rv32_phase1_tb;
    //Begin with fresh signals
    logic clk = 1'b0;
    logic reset = 1'b1;

    logic imem_valid, imem_ready;
    logic [31:0] imem_addr, imem_rdata;
    logic dmem_valid, dmem_write, dmem_ready;
    logic [3:0] dmem_wstrb;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic retire_valid;
    logic [31:0] retire_pc, retire_instr, retire_rd_value;
    logic [4:0] retire_rd;

    //Simulated Memories, 4*256=1024 bytes
    logic [31:0] imem [0:255];
    logic [31:0] dmem [0:255];

    logic imem_phase; //Delays first instruction fetch
    logic dmem_pending; //Remembers active data request
    logic [2:0] dmem_wait; //Countdown for memory access as it should be relatively slow, such as during memory stalls or cache miss etc
    logic [31:0] pending_addr, pending_wdata;
    logic [3:0] pending_wstrb;
    logic pending_write;

    //Testbench variables
    integer p;
    integer cycles;
    integer imem_stall_cycles;
    integer dmem_stall_cycles;
    integer load_use_cycles;
    integer jal_link_expected;
    integer jalr_link_expected;

    rv32_core dut (.*); //Instance of core 
    always #5 clk = ~clk; //Around 5 ns per clock cycle

    //Optional waveform trace
    initial begin
        if ($test$plusargs("trace")) begin
        $dumpfile("build/phase1/rv32_phase1.vcd");
        $dumpvars(0, rv32_phase1_tb);
        end
    end

    //Functions to make testing encodings simplified
    function automatic [31:0] enc_i(input integer imm, input integer rs1, input integer funct3, input integer rd, input integer opcode);
        enc_i = {imm[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] enc_r(input integer funct7, input integer rs2, input integer rs1, input integer funct3, input integer rd, input integer opcode);
        enc_r = {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] enc_s(input integer imm, input integer rs2, input integer rs1, input integer funct3, input integer opcode);
        enc_s = {imm[11:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] enc_b(input integer imm, input integer rs2, input integer rs1, input integer funct3, input integer opcode);
        enc_b = {imm[12], imm[10:5], rs2[4:0], rs1[4:0], funct3[2:0], imm[4:1], imm[11], opcode[6:0]};
    endfunction
    function automatic [31:0] enc_j(input integer imm, input integer rd, input integer opcode);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd[4:0], opcode[6:0]};
    endfunction
    function automatic [31:0] enc_u(input integer imm20, input integer rd, input integer opcode);
        enc_u = {imm20[19:0], rd[4:0], opcode[6:0]};
    endfunction

    //Places an instruction at next instruction memory location, increments PC
    task automatic emit(input logic [31:0] instruction);
        imem[p] = instruction;
        p = p + 1;
    endtask

    //Expected branch taken helper
    task automatic branch_taken(input integer rs1, input integer rs2,
        input integer funct3);
        emit(enc_b(8, rs2, rs1, funct3, 7'h63));
        emit(enc_i(1, 30, 0, 30, 7'h13));
    endtask

    //Expected not taken branch, if incorrectly taken should on failure instruction
    task automatic branch_not_taken(input integer rs1, input integer rs2,
        input integer funct3);
        emit(enc_b(8, rs2, rs1, funct3, 7'h63));
        emit(enc_j(8, 0, 7'h6f));
        emit(enc_i(1, 30, 0, 30, 7'h13));
    endtask

    //Clear imem and dmem
    task automatic clear_memories;
        for (integer n = 0; n < 256; n++) begin
            imem[n] = 32'h0000_0013;
            dmem[n] = 32'b0;
        end
    endtask

    //Resets for 3 clock cycles to ensure proper reset
    task automatic reset_core;
        @(negedge clk);
        reset = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
    endtask

    //Test to write distinct value for the registers
    task automatic wait_for_x31(input logic [31:0] expected, input integer limit);
        cycles = 0;
        while (cycles < limit && dut.regs[31] !== expected) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(negedge clk);
        if (dut.regs[31] !== expected)
            $fatal(1, "timeout after %0d cycles; x31=%h expected=%h", cycles, dut.regs[31], expected);
    endtask

    //CPU will delay the first fetch by 1 cycle after a reset
    always_ff @(posedge clk) begin
        if (reset)
        imem_phase <= 1'b0;
        else
        imem_phase <= 1'b1;
    end
    assign imem_ready = imem_valid && imem_phase;
    assign imem_rdata = imem[imem_addr[9:2]]; //Conversts byte address into word index

    //Memory should respond when request is pending and countdown reaches 0
    assign dmem_ready = dmem_pending && (dmem_wait == 0);
    assign dmem_rdata = dmem[pending_addr[9:2]];

    always_ff @(posedge clk) begin
        if (reset) begin
            //Reset memory transaction states
            dmem_pending <= 1'b0;
            dmem_wait <= '0;
            pending_addr  <= '0;
            pending_wdata <= '0;
            pending_wstrb <= '0;
            pending_write <= 1'b0;
        end else begin
        if (!dmem_pending && dmem_valid) begin //If CPU issues data request, testbench saves the data
            dmem_pending <= 1'b1;
            dmem_wait <= 2; //Countdown with 2 cycles
            pending_addr <= dmem_addr;
            pending_wdata <= dmem_wdata;
            pending_wstrb <= dmem_wstrb;
            pending_write <= dmem_write;
        end else if (dmem_pending && dmem_wait != 0) begin
            dmem_wait <= dmem_wait - 1'b1; //The countdown will subtract 1 from itself each cycle
        end else if (dmem_pending) begin
            if (pending_write) begin //If the data request was a write, then the strobe should handle it and be recorded
                if (pending_wstrb[0]) dmem[pending_addr[9:2]][7:0] <= pending_wdata[7:0];
                if (pending_wstrb[1]) dmem[pending_addr[9:2]][15:8] <= pending_wdata[15:8];
                if (pending_wstrb[2]) dmem[pending_addr[9:2]][23:16] <= pending_wdata[23:16];
                if (pending_wstrb[3]) dmem[pending_addr[9:2]][31:24] <= pending_wdata[31:24];
            end
            dmem_pending <= 1'b0; //No longer pending
        end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            imem_stall_cycles <= 0;
            dmem_stall_cycles <= 0;
            load_use_cycles <= 0;
        end else begin
        if (imem_valid && !imem_ready) imem_stall_cycles <= imem_stall_cycles + 1; //Count the number of instruction stall cycles
        if (dut.memory_stall) dmem_stall_cycles <= dmem_stall_cycles + 1; //Count the number for data pipeline stalls cycles
        if (dut.load_use_hazard) load_use_cycles <= load_use_cycles + 1; //Count the number of load use stall cycles
        end
    end

    initial begin

        //Test 1: complete ALU group, immediates, forwarding, LUI, and AUIPC
        clear_memories();
        p = 0;
        emit(enc_i(10, 0, 0, 1, 7'h13)); //x1 = 10
        emit(enc_i(-3, 0, 0, 2, 7'h13)); //x2 = -3
        emit(enc_r(0, 2, 1, 0, 3, 7'h33)); //x3 = 7 | Also tests for forwarding using x1 and x2
        emit(enc_r(7'h20, 2, 1, 0, 4, 7'h33)); //x4 = 13 | Also tests for forwarding using x1 and x2
        emit(enc_r(0, 2, 1, 7, 5, 7'h33)); //x5 = x1 & x2 = 8
        emit(enc_r(0, 2, 1, 6, 6, 7'h33)); //x6 = x1 | x2 = -1
        emit(enc_r(0, 2, 1, 4, 7, 7'h33)); //x7 = x1 ^ x2
        emit(enc_r(0, 2, 1, 2, 8, 7'h33)); //signed 10 < -3 = 0
        emit(enc_r(0, 2, 1, 3, 9, 7'h33)); //unsigned 10 < x2 = 1
        emit(enc_i(2, 0, 0, 11, 7'h13)); //x11 = 2
        emit(enc_r(0, 11, 1, 1, 10, 7'h33)); //x10 = 10 << 2 = 40
        emit(enc_r(0, 11, 2, 5, 12, 7'h33)); //x12 = logical(-3 >> 2)
        emit(enc_r(7'h20, 11, 2, 5, 13, 7'h33)); //x13 = arithmetic(-3 >> 2)
        emit(enc_i(-5, 1, 0, 14, 7'h13)); //x14 = 5
        emit(enc_i(0, 2, 2, 15, 7'h13)); //x15 = (-3 < 0) = 1
        emit(enc_i(1, 2, 3, 16, 7'h13)); //x16 = unsigned(x2 < 1) = 0
        emit(enc_i(15, 1, 4, 17, 7'h13)); //x17 = 10 ^ 15 = 5
        emit(enc_i(16'h055, 0, 6, 18, 7'h13)); //x18 = 0x55
        emit(enc_i(15, 2, 7, 19, 7'h13)); //x19 = 0xD
        emit(enc_i(2, 1, 1, 20, 7'h13)); //SLLI x20,x1,2 = 40
        emit(enc_i(2, 2, 5, 21, 7'h13)); //SRLI x21,x2,2
        emit(enc_i(12'h402, 2, 5, 22, 7'h13)); // RAI x22,x2,2
        emit(enc_u(20'h12345, 23, 7'h37)); //LUI
        emit(enc_u(20'h00001, 24, 7'h17)); //AUIPC, expected PC=0x5C + 0x1000 = 0x105C
        emit(enc_i(1, 0, 0, 31, 7'h13)); //Complete at reg 31

        reset_core();
        wait_for_x31(1, 300); //Wait for reg 31 to be 1, signaling test completion
        if (dut.regs[3]  !== 32'd7) $fatal(1, "ADD failed");
        if (dut.regs[4]  !== 32'd13) $fatal(1, "SUB failed");
        if (dut.regs[5]  !== 32'd8) $fatal(1, "AND failed");
        if (dut.regs[6]  !== 32'hffff_ffff) $fatal(1, "OR failed");
        if (dut.regs[7]  !== 32'hffff_fff7) $fatal(1, "XOR failed");
        if (dut.regs[8]  !== 0) $fatal(1, "SLT failed");
        if (dut.regs[9]  !== 1) $fatal(1, "SLTU failed");
        if (dut.regs[10] !== 40) $fatal(1, "SLL failed");
        if (dut.regs[12] !== 32'h3fff_ffff) $fatal(1, "SRL failed");
        if (dut.regs[13] !== 32'hffff_ffff) $fatal(1, "SRA failed");
        if (dut.regs[14] !== 5) $fatal(1, "ADDI failed");
        if (dut.regs[15] !== 1) $fatal(1, "SLTI failed");
        if (dut.regs[16] !== 0) $fatal(1, "SLTIU failed");
        if (dut.regs[17] !== 5) $fatal(1, "XORI failed");
        if (dut.regs[18] !== 32'h55) $fatal(1, "ORI failed");
        if (dut.regs[19] !== 32'hd) $fatal(1, "ANDI failed");
        if (dut.regs[20] !== 40) $fatal(1, "SLLI failed");
        if (dut.regs[21] !== 32'h3fff_ffff) $fatal(1, "SRLI failed");
        if (dut.regs[22] !== 32'hffff_ffff) $fatal(1, "SRAI failed");
        if (dut.regs[23] !== 32'h1234_5000) $fatal(1, "LUI failed");
        if (dut.regs[24] !== 32'h0000_105c) $fatal(1, "AUIPC failed: %h", dut.regs[24]);
        if (imem_stall_cycles == 0) $fatal(1, "instruction stalls were not exercised"); //Tests for instruction waiting actually occured
        $display("PASS 1/3: ALU, immediates, forwarding, LUI/AUIPC");


        //Test 2: byte/halfword/word stores and loads, delayed memory, load-use stall.

        clear_memories();
        p = 0;
        emit(enc_i(128, 0, 0, 1, 7'h13)); //The dmem starting address
        emit(enc_i(16'h0aa, 0, 0, 2, 7'h13));//0xAA, ready
        emit(enc_s(0, 2, 1, 0, 7'h23)); //SB [128] = AA
        emit(enc_i(16'h0bb, 0, 0, 3, 7'h13)); //0xBB, ready
        emit(enc_s(1, 3, 1, 0, 7'h23)); //SB [129] = BB
        emit(enc_i(16'h123, 0, 0, 4, 7'h13)); //0x0123
        emit(enc_s(2, 4, 1, 1, 7'h23)); //SH [130] = 0123 | The complete 32 bit word 01 23 BB AA
        emit(enc_i(0, 1, 0, 5, 7'h03)); //LB = FFFFFFAA | loads x5 <= x1=AA, sign extended
        emit(enc_i(0, 1, 4, 6, 7'h03)); //LBU = 000000AA | Same thing unsigned
        emit(enc_i(2, 1, 1, 7, 7'h03)); //LH = 00000123 | halfword check
        emit(enc_i(2, 1, 5, 8, 7'h03)); //LHU = 00000123
        emit(enc_i(0, 1, 2, 9, 7'h03)); //LW = 0123BBAA | entire word check
        emit(enc_i(1, 9, 0, 10, 7'h13)); //load use hazard: x10=x9+1, should detect that x10 depends on the unfinished x9 load
        emit(enc_i(77, 0, 0, 11, 7'h13)); //Testing for forwarding
        emit(enc_s(4, 11, 1, 2, 7'h23)); //SW [132] = 77, should receive forwarded value from previous instruction
        emit(enc_i(4, 1, 2, 12, 7'h03)); //LW x12,[132]
        emit(enc_i(2, 0, 0, 31, 7'h13)); // Completed

        reset_core();
        wait_for_x31(2, 300);
        if (dmem[32]     !== 32'h0123_bbaa) $fatal(1, "SB/SHW strobes failed: %h", dmem[32]);
        if (dut.regs[5]  !== 32'hffff_ffaa) $fatal(1, "LB failed");
        if (dut.regs[6]  !== 32'h0000_00aa) $fatal(1, "LBU failed");
        if (dut.regs[7]  !== 32'h0000_0123) $fatal(1, "LH failed");
        if (dut.regs[8]  !== 32'h0000_0123) $fatal(1, "LHU failed");
        if (dut.regs[9]  !== 32'h0123_bbaa) $fatal(1, "LW failed");
        if (dut.regs[10] !== 32'h0123_bbab) $fatal(1, "Load use hazard result failed");
        if (dut.regs[12] !== 77)            $fatal(1, "Store forwarding failed");
        if (dmem_stall_cycles == 0)         $fatal(1, "Dmem stalls were not used");
        if (load_use_cycles == 0)           $fatal(1, "Load use hazard was not used");
        $display("PASS 2/3: loads/stores, strobes, memory stalls, load use hazards");


        //Test 3: every branch condition, taken/not-taken, JAL, and JALR.
        //x30 is a failure counter and must remain zero.
        clear_memories();
        p = 0;
        emit(enc_i(1, 0, 0, 1, 7'h13)); //x1=1
        emit(enc_i(1, 0, 0, 2, 7'h13)); //x2=1
        emit(enc_i(2, 0, 0, 3, 7'h13)); //x3=2
        emit(enc_i(-1, 0, 0, 4, 7'h13)); //x4=-1 / max unsigned
        emit(enc_i(0, 0, 0, 30, 7'h13)); //If any branch behaves incorrectly, x30 should increment
        branch_taken(1, 2, 3'b000); //BEQ taken
        branch_not_taken(1, 3, 3'b000); //BEQ not taken
        branch_taken(1, 3, 3'b001); //BNE taken
        branch_not_taken(1, 2, 3'b001); //BNE not taken
        branch_taken(4, 1, 3'b100); //BLT signed taken
        branch_not_taken(3, 1, 3'b100); //BLT signed not taken
        branch_taken(3, 1, 3'b101); //BGE signed taken
        branch_not_taken(4, 1, 3'b101); //BGE signed not taken
        branch_taken(1, 4, 3'b110); //BLTU taken
        branch_not_taken(4, 1, 3'b110); //BLTU not taken
        branch_taken(4, 1, 3'b111); //BGEU taken
        branch_not_taken(1, 4, 3'b111); //BGEU not taken

        jal_link_expected = p * 4 + 4; //The expected link is PC + 4
        emit(enc_j(8, 20, 7'h6f)); // JAL x20,+8 | writes PC + 4 into x20 and jump by 8 bytes
        emit(enc_i(1, 30, 0, 30, 7'h13)); //Flush failure

        //Target is three instructions after this ADDI: ADDI, JALR, fail, target.
        emit(enc_i((p + 3) * 4, 0, 0, 5, 7'h13));
        jalr_link_expected = p * 4 + 4;
        emit(enc_i(0, 5, 0, 21, 7'h67)); //JALR x21,0(x5)
        emit(enc_i(1, 30, 0, 30, 7'h13)); //must be flushed
        emit(enc_i(3, 0, 0, 31, 7'h13)); //Complete

        reset_core();
        wait_for_x31(3, 300);
        if (dut.regs[30] !== 0) $fatal(1, "branch/jump failure count=%0d", dut.regs[30]);
        if (dut.regs[20] !== jal_link_expected) $fatal(1, "JAL link failed: got=%h expected=%h", dut.regs[20], jal_link_expected);
        if (dut.regs[21] !== jalr_link_expected) $fatal(1, "JALR link failed: got=%h expected=%h", dut.regs[21], jalr_link_expected);
        $display("PASS 3/3: branches taken/not-taken, JAL, JALR");
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
