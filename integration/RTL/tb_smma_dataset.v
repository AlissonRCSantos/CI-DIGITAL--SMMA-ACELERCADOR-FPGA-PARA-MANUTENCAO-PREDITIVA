`timescale 1ns / 1ps

module tb_smma_dataset;
    parameter integer SAMPLE_COUNT = 64;
    parameter DATA_FILE = "../data/vibration_input.hex";
    localparam WIDTH = 16;

    reg clk = 1'b0;
    always #10 clk = ~clk; // 50 MHz

    reg reset = 1'b1;
    reg enable = 1'b1;
    reg sample_start = 1'b0;
    reg sample_valid = 1'b0;
    reg signed [WIDTH-1:0] sample_x = 0;
    reg signed [WIDTH-1:0] sample_d = 0;
    wire sample_ready;
    wire signed [WIDTH-1:0] lms_y, lms_error;
    wire lms_valid;
    wire [5:0] fundamental_bin, fundamental_hz_frac;
    wire [19:0] fundamental_hz_int;
    wire fundamental_valid, gcd_error, analysis_busy, analysis_done;
    wire cnn_pixel_ready, cnn_valid, cnn_busy;
    wire [1:0] cnn_class;
    wire inv_ready, inv_valid_out, inv_busy, inv_singular;
    wire signed [WIDTH-1:0] inv_read_data;

    reg [31:0] words [0:SAMPLE_COUNT-1];
    integer index;

    SMMA_Top dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_start(sample_start), .sample_valid(sample_valid),
        .sample_x(sample_x), .sample_d(sample_d), .sample_ready(sample_ready),
        .lms_y(lms_y), .lms_error(lms_error), .lms_valid(lms_valid),
        .peak_threshold(16'd0), .min_gcd_bin(6'd1), .sample_rate_hz(20'd25600),
        .fundamental_bin(fundamental_bin), .fundamental_hz_int(fundamental_hz_int),
        .fundamental_hz_frac(fundamental_hz_frac), .fundamental_valid(fundamental_valid),
        .gcd_error(gcd_error), .analysis_busy(analysis_busy), .analysis_done(analysis_done),
        .cnn_start(1'b0), .cnn_pixel_valid(1'b0), .cnn_pixel(16'sd0),
        .cnn_pixel_ready(cnn_pixel_ready), .cnn_class(cnn_class),
        .cnn_valid(cnn_valid), .cnn_busy(cnn_busy),
        .inv_start(1'b0), .inv_n(3'd0), .inv_valid_in(1'b0), .inv_ready(inv_ready),
        .inv_load_row(2'd0), .inv_load_col(2'd0), .inv_load_data(16'sd0),
        .inv_valid_out(inv_valid_out), .inv_busy(inv_busy), .inv_singular(inv_singular),
        .inv_read_row(2'd0), .inv_read_col(3'd0), .inv_read_data(inv_read_data)
    );

    initial begin
        $readmemh(DATA_FILE, words);
        repeat (5) @(negedge clk);
        reset = 1'b0;

        for (index = 0; index < SAMPLE_COUNT; index = index + 1) begin
            while (sample_ready !== 1'b1) @(negedge clk);
            sample_x = words[index][15:0];
            sample_d = words[index][31:16];
            sample_valid = 1'b1;
            sample_start = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            sample_start = 1'b0;
        end

        wait (analysis_done);
        $display("Analysis done: bin=%0d, f0=%0d + frac, gcd_error=%b",
                 fundamental_bin, fundamental_hz_int, gcd_error);
        $finish;
    end
endmodule
