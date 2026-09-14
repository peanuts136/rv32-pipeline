//System module that connects the CPU core to the RAM, decoder, and GPIO
module cpu_soc #(
    //System configs
    parameter integer RAM_WORDS = 4096, //Words able used by RAM
    parameter MEM_FILE = "tests/generated/blink.hex", //Program loaded to RAM
    parameter logic [31:0] GPIO_ADDR = 32'h1000_0000 //Default address for GPIO
) ( 
    //Ports
    input logic clk,
    input logic reset,
    output logic gpio_out
);
    localparam logic [31:0] RAM_BYTES = RAM_WORDS * 4;
    
    //Connects to the RAM
    logic imem_valid;
    logic imem_ready;
    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;

    //Connects to the RAM and GPIO
    logic dmem_valid;
    logic dmem_write;
    logic dmem_ready;
    logic [3:0] dmem_wstrb;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_rdata;
    logic [31:0] dmem_wdata;

    logic ram_select;
    logic gpio_select;
    logic ram_dmem_ready;
    logic gpio_ready;
    logic [31:0] ram_dmem_rdata;
    logic [31:0] gpio_rdata;

    //used for debugs
    logic retire_valid;
    logic [4:0] retire_rd;
    logic [31:0] retire_pc;
    logic [31:0] retire_instr;
    logic [31:0] retire_rd_value;

    //Instantiating the components
    //For these signals requests, all will be broadcast according to their intended recipients
    //Such as for RAM, the RAM's dmem_valid is only true if the broadcasted dmem_valid AND ram_select is true on this clock cycle
    //For the reponse signals, must instead multiplex using if statements and determine which response is sent back.
    rv32_core core (
    //Connects data from core to SoC
    //Same name will automatically connect to same name ports
    .clk, .reset,
    .imem_valid, .imem_addr, .imem_ready, .imem_rdata,
    .dmem_valid, .dmem_write, .dmem_wstrb, .dmem_addr, .dmem_wdata, .dmem_ready, .dmem_rdata,
    .retire_valid, .retire_pc, .retire_instr, .retire_rd, .retire_rd_value
    );

    simple_ram #(
        .WORDS(RAM_WORDS), .INIT_FILE(MEM_FILE) //Override defaults
    ) ram (
        .clk, .reset,
        .imem_valid, .imem_addr, .imem_ready, .imem_rdata, //Instruction ports
        .dmem_valid(dmem_valid && ram_select), //This is a RAM data request, only if address belongs to RAM and is a valid request
        .dmem_write, .dmem_wstrb, .dmem_addr, .dmem_wdata, //Data ports
        .dmem_ready(ram_dmem_ready),
        .dmem_rdata(ram_dmem_rdata)
    );

    address_decoder #(
        .RAM_BYTES(RAM_BYTES), .GPIO_ADDR(GPIO_ADDR) //Override defaults
    ) decoder (
        .addr(dmem_addr), //Decoder examples the address generated from CPU
        .ram_select,
        .gpio_select
    );

    gpio gpio_peripheral (
        .clk, .reset,
        .valid(dmem_valid && gpio_select), //Only valid when data memory request is valid and belongs to GPIO
        .write(dmem_write), .wstrb(dmem_wstrb), .wdata(dmem_wdata), //For GPIO writing
        .ready(gpio_ready), .rdata(gpio_rdata), .gpio_out //GPIO responses
    );

    //These are the responses from either the RAM or GPIO, must differentiate to send back to the Core
    always_comb begin
        //Default values, for invalid accesses, return a 0 for dmem reads
        dmem_ready = dmem_valid;
        dmem_rdata = 32'b0;
        //If value belongs to RAM, return RAM response, else if return GPIO
        //Process example: dmem_addr = 0x0100, ram_select= 1, RAM receives dmem_valid, RAM returns ram_dmem_rdata, SoC copies into dmem_rdata, CPU receives loaded value
        if (ram_select)begin
            dmem_ready = ram_dmem_ready;
            dmem_rdata = ram_dmem_rdata;
        end
        else if (gpio_select) begin
            dmem_ready = gpio_ready;
            dmem_rdata = gpio_rdata;
        end
    end
endmodule

