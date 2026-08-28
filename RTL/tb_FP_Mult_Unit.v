// ============================================================================
// Module: tb_FP_Mult_Unit
// Description: Self-checking pipelined testbench for FP_Mult_Unit.v.
//              Implements a stress test feeding a new multiplication every 
//              clock cycle and checking the output with a 3-cycle pipeline delay.
//
// Formats Tested: Q1.15 (sfixed 16 bits: 1 sign, 15 fraction bits)
// Latency: 3 clock cycles
// ============================================================================

`timescale 1ns / 1ps

module tb_FP_Mult_Unit;

    // Simulation Parameters
    localparam WIDTH  = 16;
    localparam FRAC   = 15;
    localparam ROUNDING = 1;

    // Inputs to UUT
    reg                 clk;
    reg                 rst;
    reg  signed [WIDTH-1:0] tb_in_A;
    reg  signed [WIDTH-1:0] tb_in_B;

    // Outputs from UUT
    wire signed [WIDTH-1:0] tb_out_Y;

    // Stats Counters
    integer total_tests   = 0;
    integer success_count = 0;
    integer fail_count    = 0;

    // Instantiate Unit Under Test (UUT)
    FP_Mult_Unit #(
        .WIDTH_A(WIDTH),
        .FRAC_A(FRAC),
        .WIDTH_B(WIDTH),
        .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH),
        .FRAC_Y(FRAC),
        .ROUNDING(ROUNDING)
    ) uut (
        .clk(clk),
        .rst(rst),
        .in_A(tb_in_A),
        .in_B(tb_in_B),
        .out_Y(tb_out_Y)
    );

    // Clock Generator (50 MHz => 20ns period)
    always #10 clk = ~clk;

    // ------------------------------------------------------------------------
    // Pipelined Expected Value Logic
    // Since the multiplier has a latency of 3 clock cycles, we must delay the
    // expected check value by exactly 3 clock edges.
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] next_expected;
    reg                    next_valid;

    reg signed [WIDTH-1:0] exp_pipeline [0:2];
    reg                    valid_pipeline [0:2];

    always @(posedge clk) begin
        if (rst) begin
            exp_pipeline[0]   <= 0;
            exp_pipeline[1]   <= 0;
            exp_pipeline[2]   <= 0;
            valid_pipeline[0] <= 0;
            valid_pipeline[1] <= 0;
            valid_pipeline[2] <= 0;
        end else begin
            // Shift the pipeline
            exp_pipeline[0]   <= next_expected;
            exp_pipeline[1]   <= exp_pipeline[0];
            exp_pipeline[2]   <= exp_pipeline[1]; // Out of pipeline (after 3 edges)

            valid_pipeline[0] <= next_valid;
            valid_pipeline[1] <= valid_pipeline[0];
            valid_pipeline[2] <= valid_pipeline[1]; // Valid trigger
        end
    end

    // ------------------------------------------------------------------------
    // Dynamic Expected Value Generator Task
    // Receives two 16-bit inputs and computes the expected Q1.15 product 
    // with rounding and saturation. This output will feed the expected queue.
    // ------------------------------------------------------------------------
    task calc_expected;
        input  signed [WIDTH-1:0] a;
        input  signed [WIDTH-1:0] b;
        output signed [WIDTH-1:0] y_expected;
        reg    signed [2*WIDTH-1:0] raw_prod;
        reg    signed [2*WIDTH-1:0] rounded_prod;
        reg    signed [2*WIDTH-1:0] shifted_prod;
        begin
            raw_prod = a * b;
            
            // Step 2: Apply Rounding
            if (ROUNDING) begin
                // Add half of LSB of target fraction (1 << (FRAC_A + FRAC_B - FRAC_Y - 1))
                // Here: 15 + 15 - 15 - 1 = 14
                rounded_prod = raw_prod + (1 << 14);
            end else begin
                rounded_prod = raw_prod;
            end

            // Step 3: Shift down to Q1.15
            shifted_prod = rounded_prod >>> 15;

            // Step 4: Squeeze / Saturation
            if (shifted_prod > 32767) begin
                y_expected = 16'h7FFF; // Saturation positive max (+0.999969)
            end else if (shifted_prod < -32768) begin
                y_expected = 16'h8000; // Saturation negative min (-1.0)
            end else begin
                y_expected = shifted_prod[WIDTH-1:0];
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Automatic Checking Block
    // Monitored on the clock edge, shortly after outputs transition (#1ns)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        #1; // Delay slightly from posedge to avoid race conditions
        if (!rst && valid_pipeline[2]) begin
            total_tests = total_tests + 1;
            if (tb_out_Y === exp_pipeline[2]) begin
                success_count = success_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL ERROR] at %t: Input A = %d, B = %d | Got = %d (hex: %h), Expected = %d (hex: %h)", 
                         $time, uut.r_A, uut.r_B, tb_out_Y, tb_out_Y, exp_pipeline[2], exp_pipeline[2]);
            end
        end
    end

    // ------------------------------------------------------------------------
    // Main Simulation Stimulus (Stress Test)
    // ------------------------------------------------------------------------
    integer i;
    reg signed [WIDTH-1:0] test_a, test_b;

    initial begin
        // Initialize Signals
        clk = 0;
        rst = 1;
        tb_in_A = 0;
        tb_in_B = 0;
        next_expected = 0;
        next_valid = 0;

        // Hold Reset for 5 clock periods
        #100;
        @(negedge clk);
        rst = 0;
        $display("----------------------------------------------------------------");
        $display("  Starting Pipelined Stress Test for FP_Mult_Unit (Q1.15)");
        $display("----------------------------------------------------------------");

        // --- STAGE 1: Edge Cases / Corner Cases ---
        // Test Case: Zero
        test_case(16'h0000, 16'h0000); // 0.0 * 0.0 = 0.0
        // Test Case: Identity
        test_case(16'h4000, 16'h4000); // 0.5 * 0.5 = 0.25 (16'h2000)
        // Test Case: Sign extension/Negative
        test_case(16'hC000, 16'h4000); // -0.5 * 0.5 = -0.25 (16'hE000)
        // Test Case: Symmetric scaling
        test_case(16'hC000, 16'hC000); // -0.5 * -0.5 = 0.25 (16'h2000)
        // Test Case: Saturation overflow (-1.0 * -1.0 = +1.0 => Saturation limit Q1.15)
        test_case(16'h8000, 16'h8000); // -1.0 * -1.0 = +1.0 (Overflow -> 16'h7FFF)
        // Test Case: Saturated negative underflow
        test_case(16'h8000, 16'h7FFF); // -1.0 * 0.9999 = -0.9999 (No overflow -> 16'h8002)

        // Clear intermediate bubble
        tb_in_A = 0; tb_in_B = 0; next_expected = 0; next_valid = 0;
        #100;

        // --- STAGE 2: Pipelined Stress Test (Continuous Dataflow) ---
        // We will feed a new random pair of coordinates every single clock cycle.
        // This validates that the pipeline registers inside the DSP are processing
        // data correctly with overlapping cycles.
        for (i = 0; i < 2000; i = i + 1) begin
            @(negedge clk);
            // Generate pseudo-random signed inputs
            // $random returns 32-bit signed value, we slice 16 bits
            test_a = $random;
            test_b = $random;

            tb_in_A = test_a;
            tb_in_B = test_b;
            
            calc_expected(test_a, test_b, next_expected);
            next_valid = 1;
        end

        // Clean up pipeline at the end of the data flow
        @(negedge clk);
        tb_in_A = 0;
        tb_in_B = 0;
        next_valid = 0;
        next_expected = 0;

        // Wait for the pipeline to drain completely (3 clock cycles)
        #100;

        // --- STAGE 3: Final Consolidation of Results ---
        $display("----------------------------------------------------------------");
        $display("  Pipelined Stress Test Results Summary:");
        $display("----------------------------------------------------------------");
        $display("  Total Operations Checked : %d", total_tests);
        $display("  Successes ([PASS])       : %d", success_count);
        $display("  Failures  ([FAIL])       : %d", fail_count);
        
        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> SUCCESS: All operations verified flawlessly on Cyclone V!");
        end else begin
            $display("  >>> ERROR: Hardware behavior discrepancy detected!");
        end
        $display("----------------------------------------------------------------");

        $finish;
    end

    // Helper task to apply single edge-case vectors with pipeline tracking
    task test_case;
        input signed [WIDTH-1:0] a;
        input signed [WIDTH-1:0] b;
        reg signed [WIDTH-1:0] expected_y;
        begin
            @(negedge clk);
            tb_in_A = a;
            tb_in_B = b;
            calc_expected(a, b, expected_y);
            next_expected = expected_y;
            next_valid = 1;
        end
    endtask

endmodule
