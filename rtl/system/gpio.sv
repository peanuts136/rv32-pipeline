//Overall process: a 0x00000001 value will be written to address 0x10000000 on the dmem, which will be decoded as GPIO
//gpio_out <= wdata[0] which is 0x00000001,  this will be sent to the lattice


module gpio(
    input logic clk,
    input logic reset,
    input logic valid, //Should only assert this when CPU chooses the GPIO address
    input logic write, //1=store, 0=load
    input logic [3:0] wstrb, //Indicates which byte lane will be used, 0=7:0, 3=31:24
    input logic [31:0] wdata,

    output logic ready, //Tells CPU that GPIO is ready
    output logic [31:0] rdata, //Return GPIO state when software reads GPIO address
    output logic gpio_out //Physical state

);
    assign ready = valid; 
    assign rdata = {31'b0, gpio_out}; //Used for load data, input on GPIO, not yet implemented, could use button

    always_ff @(posedge clk) begin
        if (reset) gpio_out <= 1'b0;
        else if (valid && write && wstrb[0]) gpio_out <= wdata[0]; //only changes when all conditions are true
    end



endmodule
