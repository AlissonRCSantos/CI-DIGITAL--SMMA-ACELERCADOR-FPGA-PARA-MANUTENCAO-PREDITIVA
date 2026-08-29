// ============================================================================
// Module: LMS_Filter_Top_v3
// Description: Top-Level Module for the 8-tap Folded (Shared-Resource) LMS
//              Adaptive Filter in Verilog, incorporating an industrial-grade
//              handshake and control interface.
//
// Interconnections:
//   - Connects LMS_Control_FSM_v3, LMS_Input_Delay_Line, LMS_Weight_Storage,
//     LMS_Processing_Element, and LMS_Accumulator_Error_Scale.
//   - Aligns sample shifting in the delay line to the internal 'load_sample'
//     control signal generated during the start handshake phase of the FSM.
// ============================================================================

`timescale 1ns / 1ps

module LMS_Filter_Top #(
    parameter WIDTH    = 16,       // Word width (default: 16 bits)
    parameter FRAC     = 15,       // Fraction width (default: Q1.15)
    parameter MU_SHIFT = 4         // Step size mu = 2^-4 = 0.0625
)(
    input  wire                 clk,          // System clock (50 MHz)
    input  wire                 rst,          // Synchronous reset (active-high)
    
    // Handshake & Control Interface Ports
    input  wire                 start,        // Pulses high for 1 cycle to trigger filtering/update
    input  wire                 enable,       // Global module enable (clock-enable)
    input  wire                 valid_in,     // Active high when input sample is valid
    
    output wire                 ready,        // High when output is ready and stable
    output wire                 busy,         // High during calculation window (17 cycles)
    output wire                 valid_out,    // Pulses high for 1 cycle when output is ready

    input  wire signed [WIDTH-1:0] in_x,      // Input sample x(n) (Format: Q1.15)
    
    output wire signed [WIDTH-1:0] out_y,       // Saturated filter output y(n) (Format: Q1.15)
    output wire signed [WIDTH-1:0] out_error,   // Saturated raw error e(n) = d(n) - y(n) (Format: Q1.15)

    // Debug Interface: Monitor all weights in parallel
    output wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7
);

    // ============================================================================
    // Interconnection Wires
    // ============================================================================
    
    // FSM Control Signals
    wire        ctrl_load_sample;
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
    // 1. Controller Instance (FSM v3 - with Handshake)
    // ============================================================================
    LMS_Control_FSM_v3 u_control (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .valid_in(valid_in),
        .ready(ready),
        .busy(busy),
        .valid_out(valid_out),
        .load_sample(ctrl_load_sample),
        .rd_addr(ctrl_rd_addr),
        .pe_sel(ctrl_pe_sel),
        .pe_valid(ctrl_pe_valid),
        .clear_acc(ctrl_clear_acc),
        .wr_addr(ctrl_wr_addr),
        .wr_en_gate(ctrl_wr_en_gate)
    );

    // ============================================================================
    // 2. Input Delay Line Instance
    // ============================================================================
    // Shifts/loads the new sample 'in_x' when FSM pulses 'ctrl_load_sample' high
    LMS_Input_Delay_Line #(
        .WIDTH(WIDTH)
    ) u_delay_line (
        .clk(clk),
        .rst(rst),
        .sample_valid(ctrl_load_sample),
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
    // Utilizes LMS_Processing_Element_v2 to resolve Quartus vector indexing issues.
    LMS_Processing_Element_v2 #(
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
