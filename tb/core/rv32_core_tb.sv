module rv32_core_tb;

    //Begin with fresh signals
    logic clk = 0;
    logic reset = 1;
    logic imem_valid, imem_ready;
    logic [31:0] imem_addr, imem_rdata;
    logic dmem_valid, dmem_write, dmem_ready;
    logic [3:0] dmem_wstrb;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic retire_valid;
    logic [31:0] retire_pc, retire_instr, retire_rd_value;
    logic [4:0] retire_rd;
    //Simulated memories = 64 * 4 = 256 bytes
    logic [31:0] imem [0:63];
    logic [31:0] dmem [0:63];
    integer cycles;

    //CPU Instance, device under test
    rv32_core dut (.*);

    //Clock will change every #N time units
    always #5 clk = ~clk;

    //Optional waveform trace
    initial begin
        if ($test$plusargs("trace")) begin
        $dumpfile("build/core/rv32_core.vcd");
        $dumpvars(0, rv32_core_tb);
        end
    end

    //Functions to make testing simplified
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


    always_comb begin
        imem_ready = imem_valid; //Whenever CPU requests instruction, testbench will respond with ready = 1
        imem_rdata = imem[imem_addr[7:2]]; //Byte address is converted into word index, e.g 4->1, 8->2
        dmem_ready = dmem_valid; //Load and store the memory instantly
        dmem_rdata = dmem[dmem_addr[7:2]];
    end

    always_ff @(posedge clk) begin
        if (dmem_valid && dmem_write) begin //Memory is modified for valid store
        //Strobe allows for byte, halfword, word stores
        if (dmem_wstrb[0]) dmem[dmem_addr[7:2]][7:0]   <= dmem_wdata[7:0];
        if (dmem_wstrb[1]) dmem[dmem_addr[7:2]][15:8]  <= dmem_wdata[15:8];
        if (dmem_wstrb[2]) dmem[dmem_addr[7:2]][23:16] <= dmem_wdata[23:16];
        if (dmem_wstrb[3]) dmem[dmem_addr[7:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    initial begin
        for (integer n = 0; n < 64; n++) begin
            imem[n] = 32'h0000_0013;
            dmem[n] = 32'b0;
        end


        imem[0] = enc_i(5, 0, 0, 1, 7'h13); //addi x1,x0,5
        imem[1] = enc_i(7, 0, 0, 2, 7'h13); //addi x2,x0,7
        imem[2] = enc_r(0, 2, 1, 0, 3, 7'h33); //add x3,x1,x2 | x2 will be dependent, tests forwarding
        imem[3] = enc_s(0, 3, 0, 2, 7'h23); //sw x3,0(x0) | Stores recent result, tests strobes and forwarding
        imem[4] = enc_i(0, 0, 2, 4, 7'h03); //lw x4,0(x0) 
        imem[5] = enc_r(0, 1, 4, 0, 5, 7'h33); //add x5,x4,x1 | Detects add needs x4, holds add in ID and insert NOP, forward when available
        imem[6] = enc_b(8, 5, 5, 0, 7'h63); //beq x5,x5,+8 | branch should be taken, should jump to imem[8]
        imem[7] = enc_i(99, 0, 0, 6, 7'h13); //flushed b/c branch
        imem[8] = enc_j(8, 7, 7'h6f); //jal x7,+8 | should jump to imem[10]
        imem[9] = enc_i(88, 0, 0, 8, 7'h13); //flushed
        imem[10] = enc_i(1, 0, 0, 9, 7'h13); //addi x9,x0,1 
        imem[11] = enc_u(20'h12345, 10, 7'h37); //lui x10,0x12345 | tests for reg writeback
        imem[12] = enc_u(20'h00001, 11, 7'h17); //auipc x11,0x1 | tests PC current at 0x30 + 0x1000 = 0x1030

        //Resets
        repeat (3) @(posedge clk);
        reset <= 0;
        cycles = 0;
        while (cycles < 80 && dut.regs[11] != 32'h0000_1030) begin
        @(posedge clk);
        cycles++;
        end
        @(negedge clk);
        if (dmem[0] !== 12) $fatal(1, "store/forwarding failed: dmem[0]=%0d", dmem[0]);
        if (dut.regs[4] !== 12) $fatal(1, "load failed: x4=%0d", dut.regs[4]);
        if (dut.regs[5] !== 17) $fatal(1, "load-use failed: x5=%0d", dut.regs[5]);
        if (dut.regs[6] !== 0) $fatal(1, "branch flush failed: x6=%0d", dut.regs[6]);
        if (dut.regs[7] !== 36) $fatal(1, "JAL link failed: x7=%0d", dut.regs[7]);
        if (dut.regs[8] !== 0) $fatal(1, "JAL flush failed: x8=%0d", dut.regs[8]);
        if (dut.regs[9] !== 1) $fatal(1, "target instruction missing");
        if (dut.regs[10] !== 32'h1234_5000) $fatal(1, "LUI failed: x10=%h", dut.regs[10]);
        if (dut.regs[11] !== 32'h0000_1030) $fatal(1, "AUIPC failed: x11=%h", dut.regs[11]);
        $display("PASS: pipeline core completed directed test in %0d cycles", cycles);
        $finish;
    end
endmodule


