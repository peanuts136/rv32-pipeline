//Ensures that the reset is synched with the clock on startup
module reset_sync(
    input logic clk, //synched with the 12Mhz clock on physical board
    input logic button_n, //active low button input
    output logic reset //Active high reset for CPU, RAM, GPIO
);
    logic [3:0] release_pipe = 4'b0000; //Declares 4 bits to be set to 0

    //At startup or button press, the system is fully reset with all four bits being set to 0
    //Each positive clock edge acts as increment
    always_ff @(posedge clk or negedge button_n) begin
        if(!button_n) release_pipe <= 4'b0000;
        //Full cycle: 0000->0001->0011->0111->1111, reset is lifted in 4 clock cycles
        else release_pipe <= {release_pipe[2:0], 1'b1}; //Take the lower 3 bit and append bit 1 to the right

    end

    //This is the only bit that is read, since it is active high, must inverse it such that bit 1111-> release_pipe[3] = 1-> reset=0
    assign reset = !release_pipe[3];


endmodule