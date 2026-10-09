// ============================================================================
// tb_FP_Arith_Unit -- testbench da soma/subtracao em ponto fixo
// ============================================================================

`timescale 1ns / 1ps

module tb_FP_Arith_Unit;

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

    // Verification Task: check_result
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

    // Stimulus Block
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

        check_result(18'h0A000, 18'h05000, 1'b0, 18'h0F000, "TC1: Std Addition");

        check_result(18'h0C000, 18'h06000, 1'b1, 18'h06000, "TC2: Std Subtraction");

        check_result(18'h38000, 18'h04000, 1'b0, 18'h3C000, "TC3: Neg Addition");

        check_result(18'h18000, 18'h0C000, 1'b0, 18'h1FFFF, "TC4: Pos Overflow ");

        check_result(18'h28000, 18'h0C000, 1'b1, 18'h20000, "TC5: Neg Underflow");

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
