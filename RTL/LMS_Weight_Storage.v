// ============================================================================
// Module: LMS_Weight_Storage
// Description: Sychronous Weight Storage (Register Bank) for an 8-tap folded
//              LMS adaptive filter using Q1.15 fixed-point representation.
//
// Features:
//   - Stores 8 coefficients (w0 to w7) of 16-bit width.
//   - Asynchronous/combinational read of the selected coefficient (rd_addr)
//     to prevent adding an extra cycle of latency to the PE input.
//   - Sychronous write of the updated coefficient (wr_addr) using the PE
//     validation signal as Write Enable (we).
//   - Supports initialization/reset of weights to 0 (or a default value).
// ============================================================================

`timescale 1ns / 1ps

module LMS_Weight_Storage #(
    parameter WIDTH = 16  // Default word width (e.g., 16 bits)
)(
    input  wire                 clk,       // System clock (50 MHz)
    input  wire                 rst,       // Synchronous reset (active-high)
    
    // Read Interface (Fase 1 & Fase 2 reading)
    input  wire [2:0]           rd_addr,   // Address of the weight to read (0 to 7)
    output wire signed [WIDTH-1:0] rd_data,   // Selected weight output w_k(n)
    
    // Write Interface (Fase 2 updating)
    input  wire                 we,        // Write Enable (connected to valid_w_next of PE)
    input  wire [2:0]           wr_addr,   // Address of the weight to update (0 to 7)
    input  wire signed [WIDTH-1:0] wr_data,   // Updated weight input w_k(n+1) from PE
    
    // Debug Interface (to monitor convergence/all weights in parallel if needed)
    output wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7
);

    // 8 Registers of WIDTH bits
    reg signed [WIDTH-1:0] weights [0:7];
    integer i;

    // Synchronous Write / Reset
    always @(posedge clk) begin
        if (rst) begin
            // Initialize all weights to 0.0 (or a small fractional value if desired)
            for (i = 0; i < 8; i = i + 1) begin
                weights[i] <= {WIDTH{1'b0}};
            end
        end else if (we) begin
            weights[wr_addr] <= wr_data;
        end
    end

    // Combinational Read (Ensures zero-latency read for the PE input mux)
    assign rd_data = weights[rd_addr];

    // Map registers to debug ports
    assign w0 = weights[0];
    assign w1 = weights[1];
    assign w2 = weights[2];
    assign w3 = weights[3];
    assign w4 = weights[4];
    assign w5 = weights[5];
    assign w6 = weights[6];
    assign w7 = weights[7];

endmodule
