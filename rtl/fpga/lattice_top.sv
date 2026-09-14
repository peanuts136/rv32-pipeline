//Connects the internal SoC to the physical clock, buttons, and LED pins
module lattice_top (
    input logic clk_12mhz, //The clock supplied by physical board 

    //These signals are active low
    input logic button_n, //Signal from push button
    output logic [7:0] led_n //Signal from board's eight pins
);
    logic reset; //Connects the reset_sync module to SoC
    logic gpio_out; //Connects the LED outputt o SoC


    //Instances of reset sync and SoC
    reset_sync reset_conditioner (
        .clk(clk_12mhz),
        .button_n,
        .reset
    );

    cpu_soc soc (
        .clk(clk_12mhz),
        .reset,
        .gpio_out
    );
    
    assign led_n = {7'b1111111, ~gpio_out}; //LEDs 1-7 are active low, they are also not used
    //LED 0 is the inverse of gpio_out, the inverse makes convention easier
    //LED 1 is the independent clock heartbeat for testing purposes
endmodule