`timescale 1ns / 1ps

// Extrai as mesmas 12 features que alimentam a arvore do top_level.
// A entrada e o acelerometro cru em Q1.15, amostrado a 25.6 kHz.
module SMMA_Tree_Feature_Pipeline #(
    parameter WIDTH = 16,
    parameter FRAC = 15,
    parameter NFFT = 64,
    parameter HOP = 32,
    parameter N_BINS = 32,
    parameter N_FRAMES = 32,
    parameter RAW_SAMPLES = 8503,
    parameter TREE_N_NODES = 141,
    parameter FIR_COEF = "vetores/fir_coef.hex",
    parameter TREE_ROM = "vetores/arvore.hex"
)(
    input wire clk,
    input wire rst,
    input wire enable,
    input wire sample_valid,
    input wire signed [WIDTH-1:0] sample,
    output wire sample_ready,
    output wire window_start,
    input wire image_ready,
    input wire image_done,
    output wire image_valid,
    output wire [WIDTH-1:0] image_pixel,
    output wire busy,
    output reg done,
    output wire class_valid,
    output wire [1:0] class_out,
    output wire tree_error
);
    localparam integer DECIM = 8;
    localparam integer WINDOW_DEC = (N_FRAMES-1)*HOP + NFFT;

    reg launched;
    reg [13:0] raw_count;
    reg [11:0] dec_count;
    wire launch = !rst && !launched;
    assign window_start = launch;

    wire fir_in_ready, fir_out_valid, fir_out_ready;
    wire signed [WIDTH-1:0] dec_sample;
    wire fir_overflow;

    assign sample_ready = enable && launched && (raw_count < RAW_SAMPLES) && fir_in_ready;
    FIR_Decimator #(.WIDTH(WIDTH), .FRAC(FRAC), .N_TAPS(63), .DECIM(DECIM),
                    .ARQ_COEF(FIR_COEF)) u_fir (
        .clk(clk), .rst(rst), .limpa(launch),
        .in_valid(sample_valid && sample_ready), .in_ready(fir_in_ready),
        .in_sample(sample), .out_ready(fir_out_ready),
        .out_valid(fir_out_valid), .out_sample(dec_sample), .overflow(fir_overflow)
    );

    wire fb_ready, fb_busy, fb_done, fb_in_ready;
    wire fb_out_valid, fb_out_ready, fb_frame_ini, fb_frame_fim;
    wire signed [WIDTH-1:0] fb_out_sample;
    wire ft_ready, ft_busy, ft_done, ft_in_ready;
    wire fs_ready, fs_busy, fs_done, fs_in_ready;
    wire tree_ready, tree_busy, tree_done, tree_in_ready;
    wire dec_join_ready = fb_in_ready && ft_in_ready;
    assign fir_out_ready = dec_join_ready;
    wire dec_accept = fir_out_valid && fir_out_ready;

    Frame_Builder #(.WIDTH(WIDTH), .NFFT(NFFT), .HOP(HOP),
                    .N_QUADROS(N_FRAMES)) u_frames (
        .clk(clk), .rst(rst), .start(launch), .ready(fb_ready),
        .busy(fb_busy), .done(fb_done), .in_valid(dec_accept),
        .in_ready(fb_in_ready), .in_sample(dec_sample),
        .out_ready(fb_out_ready), .out_valid(fb_out_valid),
        .out_sample(fb_out_sample), .out_frame_ini(fb_frame_ini),
        .out_frame_fim(fb_frame_fim)
    );

    wire fft_ready, fft_busy, fft_done, fft_in_ready;
    wire fft_out_valid, fft_out_ready;
    wire [5:0] fft_out_index;
    wire [WIDTH-1:0] fft_out_mag;
    reg fft_armed;
    wire fft_start = fb_out_valid && fb_frame_ini && fft_ready && !fft_armed;

    always @(posedge clk) begin
        if (rst) fft_armed <= 1'b0;
        else if (fft_start) fft_armed <= 1'b1;
        else if (fb_out_valid && fb_out_ready && fb_frame_fim) fft_armed <= 1'b0;
    end

    assign fb_out_ready = fft_armed && fft_in_ready;
    // /16, igual a escala usada ao gerar os limiares e os dados da CNN.
    FFT_Top #(.WIDTH(WIDTH), .FRAC(FRAC), .LOG2N(6),
              .SCALE_MASK(6'b001111)) u_tree_fft (
        .clk(clk), .rst(rst), .start(fft_start), .enable(enable),
        .ready(fft_ready), .busy(fft_busy), .done(fft_done),
        .in_valid(fb_out_valid && fft_armed), .in_ready(fft_in_ready),
        .in_real(fb_out_sample), .in_imag({WIDTH{1'b0}}),
        .out_ready(fft_out_ready), .out_valid(fft_out_valid),
        .out_index(fft_out_index), .out_real(), .out_imag(),
        .out_mag(fft_out_mag), .stage_dbg()
    );

    wire useful_bin = (fft_out_index < N_BINS);
    wire sb_in_ready;
    wire consumers_ready = fs_in_ready && sb_in_ready;
    assign fft_out_ready = useful_bin ? consumers_ready : 1'b1;
    wire accepted_bin = fft_out_valid && useful_bin && consumers_ready;
    wire fs_out_valid, ft_out_valid;
    wire signed [WIDTH-1:0] fs_feature, ft_feature;
    wire fs_out_ready, ft_out_ready;
    wire tree_start = launch;

    Feature_Spectral #(.WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_FRAMES)) u_spectral (
        .clk(clk), .rst(rst), .start(launch), .ready(fs_ready),
        .busy(fs_busy), .done(fs_done), .in_valid(accepted_bin),
        .in_ready(fs_in_ready), .in_mag(fft_out_mag), .out_ready(fs_out_ready),
        .out_valid(fs_out_valid), .out_feature(fs_feature)
    );

    wire log_valid;
    wire [WIDTH-1:0] log_pixel;
    FFT_Log2_Compress #(.WIDTH(WIDTH)) u_log2 (
        .clk(clk), .rst(rst), .en(sb_in_ready),
        .in_valid(accepted_bin), .in_mag(fft_out_mag),
        .out_valid(log_valid), .out_pixel(log_pixel)
    );

    wire sb_ready, sb_busy, sb_done, sb_out_valid, sb_out_ready;
    wire [WIDTH-1:0] sb_out_pixel;
    Spectrogram_Buffer #(.WIDTH(WIDTH), .N_BINS(N_BINS),
                         .N_QUADROS(N_FRAMES)) u_spectrogram (
        .clk(clk), .rst(rst), .start(launch), .ready(sb_ready),
        .busy(sb_busy), .done(sb_done), .in_valid(log_valid),
        .in_ready(sb_in_ready), .in_pixel(log_pixel),
        .out_ready(sb_out_ready), .out_valid(sb_out_valid),
        .out_pixel(sb_out_pixel)
    );

    assign sb_out_ready = image_ready;
    assign image_valid = sb_out_valid;
    assign image_pixel = sb_out_pixel;

    wire ft_last = (dec_count == WINDOW_DEC-1);
    Feature_Temporal #(.WIDTH(WIDTH), .FRAC(FRAC), .N_TAPS(8),
                       .MU_SHIFT(3), .N_LAGS(3)) u_temporal (
        .clk(clk), .rst(rst), .start(launch), .ready(ft_ready),
        .busy(ft_busy), .done(ft_done), .in_valid(dec_accept),
        .in_ready(ft_in_ready), .in_sample(dec_sample), .in_last(ft_last),
        .out_ready(ft_out_ready), .out_valid(ft_out_valid), .out_feature(ft_feature)
    );

    reg [3:0] feature_index;
    wire spectral_phase = (feature_index < 8);
    assign fs_out_ready = tree_in_ready && spectral_phase;
    assign ft_out_ready = tree_in_ready && !spectral_phase;
    wire tree_in_valid = spectral_phase ? fs_out_valid : ft_out_valid;
    wire signed [WIDTH-1:0] tree_in_feature = spectral_phase ? fs_feature : ft_feature;

    ML_Tree_Classifier #(.WIDTH(WIDTH), .N_FEATURES(12),
        .N_NOS(TREE_N_NODES), .PROF_MAX(9), .ARQ_ROM(TREE_ROM)) u_tree (
        .clk(clk), .rst(rst), .start(tree_start), .enable(enable),
        .ready(tree_ready), .busy(tree_busy), .done(tree_done),
        .in_valid(tree_in_valid), .in_ready(tree_in_ready),
        .in_feature(tree_in_feature), .out_ready(1'b1),
        .out_valid(class_valid), .out_class(class_out), .out_error(tree_error)
    );

    assign busy = !launched || (raw_count < RAW_SAMPLES) || fb_busy ||
                  ft_busy || fs_busy || tree_busy || sb_busy;

    reg tree_seen, cnn_seen;

    always @(posedge clk) begin
        if (rst) begin
            launched <= 1'b0;
            raw_count <= 0;
            dec_count <= 0;
            feature_index <= 0;
            tree_seen <= 1'b0;
            cnn_seen <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (launch) begin
                launched <= 1'b1;
                raw_count <= 0;
                dec_count <= 0;
                feature_index <= 0;
                tree_seen <= 1'b0;
                cnn_seen <= 1'b0;
            end else begin
                if (tree_done) tree_seen <= 1'b1;
                if (image_done) cnn_seen <= 1'b1;
                if ((tree_seen || tree_done) && (cnn_seen || image_done))
                    launched <= 1'b0;
                if (sample_valid && sample_ready) raw_count <= raw_count + 1'b1;
                if (dec_accept) dec_count <= dec_count + 1'b1;
                if (tree_in_valid && tree_in_ready) feature_index <= feature_index + 1'b1;
                if (tree_done) done <= 1'b1;
            end
        end
    end
endmodule
