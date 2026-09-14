`timescale 1ns/1ps //1ns time unit with 1ps precision

module cpu_soc_tb;
    //Initial signals
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic gpio_out; //Connects to SoC with GPIO
    //For debugs
    integer cycles;
    integer transitions;
    logic previous_gpio; //Used to see transitions from 0->1 and 1->0

    cpu_soc #( //CPU SoC instance
        .RAM_WORDS(4096),
        .MEM_FILE("tests/generated/blink_sim.hex") //Use simulated version of program with much less delay
    )
    dut( //Connect the ports
        .clk,
        .reset,
        .gpio_out
    );

    always #5 clk = ~clk; //Toggle clock every 10ns

    //Optional waveform trace file generation
    initial begin
        if ($test$plusargs("trace")) begin
            $dumpfile("build/phase3_sim/cpu_soc.vcd");
            $dumpvars(0, cpu_soc_tb); //All signals through SoC
        end
    end

    //Begin time 0
    initial begin
        repeat (4) @(posedge clk); //Wait for 4 rising clock edges
        reset <= 1'b0; //Then begin executing
        cycles = 0;
        transitions = 0;
        previous_gpio = gpio_out;

        while (cycles < 1000 && transitions < 4) begin //Should be done in fewer than arbitrary 1000 cycles which elsewise, likely indicates an error
            @(negedge clk); cycles++;

            if(gpio_out != previous_gpio) begin //The GPIO changes state 
                transitions++;
                previous_gpio = gpio_out;
            end
        end

        if (transitions < 4) $fatal(1, "GPIO did not toggle four times: toggles found=%0d", transitions);

        $display("Pass: SoC program toggled GPIO four times in %0d, cycles", cycles);
        $finish;
    end
endmodule

