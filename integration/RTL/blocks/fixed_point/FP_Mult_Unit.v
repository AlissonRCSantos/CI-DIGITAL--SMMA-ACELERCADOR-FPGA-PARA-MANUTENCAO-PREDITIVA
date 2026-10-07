// ============================================================================
// Module: FP_Mult_Unit
// Description: Parameterized Signed Fixed-Point Multiplier Unit designed for 
//              optimal inference of Variable-Precision DSP blocks on Intel 
//              Cyclone V FPGAs.
//
// Features:
//   - Fully parameterizable widths and fractions.
//   - Fully pipelined (3 clock cycles of latency) for maximum clock speed.
//   - Infers Cyclone V Variable-Precision DSP blocks in 18x18 or 27x27 modes.
//   - Integrates optional symmetric rounding (Round to Nearest).
//   - Built-in overflow/underflow detection and saturation to prevent wrapping.
//
// Latency: exactly 3 clock cycles.
//   - Cycle 1: Registered Inputs (inside DSP input register stage)
//   - Cycle 2: Registered Product (inside DSP product register stage)
//   - Cycle 3: Rounding, Saturation, and Registered Output (in logic fabric)
// ============================================================================

`timescale 1ns / 1ps

module FP_Mult_Unit #(
    parameter WIDTH_A  = 16, // Bit width of input A
    parameter FRAC_A   = 15, // Fraction bits of input A (e.g. Q1.15)
    parameter WIDTH_B  = 16, // Bit width of input B
    parameter FRAC_B   = 15, // Fraction bits of input B (e.g. Q1.15)
    parameter WIDTH_Y  = 16, // Bit width of output Y
    parameter FRAC_Y   = 15, // Fraction bits of output Y (e.g. Q1.15)
    parameter ROUNDING = 1   // 1: Round to Nearest, 0: Truncation
)(
    input  wire                 clk,   // System clock (50 MHz)
    input  wire                 rst,   // Synchronous reset (active-high)
    input  wire signed [WIDTH_A-1:0] in_A,  // Fixed-point input A
    input  wire signed [WIDTH_B-1:0] in_B,  // Fixed-point input B
    output reg  signed [WIDTH_Y-1:0] out_Y   // Fixed-point product output Y
);

    // ------------------------------------------------------------------------
    // Local Parameters & Sizing
    // ------------------------------------------------------------------------
    localparam FRAC_PROD = FRAC_A + FRAC_B;
    localparam FRAC_DIFF = FRAC_PROD - FRAC_Y;
    
    // Saturation limits (signed)
    localparam signed [WIDTH_Y-1:0] OUT_MAX = {1'b0, {(WIDTH_Y-1){1'b1}}}; // e.g. 0x7FFF for 16-bit
    localparam signed [WIDTH_Y-1:0] OUT_MIN = {1'b1, {(WIDTH_Y-1){1'b0}}}; // e.g. 0x8000 for 16-bit

    // ------------------------------------------------------------------------
    // Pipeline Stage 1: Registered Inputs (to infer DSP input registers)
    // ------------------------------------------------------------------------
    reg signed [WIDTH_A-1:0] r_A;
    reg signed [WIDTH_B-1:0] r_B;

    always @(posedge clk) begin
        if (rst) begin
            r_A <= 0;
            r_B <= 0;
        end else begin
            r_A <= in_A;
            r_B <= in_B;
        end
    end

    // ------------------------------------------------------------------------
    // Pipeline Stage 2: Registered Product (to infer DSP product register)
    // ------------------------------------------------------------------------
    reg signed [WIDTH_A+WIDTH_B-1:0] r_prod;

    always @(posedge clk) begin
        if (rst) begin
            r_prod <= 0;
        end else begin
            r_prod <= r_A * r_B; // Signed multiplication
        end
    end

    // ------------------------------------------------------------------------
    // Pipeline Stage 3: Rounding, Scaling and Saturation
    // ------------------------------------------------------------------------
    wire signed [WIDTH_A+WIDTH_B-1:0] rounded_prod;
    wire signed [WIDTH_A+WIDTH_B-1:0] shifted_prod;

    generate
        if (FRAC_DIFF > 0) begin : gen_shift_right
            if (ROUNDING) begin : gen_rounding
                // Compiler-calculated rounding offset
                localparam signed [WIDTH_A+WIDTH_B-1:0] ROUND_VAL = (1 << (FRAC_DIFF - 1));
                assign rounded_prod = r_prod + ROUND_VAL;
                assign shifted_prod = rounded_prod >>> FRAC_DIFF;
            end else begin : gen_no_rounding
                assign rounded_prod = r_prod;
                assign shifted_prod = r_prod >>> FRAC_DIFF;
            end
        end else if (FRAC_DIFF == 0) begin : gen_no_shift
            assign rounded_prod = r_prod;
            assign shifted_prod = r_prod;
        end else begin : gen_shift_left
            assign rounded_prod = r_prod;
            // Scale up if necessary
            assign shifted_prod = r_prod <<< (-FRAC_DIFF);
        end
    endgenerate

    // Registered output with sychronous saturation check
    always @(posedge clk) begin
        if (rst) begin
            out_Y <= 0;
        end else begin
            // Signed comparison with compiler sign-extension
            if (shifted_prod > OUT_MAX) begin
                out_Y <= OUT_MAX; // Saturate positive overflow
            end else if (shifted_prod < OUT_MIN) begin
                out_Y <= OUT_MIN; // Saturate negative underflow
            end else begin
                out_Y <= shifted_prod[WIDTH_Y-1:0]; // Pass-through safely
            end
        end
    end

endmodule
