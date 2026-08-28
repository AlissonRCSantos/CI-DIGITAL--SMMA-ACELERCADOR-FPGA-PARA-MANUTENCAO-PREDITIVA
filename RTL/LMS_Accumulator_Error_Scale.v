// ============================================================================
// Module: LMS_Accumulator_Error_Scale
// Description: Accumulation, Error Calculation and Convergence Scaling (mu * e)
//              unit designed for a shared-resource LMS adaptive filter in Verilog.
//
// Features:
//   - Parameterizable word width and fraction bits.
//   - Self-timing accumulator that counts valid partial products from PE.
//   - 32-bit signed guard accumulation to prevent intermediate overflow.
//   - Integrates symmetric saturation to convert y(n) back to Q1.15.
//   - Performs subtraction e(n) = d(n) - y(n) with symmetric saturation.
//   - Performs arithmetic right shift to scale error by mu = 2^-MU_SHIFT.
//   - Self-timing "valid_u_e" strobe to trigger the weight update phase.
// ============================================================================\n
`timescale 1ns / 1ps

module LMS_Accumulator_Error_Scale #(
    parameter WIDTH    = 16,       // Word width (e.g. 16 bits)
    parameter FRAC     = 15,       // Fraction bits (e.g. Q1.15)
    parameter MU_SHIFT = 4         // mu = 2^-4 = 0.0625
)(
    input  wire                 clk,          // System clock (50 MHz)
    input  wire                 rst,          // Synchronous reset (active-high)
    input  wire                 clear_acc,    // Clears accumulator at start of sample iteration
    
    // Inputs from PE
    input  wire                 valid_y_part, // Active high when a valid partial product arrives
    input  wire signed [WIDTH-1:0] in_y_part,   // Partial product from PE (out_y_part)
    
    // Input from Delay Line
    input  wire signed [WIDTH-1:0] in_d,        // Stabilized desired signal d(n)
    
    // Outputs
    output reg  signed [WIDTH-1:0] out_y,       // Saturated filtering output y(n)
    output reg  signed [WIDTH-1:0] out_error,   // Saturated raw error e(n) = d(n) - y(n)
    output reg  signed [WIDTH-1:0] out_u_e,     // Scaled error mu * e(n) (stable for update)
    output reg                  valid_u_e     // Strobe high for 1 cycle when error & scale are ready
);

    // ============================================================================
    // 1. Guard Accumulator & Tap Counter
    // ============================================================================
    // 32-bit signed accumulator provides plenty of guard bits to prevent intermediate
    // overflow during the accumulation of 8 partial products.
    reg signed [31:0] acc_reg;
    reg [2:0]         tap_count; // Counts from 0 to 7 (8 taps total)
    reg               y_ready;   // Internal strobe indicating y(n) accumulation is complete

    always @(posedge clk) begin
        if (rst) begin
            acc_reg   <= 32'sb0;
            tap_count <= 3'd0;
            y_ready   <= 1'b0;
        end else if (clear_acc) begin
            acc_reg   <= 32'sb0;
            tap_count <= 3'd0;
            y_ready   <= 1'b0;
        end else if (valid_y_part) begin
            acc_reg   <= acc_reg + $signed(in_y_part);
            tap_count <= tap_count + 1'b1;
            
            // On the 8th tap (tap_count == 7), the final sum is written to acc_reg.
            // On the next cycle, y_ready will strobe high to process the completed y(n).
            if (tap_count == 3'd7) begin
                y_ready <= 1'b1;
            end else begin
                y_ready <= 1'b0;
            end
        end else begin
            y_ready <= 1'b0;
        end
    end

    // ============================================================================
    // 2. Output Saturation & Scaling
    // ============================================================================
    // 2.1 Saturation of y(n): 32-bit accumulator back to Q(WIDTH-1-FRAC).(FRAC)
    // For Q1.15 (INT = 0, FRAC = 15): limits are [-32768, 32767]
    localparam signed [31:0] MAX_VAL = (1 << (WIDTH - 1)) - 1;
    localparam signed [31:0] MIN_VAL = -(1 << (WIDTH - 1));

    wire signed [WIDTH-1:0] sat_y;
    assign sat_y = (acc_reg > MAX_VAL) ? $signed(MAX_VAL[WIDTH-1:0]) :
                   (acc_reg < MIN_VAL) ? $signed(MIN_VAL[WIDTH-1:0]) :
                   acc_reg[WIDTH-1:0];

    // 2.2 Subtraction: e(n) = d(n) - y(n) in 17 bits to avoid intermediate wrap
    wire signed [WIDTH:0] raw_err = $signed(in_d) - $signed(sat_y);

    // Saturated raw error (for external debug and system monitoring)
    reg signed [WIDTH-1:0] sat_error;
    always @(*) begin
        if (raw_err > $signed(MAX_VAL[WIDTH:0])) begin
            sat_error = MAX_VAL[WIDTH-1:0];
        end else if (raw_err < $signed(MIN_VAL[WIDTH:0])) begin
            sat_error = MIN_VAL[WIDTH-1:0];
        end else begin
            sat_error = raw_err[WIDTH-1:0];
        end
    end

    // 2.3 Arithmetic Shift: mu * e(n) = e(n) >>> MU_SHIFT
    // Since we shift the 17-bit raw error first, there is no chance of intermediate overflow 
    // for the scaled error, which is then safely sliced to [WIDTH-1:0].
    wire signed [WIDTH:0] shifted_err = raw_err >>> MU_SHIFT;

    // Synchronous registered output block
    always @(posedge clk) begin
        if (rst) begin
            out_y     <= {WIDTH{1'b0}};
            out_error <= {WIDTH{1'b0}};
            out_u_e   <= {WIDTH{1'b0}};
            valid_u_e <= 1'b0;
        end else if (y_ready) begin
            out_y     <= sat_y;
            out_error <= sat_error;
            out_u_e   <= shifted_err[WIDTH-1:0]; // Slice directly to Q1.15
            valid_u_e <= 1'b1;                   // Trigger Weight Update Phase
        end else begin
            valid_u_e <= 1'b0;
        end
    end

endmodule
