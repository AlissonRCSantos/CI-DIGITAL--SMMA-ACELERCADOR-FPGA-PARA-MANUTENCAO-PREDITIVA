// ============================================================================
// Module: LMS_Processing_Element
// Description: Processing Element (PE) for a shared-resource LMS adaptive filter.
//              Integrates the pipelined multiplier (FP_Mult_Unit) and the 
//              pipelined adder/subtractor (FP_Arith_Unit) with internal 
//              latency alignment for Cyclone V FPGA.
//
// Latency Paths:
//   - Input to out_y_part (Filtering): exactly 3 clock cycles.
//   - Input to out_w_next (Weight Update): exactly 5 clock cycles (3 mult + 2 add).
//
// Sychronization Internals:
//   - Automatically delays the 'sel' and 'valid_in' signals to align with
//     the 3-cycle multiplier latency and 2-cycle adder latency.
//   - Automatically delays the input weight 'in_w' by 3 cycles so that
//     the adder receives the weight w_k(n) and its increment delta_w at 
//     the exact same clock cycle, even when valid_in goes low (non-gated shift).
// ============================================================================

`timescale 1ns / 1ps

module LMS_Processing_Element #(
    parameter WIDTH = 16,  // Default word width (e.g., 16 bits)
    parameter FRAC  = 15   // Default fraction width (e.g., Q1.15)
)(
    input  wire                 clk,        // System clock (50 MHz)
    input  wire                 rst,        // Synchronous reset (active-high)
    
    // Control signals from FSM
    input  wire                 sel,        // 0: Filtering (Fase 1), 1: Weight Update (Fase 2)
    input  wire                 valid_in,   // Inputs are valid in the current clock cycle
    
    // Data Inputs
    input  wire signed [WIDTH-1:0] in_x,     // Delayed input sample x(n-k) (fixed multiplier port)
    input  wire signed [WIDTH-1:0] in_w,     // Current weight w_k(n) from storage
    input  wire signed [WIDTH-1:0] in_u_e,   // Scaled error mu * e(n) (stable during Phase 2)
    
    // Data Outputs
    output reg  signed [WIDTH-1:0] out_y_part,  // Pipelined filtering product (valid after 3 cycles)
    output wire signed [WIDTH-1:0] out_w_next,  // Pipelined updated weight w_k(n+1) (valid after 5 cycles)
    
    // Sychronized validation signals for external blocks
    output reg                  valid_y_part,  // Active high when out_y_part is valid (valid_in delayed by 3 cycles)
    output reg                  valid_w_next   // Active high when out_w_next is valid (valid_in delayed by 5 cycles)
);

    // ============================================================================
    // 1. Latency & Control Pipelines
    // ============================================================================
    // Delay pipelines for control signals to align with multiplier (3 cycles) and adder (2 cycles)
    reg [2:0] sel_pipe;
    reg [4:0] valid_pipe;

    always @(posedge clk) begin
        if (rst) begin
            sel_pipe   <= 3'b0;
            valid_pipe <= 5'b0;
        end else begin
            sel_pipe   <= {sel_pipe[1:0], sel};
            valid_pipe <= {valid_pipe[3:0], valid_in};
        end
    end

    // Map output validation lines based on pipeline depths
    always @(*) begin
        valid_y_part = valid_pipe[2] && (!sel_pipe[2]); // Valid filtering output (Cycle T+3, Phase 1)
        valid_w_next = valid_pipe[4] && sel_pipe[4];    // Valid updated weight (Cycle T+5, Phase 2)
    end

    // ============================================================================
    // 2. Weight Delay Line (Align current weight with multiplier output delta_w)
    // ============================================================================
    // Since multiplier has a latency of 3 cycles, we must delay the weight 'in_w'
    // by 3 cycles so that the adder receives w_k(n) and delta_w simultaneously.
    // This shift register must run unconditionally on every clock cycle to allow
    // trailing pipeline values to exit correctly when valid_in transitions to low.
    reg signed [WIDTH-1:0] w_delay [0:2];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 3; i = i + 1) begin
                w_delay[i] <= {WIDTH{1'b0}};
            end
        end else begin
            w_delay[0] <= in_w;
            w_delay[1] <= w_delay[0];
            w_delay[2] <= w_delay[1];
        end
    end

    // ============================================================================
    // 3. Multiplier Input Multiplexing
    // ============================================================================
    // Select input B of the multiplier:
    // - Phase 1 (sel = 0): Weight w_k(n)
    // - Phase 2 (sel = 1): Scaled error mu * e(n)
    wire signed [WIDTH-1:0] mult_in_B = (sel == 1'b1) ? in_u_e : in_w;

    // ============================================================================
    // 4. Pipelined Multiplier Instance (Latency: 3 cycles)
    // ============================================================================
    wire signed [WIDTH-1:0] mult_out;

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH),
        .FRAC_A(FRAC),
        .WIDTH_B(WIDTH),
        .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH),
        .FRAC_Y(FRAC),
        .ROUNDING(1)  // Enable symmetric rounding
    ) u_mult (
        .clk(clk),
        .rst(rst),
        .in_A(in_x),       // Fixed input sample
        .in_B(mult_in_B),  // MUXed weight or scaled error
        .out_Y(mult_out)   // Multiplier output
    );

    // ============================================================================
    // 5. Demultiplexer & Product Register
    // ============================================================================
    // Route multiplier output based on the 3-cycle delayed phase selector (sel_pipe[2])
    always @(posedge clk) begin
        if (rst) begin
            out_y_part <= {WIDTH{1'b0}};
        end else if (valid_pipe[2] && (sel_pipe[2] == 1'b0)) begin
            out_y_part <= mult_out; // Routing to output filtering accumulator
        end
    end

    // If we are in weight update phase (sel_pipe[2] == 1), route mult_out as delta_w
    wire signed [WIDTH-1:0] delta_w = (sel_pipe[2] == 1'b1) ? mult_out : {WIDTH{1'b0}};
    wire signed [WIDTH-1:0] w_aligned = w_delay[2];

    // ============================================================================
    // 6. Pipelined Adder Instance (Latency: 2 cycles)
    // ============================================================================
    // Calculates: w_k(n+1) = w_k(n) + delta_w
    // Parameters map to standard sfixed representation of Q1.15
    // INT parameters exclude signal bit, so Q1.15 -> INT = 0, FRAC = 15
    localparam INT_VAL = WIDTH - 1 - FRAC;

    FP_Arith_Unit #(
        .INT_A(INT_VAL),
        .FRAC_A(FRAC),
        .INT_B(INT_VAL),
        .FRAC_B(FRAC),
        .INT_Y(INT_VAL),
        .FRAC_Y(FRAC),
        .ROUNDING(1) // Enable symmetric rounding
    ) u_adder (
        .clk(clk),
        .rst(rst),
        .add_sub(1'b0),     // Always ADD
        .in_A(w_aligned),   // Delayed weight w_k(n)
        .in_B(delta_w),     // Weight increment delta_w
        .out_Y(out_w_next)  // Updated weight w_k(n+1)
    );

endmodule