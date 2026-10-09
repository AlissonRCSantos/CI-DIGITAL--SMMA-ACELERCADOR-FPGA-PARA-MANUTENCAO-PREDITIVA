// ============================================================================
// Module: LMS_Input_Delay_Line
// Description: Addressable Input Delay Line (Shift Register) for folded LMS.
//              Holds the history of input samples x(n-1) to x(n-8) and captures
//              the current input sample as the desired signal d(n).
// ============================================================================

`timescale 1ns / 1ps

module LMS_Input_Delay_Line #(
    parameter WIDTH = 16
)(
    input  wire                 clk,          // System clock (50 MHz)
    input  wire                 rst,          // Synchronous reset (active-high)
    input  wire                 sample_valid, // Active high when a new sample arrives
    input  wire signed [WIDTH-1:0] in_x,      // New input sample x(n)
    input  wire        [2:0]     rd_addr,      // Read address to select tap x(n-1-k)
    output wire signed [WIDTH-1:0] out_x_k,    // Selected tapped sample x(n-1-rd_addr)
    output reg  signed [WIDTH-1:0] out_d       // Stable registered desired signal d(n)
);

    reg signed [WIDTH-1:0] shift_reg [0:7];
    integer i;

    // Shift Register Cascade & d(n) Capture
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) begin
                shift_reg[i] <= {WIDTH{1'b0}};
            end
            out_d <= {WIDTH{1'b0}};
        end else if (sample_valid) begin
            shift_reg[0] <= in_x;
            for (i = 1; i < 8; i = i + 1) begin
                shift_reg[i] <= shift_reg[i-1];
            end
            out_d <= in_x; // Capture current input sample as the desired signal d(n)
        end
    end

    // Combinational Addressable Read
    assign out_x_k = shift_reg[rd_addr];

endmodule