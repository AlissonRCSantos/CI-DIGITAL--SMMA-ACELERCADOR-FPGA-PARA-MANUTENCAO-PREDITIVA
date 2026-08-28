// ============================================================================
// Module: LMS_Filter_Top
// Description: Top-Level Module for the 8-tap Folded (Shared-Resource) LMS
//              Adaptive Filter in Verilog.
//              Interconnects all submodules: Delay Line, Control FSM, PE,
//              Weight Storage, and Accumulator/Error/Scale units.
// ============================================================================

`timescale 1ns / 1ps

module LMS_Filter_Top #(
    parameter WIDTH    = 16,       // Word width (default: 16 bits)
    parameter FRAC     = 15,       // Fraction width (default: Q1.15)
    parameter MU_SHIFT = 4         // Step size mu = 2^-4 = 0.0625
)(
    input  wire                 clk,          // System clock (50 MHz)
    input  wire                 rst,          // Synchronous reset (active-high)
    input  wire                 sample_valid, // Pulses high for 1 cycle when new sample arrives
    input  wire signed [WIDTH-1:0] in_x,      // Input sample x(n) (Format: Q1.15)
    
    output wire signed [WIDTH-1:0] out_y,       // Saturated filter output y(n) (Format: Q1.15)
    output wire signed [WIDTH-1:0] out_error,   // Saturated raw error e(n) = d(n) - y(n) (Format: Q1.15)
    output wire                 filter_busy,  // Status high when calculation is in progress

    // Debug Interface: Monitor all weights in parallel
    output wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7
);

    // ============================================================================
    // Interconnection Wires
    // ============================================================================
    
    // FSM Control Signals
    wire [2:0]  ctrl_rd_addr;
    wire        ctrl_pe_sel;
    wire        ctrl_pe_valid;
    wire        ctrl_clear_acc;
    wire [2:0]  ctrl_wr_addr;
    wire        ctrl_wr_en_gate;
    
    // Input Delay Line Outputs
    wire signed [WIDTH-1:0] delay_out_x_k;
    wire signed [WIDTH-1:0] delay_out_d;
    
    // Weight Storage Outputs
    wire signed [WIDTH-1:0] storage_rd_data;
    
    // PE Outputs
    wire signed [WIDTH-1:0] pe_out_y_part;
    wire signed [WIDTH-1:0] pe_out_w_next;
    wire                    pe_valid_y_part;
    wire                    pe_valid_w_next;
    
    // Accumulator & Error Outputs
    wire signed [WIDTH-1:0] acc_out_u_e;
    wire                    acc_valid_u_e;

    // ============================================================================
    // 1. Controller Instance (FSM)
    // ============================================================================
    LMS_Control_FSM_v2 u_control (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .rd_addr(ctrl_rd_addr),
        .pe_sel(ctrl_pe_sel),
        .pe_valid(ctrl_pe_valid),
        .clear_acc(ctrl_clear_acc),
        .wr_addr(ctrl_wr_addr),
        .wr_en_gate(ctrl_wr_en_gate),
        .filter_busy(filter_busy)
    );

    // ============================================================================
    // 2. Input Delay Line Instance
    // ============================================================================
    LMS_Input_Delay_Line #(
        .WIDTH(WIDTH)
    ) u_delay_line (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .in_x(in_x),
        .rd_addr(ctrl_rd_addr),
        .out_x_k(delay_out_x_k),
        .out_d(delay_out_d)
    );

    // ============================================================================
    // 3. Weight Storage Instance (Register Bank)
    // ============================================================================
    // The write enable (we) is controlled by the PE's weight update validation
    // signal 'pe_valid_w_next'. The FSM ensures wr_addr is delayed 5 cycles
    // to match PE's weight update latency.
    LMS_Weight_Storage #(
        .WIDTH(WIDTH)
    ) u_weight_storage (
        .clk(clk),
        .rst(rst),
        .rd_addr(ctrl_rd_addr),
        .rd_data(storage_rd_data),
        .we(pe_valid_w_next),
        .wr_addr(ctrl_wr_addr),
        .wr_data(pe_out_w_next),
        .w0(w0),
        .w1(w1),
        .w2(w2),
        .w3(w3),
        .w4(w4),
        .w5(w5),
        .w6(w6),
        .w7(w7)
    );

    // ============================================================================
    // 4. Processing Element (PE) Instance
    // ============================================================================
    LMS_Processing_Element #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) u_pe (
        .clk(clk),
        .rst(rst),
        .sel(ctrl_pe_sel),
        .valid_in(ctrl_pe_valid),
        .in_x(delay_out_x_k),
        .in_w(storage_rd_data),
        .in_u_e(acc_out_u_e),
        .out_y_part(pe_out_y_part),
        .out_w_next(pe_out_w_next),
        .valid_y_part(pe_valid_y_part),
        .valid_w_next(pe_valid_w_next)
    );

    // ============================================================================
    // 5. Accumulator, Error Calculation & Convergence Scaling Instance
    // ============================================================================
    LMS_Accumulator_Error_Scale #(
        .WIDTH(WIDTH),
        .FRAC(FRAC),
        .MU_SHIFT(MU_SHIFT)
    ) u_accumulator_error (
        .clk(clk),
        .rst(rst),
        .clear_acc(ctrl_clear_acc),
        .valid_y_part(pe_valid_y_part),
        .in_y_part(pe_out_y_part),
        .in_d(delay_out_d),
        .out_y(out_y),
        .out_error(out_error),
        .out_u_e(acc_out_u_e),
        .valid_u_e(acc_valid_u_e)
    );

endmodule
