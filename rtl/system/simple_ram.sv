module simple_ram #(
    //Contains both the CPU program and program data
    parameter integer WORDS = 4096, //Number of 32 bit words available, 4096 * 4bytes = 16384 = 16KiB
    parameter INIT_FILE = "tests/generated/blink.hex" //The program loaded into memory
    //These params can be overwritten at instantiation
) (
    input logic clk,
    input logic reset,

    //Instruction memory ports
    input logic imem_valid, //CPU reqs instruction
    input logic [31:0] imem_addr, //Address from PC
    output logic imem_ready, //RAM finished request
    output logic [31:0] imem_rdata, //encoded instruction to CPU

    //Data memory
    input logic dmem_valid, //CPU requesting data
    input logic dmem_write, //1=store, 0 = load
    input logic [3:0] dmem_wstrb, //Which byte lanes are written
    input logic [31:0] dmem_addr, //Memory address 
    input logic [31:0] dmem_wdata, //Value to be stored
    output logic dmem_ready, //Req is completed
    output logic [31:0] dmem_rdata //Value loaded

);
    localparam integer ADDR_WIDTH = $clog2(WORDS); //ADDR_WIDTH = log2(4096) = 12, so for 4096 words, we need 12 bits to represents them

    logic [31:0] memory [0:WORDS-1]; //4096 WORDS, each 32 bit long
    //1 cycle response for requests/reponses
    logic imem_pending;
    logic dmem_pending;

    initial begin
        $readmemh(INIT_FILE, memory); //Loads the program over beginning of memory, starting at memory[0]
    end

    //At the clock edge, memory is received or written, and is ready to use
    assign imem_ready = imem_pending;
    assign dmem_ready = dmem_pending;

    always_ff @(posedge clk) begin

        if(reset)begin
            imem_pending <= 1'b0;
            dmem_pending <= 1'b0;
            imem_rdata <= 32'h0000_0013;
            dmem_rdata <= 32'b0;
        end
        else begin
            //Instruction memory
            if(imem_pending)begin //If response is ready, then consume during this edge
                imem_pending <= 1'b0;
            end
            else if(imem_valid)begin //Get new instruction
                imem_rdata <= memory[imem_addr[ADDR_WIDTH+1:2]]; //Get address from hex form into indices, ie 0x0000_0000 = 0, 0x0000_0004 = index 1, etc. The LS 2 bits are not needed
                imem_pending <= 1'b1; //Imem_ready becomes 1 at next cycle
            end

            //Data memory
            if(dmem_pending) begin //Clear completed response or accept new request
                dmem_pending <= 1'b0;
            end
            else if(dmem_valid)begin
                dmem_rdata <= memory[dmem_addr[ADDR_WIDTH+1:2]]; //Read the value at address, used in loads. Ignored in writes
                if(dmem_write)begin
                    //Depending on the strobe, write to the 4 byte lanes. These values will match the wdata
                    //e.g For full words, strobe will be 1111, therefore writing to all four bytes
                    if (dmem_wstrb[0]) memory[dmem_addr[ADDR_WIDTH+1:2]][7:0] <= dmem_wdata[7:0];
                    if (dmem_wstrb[1]) memory[dmem_addr[ADDR_WIDTH+1:2]][15:8] <= dmem_wdata[15:8];
                    if (dmem_wstrb[2]) memory[dmem_addr[ADDR_WIDTH+1:2]][23:16] <= dmem_wdata[23:16];
                    if (dmem_wstrb[3]) memory[dmem_addr[ADDR_WIDTH+1:2]][31:24] <= dmem_wdata[31:24];
                end
                dmem_pending <= 1'b1; //Complete request
            end
        end 
    end
endmodule
