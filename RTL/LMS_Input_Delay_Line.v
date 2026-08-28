// ============================================================================
// Module: LMS_Input_Delay_Line
// Description: Addressable Input Delay Line for a shared-resource (folded) 
//              LMS adaptive filter. Optimized for predictive line-enhancement
//              where the desired signal d(n) is the current sample x(n), and
//              the filter FIR line uses delayed samples x(n-1) to x(n-8).
//
// Features:
//   - Parameterized word width (default 16-bit Q1.15).
//   - Synchronous shift on 'sample_valid' (when a new sample arrives).
//   - Addressable read port ('rd_addr') to allow the sequencial FSM to select
//     the exact sample x(n-1-k) for the current tap 'k' being processed.
//   - High-performance combinational read multiplexer (the output is directly
//     registered in the PE's multiplier input registers, maintaining Fmax).
//   - Embedded register to capture and hold the desired signal d(n) stable
//     throughout the LMS iteration cycles.
// ============================================================================

`timescale 1ns / 1ps

module LMS_Input_Delay_Line #(
    parameter WIDTH = 16  // Default word width (e.g., 16 bits for Q1.15)
)(
    input  wire                 clk,          // System clock (50 MHz)
    input  wire                 rst,          // Synchronous reset (active-high)
    
    // Sample Control Interface
    input  wire                 sample_valid, // High for 1 clock cycle when a new physical sample arrives
    input  wire signed [WIDTH-1:0] in_x,      // New physical sample x(n) (Q1.15)
    
    // FSM Read Interface
    input  wire [2:0]           rd_addr,      // Read address from FSM (0 to 7 to select tap k)
    
    // Data Outputs
    output wire signed [WIDTH-1:0] out_x_k,     // Selected delayed sample x(n-1-rd_addr) for the PE
    output reg  signed [WIDTH-1:0] out_d        // Captured desired signal d(n) = x(n)
);

    // ============================================================================
    // 1. Shift Register Storage (8 Taps of Delay)
    // ============================================================================
    // shift_reg[0] holds x(n-1)
    // shift_reg[1] holds x(n-2)
    // ...
    // shift_reg[7] holds x(n-8)
    reg signed [WIDTH-1:0] shift_reg [0:7];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) begin
                shift_reg[i] <= {WIDTH{1'b0}};
            end
        end else if (sample_valid) begin
            // Shift operations
            shift_reg[0] <= in_x; // Shift in the newest sample to represent x(n-1)
            for (i = 1; i < 8; i = i + 1) begin
                shift_reg[i] <= shift_reg[i-1]; // Cascade shifts
            end
        end
    end

    // ============================================================================
    // 2. Addressable Read Multiplexer
    // ============================================================================
    // Selects the delayed sample based on rd_addr (0 to 7) to feed into the PE.
    // This combinational MUX is extremely fast because it has only 8 inputs and
    // its output is directly registered in the PE's input register.
    assign out_x_k = shift_reg[rd_addr];

    // ============================================================================
    // 3. Desired Signal Capture
    // ============================================================================
    // In a predictive model (e.g., Adaptive Line Enhancer - ALE), the desired
    // signal d(n) is the raw current input sample x(n) (un-delayed).
    // We register and hold this sample to ensure it remains stable throughout
    // all the LMS calculation phases (which take 17 clock cycles).
    always @(posedge clk) begin
        if (rst) begin
            out_d <= {WIDTH{1'b0}};
        end else if (sample_valid) begin
            out_d <= in_x; // Capture d(n) = x(n)
        end
    end

endmodule
