`timescale 1ns / 1ps

module tb_smma_dataset;
    localparam WIDTH = 16;

    reg clk = 1'b0;
    always #10 clk = ~clk; // 50 MHz

    reg reset = 1'b1;
    reg enable = 1'b1;
    reg sample_start = 1'b0;
    reg sample_valid = 1'b0;
    reg dataset_start = 1'b0;
    reg signed [WIDTH-1:0] sample_x = 0;
    reg signed [WIDTH-1:0] sample_d = 0;
    wire sample_ready;
    wire dataset_busy, dataset_done;
    wire signed [WIDTH-1:0] lms_y, lms_error;
    wire lms_valid;
    wire [5:0] fundamental_bin, fundamental_hz_frac;
    wire [19:0] fundamental_hz_int;
    wire fundamental_valid, gcd_error, analysis_busy, analysis_done;
    wire cnn_pixel_ready, cnn_valid, cnn_busy;
    wire [1:0] cnn_class;
    wire auto_tree_busy, auto_tree_done, auto_tree_class_valid, auto_tree_error;
    wire auto_cnn_busy, auto_cnn_done, auto_cnn_class_valid;
    wire [1:0] auto_tree_class, auto_cnn_class;
    wire inv_ready, inv_valid_out, inv_busy, inv_singular;
    wire signed [WIDTH-1:0] inv_read_data;

    SMMA_Top #(.DATA_ROM_FAST(1)) dut (
        .clk(clk), .reset(reset), .enable(enable),
        .dataset_start(dataset_start), .dataset_busy(dataset_busy),
        .dataset_done(dataset_done),
        .sample_start(sample_start), .sample_valid(sample_valid),
        .sample_x(sample_x), .sample_d(sample_d), .sample_ready(sample_ready),
        .lms_y(lms_y), .lms_error(lms_error), .lms_valid(lms_valid),
        .peak_threshold(16'd0), .min_gcd_bin(6'd1), .sample_rate_hz(20'd25600),
        .fundamental_bin(fundamental_bin), .fundamental_hz_int(fundamental_hz_int),
        .fundamental_hz_frac(fundamental_hz_frac), .fundamental_valid(fundamental_valid),
        .gcd_error(gcd_error), .analysis_busy(analysis_busy), .analysis_done(analysis_done),
        .tree_start(1'b0), .tree_feature_valid(1'b0), .tree_feature(16'sd0),
        .tree_feature_ready(), .tree_ready(), .tree_busy(), .tree_done(),
        .tree_class_ready(1'b1), .tree_class_valid(), .tree_class(), .tree_error(),
        .auto_tree_busy(auto_tree_busy), .auto_tree_done(auto_tree_done),
        .auto_tree_class_valid(auto_tree_class_valid), .auto_tree_class(auto_tree_class),
        .auto_tree_error(auto_tree_error),
        .auto_cnn_busy(auto_cnn_busy), .auto_cnn_done(auto_cnn_done),
        .auto_cnn_class_valid(auto_cnn_class_valid), .auto_cnn_class(auto_cnn_class),
        .cnn_start(1'b0), .cnn_pixel_valid(1'b0), .cnn_pixel(16'sd0),
        .cnn_pixel_ready(cnn_pixel_ready), .cnn_class(cnn_class),
        .cnn_valid(cnn_valid), .cnn_busy(cnn_busy),
        .inv_start(1'b0), .inv_n(3'd0), .inv_valid_in(1'b0), .inv_ready(inv_ready),
        .inv_load_row(2'd0), .inv_load_col(2'd0), .inv_load_data(16'sd0),
        .inv_valid_out(inv_valid_out), .inv_busy(inv_busy), .inv_singular(inv_singular),
        .inv_read_row(2'd0), .inv_read_col(3'd0), .inv_read_data(inv_read_data)
    );

    initial begin
        repeat (5) @(negedge clk);
        reset = 1'b0;
        dataset_start = 1'b1;
        @(negedge clk);
        dataset_start = 1'b0;
        wait (dataset_done);
        wait (auto_tree_done);
        wait (auto_cnn_done);
        $display("Same vibration window: tree=%0d (error=%b), CNN=%0d; legacy f0=%0d + frac, gcd_error=%b",
                 auto_tree_class, auto_tree_error, auto_cnn_class,
                 fundamental_hz_int, gcd_error);
        $finish;
    end
endmodule
