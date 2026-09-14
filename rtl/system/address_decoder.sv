module address_decoder #(
    //0x0000_0000 - 0x0000_3FFF = 16 KiB RAM = 16384 bytes          
    //0x1000_0000 - 0x1000_0003 -> GPIO register
    parameter logic [31:0] RAM_BYTES = 32'd16384,
    parameter logic [31:0] GPIO_ADDR = 32'h1000_0000
) (
    input logic [31:0] addr,
    output logic ram_select,
    output logic gpio_select
);   
    //If less than the max RAM_BYTES, then the address must be selected in RAM
    //GPIO select will ignore the LSB
    assign ram_select = (addr < RAM_BYTES); 
    assign gpio_select = (addr[31:2] == GPIO_ADDR[31:2]);

endmodule