// ============================================================================
// Module: tb_FP_Arith_Unit
// Description: Testbench in Verilog for the FP_Arith_Unit module.
//              Configured for Q4.14 signed notation (18 bits total: 
//              1 sign bit, 3 integer bits, and 14 fractional bits).
//
// Features:
//   - Includes clock generation and synchronous reset.
//   - Tests addition, subtraction, negative numbers, and overflow/underflow.
//   - Employs a robust checking task ("check_result") to verify sýnchronous
//     pipeline outputs after the 2-clock latency.
// ============================================================================

`timescale 1ns / 1ps

module tb_FP_Arith_Unit;

    // Parameters for Q4.14 Notation
    // 1 sign bit + 3 integer bits = 4 bits left of the radix point (matching the 4 of Q4.14)
    // 14 fractional bits (matching the 14 of Q4.14)
    // Port width: [3 + 14 : 0] = [17:0] (18 bits)
    parameter INT_A   = 3;
    parameter FRAC_A  = 14;
    parameter INT_B   = 3;
    parameter FRAC_B  = 14;
    parameter INT_Y   = 3;
    parameter FRAC_Y  = 14;
    parameter ROUNDING = 1;

    localparam WIDTH = 1 + INT_Y + FRAC_Y; // 18 bits

    // Inputs to DUT
    reg              clk;
    reg              rst;
    reg              add_sub;
    reg  [WIDTH-1:0] in_A;
    reg  [WIDTH-1:0] in_B;

    // Output from DUT
    wire [WIDTH-1:0] out_Y;

    // Instantiate Device Under Test (DUT)
    FP_Arith_Unit #(
        .INT_A(INT_A),
        .FRAC_A(FRAC_A),
        .INT_B(INT_B),
        .FRAC_B(FRAC_B),
        .INT_Y(INT_Y),
        .FRAC_Y(FRAC_Y),
        .ROUNDING(ROUNDING)
    ) dut (
        .clk(clk),
        .rst(rst),
        .add_sub(add_sub),
        .in_A(in_A),
        .in_B(in_B),
        .out_Y(out_Y)
    );

    // Clock Generation (50 MHz => Period = 20ns)
    always begin
        #10 clk = ~clk;
    end

    // Error Tracking Counter
    integer error_count = 0;
    integer test_count = 0;

    // ------------------------------------------------------------------------
    // Verification Task: check_result
    // Drives inputs, waits for pipeline latency (2 clock cycles), 
    // and checks if the output matches expected sýnchronous result.
    // ------------------------------------------------------------------------
    task check_result;
        input [WIDTH-1:0] test_A;
        input [WIDTH-1:0] test_B;
        input             op_sub; // 0 for Add, 1 for Sub
        input [WIDTH-1:0] expected_Y;
        input [127:0]     test_name; // String identifier
        begin
            test_count = test_count + 1;
            
            // Step 1: Drive inputs sýnchronously at falling edge of clock 
            // to avoid race conditions with rising edge.
            @(negedge clk);
            in_A    = test_A;
            in_B    = test_B;
            add_sub = op_sub;
            
            // Step 2: Wait for exactly 2 rising edges of clock (DUT pipeline latency)
            @(posedge clk); // Cycle 1: sum_reg gets calculated
            @(posedge clk); // Cycle 2: out_Y gets registered
            
            // Small delay to allow signals to settle in simulation
            #1;
            
            // Step 3: Evaluate and report
            if (out_Y === expected_Y) begin
                $display("[PASS] %s: in_A=%h, in_B=%h, op=%s | out_Y=%h (Expected: %h)", 
                         test_name, test_A, test_B, (op_sub ? "-" : "+"), out_Y, expected_Y);
            end else begin
                $display("[FAIL] %s: in_A=%h, in_B=%h, op=%s | out_Y=%h (Expected: %h)", 
                         test_name, test_A, test_B, (op_sub ? "-" : "+"), out_Y, expected_Y);
                error_count = error_count + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Stimulus Block
    // ------------------------------------------------------------------------
    initial begin
        // Initialize signals
        clk     = 0;
        rst     = 1;
        in_A    = 0;
        in_B    = 0;
        add_sub = 0;

        $display("=================================================================");
        $display("Starting Testbench: FP_Arith_Unit (Q4.14 Signed Arithmetic)");
        $display("Latency: 2 Clock Cycles");
        $display("=================================================================");

        // Apply reset
        #40;
        @(negedge clk);
        rst = 0;
        #10;

        // --- TEST CASE 1: Standard Addition (2.5 + 1.25 = 3.75) ---
        // 2.5  => 18'h0A000
        // 1.25 => 18'h05000
        // 3.75 => 18'h0F000
        check_result(18'h0A000, 18'h05000, 1'b0, 18'h0F000, "TC1: Std Addition");

        // --- TEST CASE 2: Standard Subtraction (3.0 - 1.5 = 1.5) ---
        // 3.0 => 18'h0C000
        // 1.5 => 18'h06000
        // 1.5 => 18'h06000
        check_result(18'h0C000, 18'h06000, 1'b1, 18'h06000, "TC2: Std Subtraction");

        // --- TEST CASE 3: Signed Arithmetic with Negatives (-2.0 + 1.0 = -1.0) ---
        // -2.0 => 18'h38000
        //  1.0 => 18'h04000
        // -1.0 => 18'h3C000
        check_result(18'h38000, 18'h04000, 1'b0, 18'h3C000, "TC3: Neg Addition");

        // --- TEST CASE 4: Positive Overflow and Saturation (6.0 + 3.0 = 9.0 => Saturation MaxPos) ---
        // 6.0    => 18'h18000
        // 3.0    => 18'h0C000
        // MaxPos => 18'h1FFFF (+7.99993896)
        check_result(18'h18000, 18'h0C000, 1'b0, 18'h1FFFF, "TC4: Pos Overflow ");

        // --- TEST CASE 5: Negative Overflow and Saturation (-6.0 - 3.0 = -9.0 => Saturation MinNeg) ---
        // -6.0   => 18'h28000
        //  3.0   => 18'h0C000
        // MinNeg => 18'h20000 (-8.0)
        check_result(18'h28000, 18'h0C000, 1'b1, 18'h20000, "TC5: Neg Underflow");

        // --- TEST CASE 6: Subtraction yielding Negative Result (1.0 - 2.5 = -1.5) ---
        // 1.0  => 18'h04000
        // 2.5  => 18'h0A000
        // -1.5 => 18'h3A000 (Two's complement check: -1.5 * 16384 = -24576 => 18'h3A000)
        check_result(18'h04000, 18'h0A000, 1'b1, 18'h3A000, "TC6: Negative Diff");

        // Finish simulation
        #40;
        $display("=================================================================");
        $display("Testbench Completed: %0d tests run.", test_count);
        if (error_count == 0) begin
            $display("[SUCCESS] All tests passed flawlessly!");
        end else begin
            $display("[ERROR] Failed %0d tests out of %0d.", error_count, test_count);
        end
        $display("=================================================================");
        $finish;
    end

endmodule
