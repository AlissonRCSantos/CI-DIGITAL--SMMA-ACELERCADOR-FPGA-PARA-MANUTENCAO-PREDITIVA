`timescale 1ns / 1ps

// Integra a cadeia LMS -> FFT -> detector de picos -> MDC -> f0.
// CNN e inversao de matriz sao subsistemas controlados por interfaces proprias:
// o projeto nao define um gerador de espectrograma nem a origem da matriz.
module SMMA_Top #(
    parameter WIDTH = 16,
    parameter FRAC = 15,
    parameter FFT_LOG2N = 6,
    parameter FS_WIDTH = 20,
    parameter INV_FRAC = 12,
    parameter signed [WIDTH-1:0] INV_EPSILON = 16'sd8
)(
    input wire clk,
    input wire reset,
    input wire enable,

    // Entrada de uma amostra LMS. start e valid devem estar altos juntos.
    input wire sample_start,
    input wire sample_valid,
    input wire signed [WIDTH-1:0] sample_x,
    input wire signed [WIDTH-1:0] sample_d,
    output wire sample_ready,
    output wire signed [WIDTH-1:0] lms_y,
    output wire signed [WIDTH-1:0] lms_error,
    output wire lms_valid,

    // Configuracao da analise espectral.
    input wire [WIDTH-1:0] peak_threshold,
    input wire [FFT_LOG2N-1:0] min_gcd_bin,
    input wire [FS_WIDTH-1:0] sample_rate_hz,
    output wire [FFT_LOG2N-1:0] fundamental_bin,
    output wire [FS_WIDTH-1:0] fundamental_hz_int,
    output wire [FFT_LOG2N-1:0] fundamental_hz_frac,
    output wire fundamental_valid,
    output wire gcd_error,
    output wire analysis_busy,
    output reg analysis_done,

    // CNN: recebe diretamente os 1024 pixels do espectrograma (raster).
    input wire cnn_start,
    input wire cnn_pixel_valid,
    input wire signed [WIDTH-1:0] cnn_pixel,
    output wire cnn_pixel_ready,
    output wire [1:0] cnn_class,
    output wire cnn_valid,
    output wire cnn_busy,

    // Inversor: carga sequencial/enderecada da matriz A, N=2..4.
    input wire inv_start,
    input wire [2:0] inv_n,
    input wire inv_valid_in,
    output wire inv_ready,
    input wire [1:0] inv_load_row,
    input wire [1:0] inv_load_col,
    input wire signed [WIDTH-1:0] inv_load_data,
    output wire inv_valid_out,
    output wire inv_busy,
    output wire inv_singular,
    input wire [1:0] inv_read_row,
    input wire [2:0] inv_read_col,
    output wire signed [WIDTH-1:0] inv_read_data
);

    localparam integer FFT_N = (1 << FFT_LOG2N);
    localparam [2:0] S_IDLE=3'd0, S_FFT_START=3'd1,
                     S_FFT_LOAD=3'd2, S_WAIT=3'd3;
    reg [2:0] state;
    reg signed [WIDTH-1:0] sample_buffer [0:FFT_N-1];
    reg [FFT_LOG2N-1:0] load_count;
    reg fft_finished, frequency_finished;

    wire lms_ready, lms_busy;
    wire signed [WIDTH-1:0] lms_w0,lms_w1,lms_w2,lms_w3;
    wire signed [WIDTH-1:0] lms_w4,lms_w5,lms_w6,lms_w7;
    wire lms_start = sample_start && sample_valid && sample_ready && enable;
    assign sample_ready = (state == S_IDLE) && enable && lms_ready && !lms_busy;
    assign analysis_busy = (state != S_IDLE) || lms_busy || (load_count != 0);

    LMS_Filter_Top #(.WIDTH(WIDTH), .FRAC(FRAC)) u_lms (
        .clk(clk), .rst(reset), .start(lms_start), .enable(enable),
        .valid_in(sample_valid && sample_start && sample_ready),
        .ready(lms_ready), .busy(lms_busy), .valid_out(lms_valid),
        .in_x(sample_x), .in_d(sample_d), .out_y(lms_y), .out_error(lms_error),
        .w0(lms_w0), .w1(lms_w1), .w2(lms_w2), .w3(lms_w3),
        .w4(lms_w4), .w5(lms_w5), .w6(lms_w6), .w7(lms_w7)
    );

    wire fft_start = (state == S_FFT_START);
    wire fft_in_valid = (state == S_FFT_LOAD);
    wire fft_in_ready, fft_ready, fft_busy, fft_done;
    wire fft_out_valid, fft_out_ready;
    wire [FFT_LOG2N-1:0] fft_out_index;
    wire signed [WIDTH-1:0] fft_out_real, fft_out_imag;
    wire [WIDTH-1:0] fft_out_mag;
    wire [2:0] fft_stage;
    FFT_Top #(.WIDTH(WIDTH), .FRAC(FRAC), .LOG2N(FFT_LOG2N)) u_fft (
        .clk(clk), .rst(reset), .start(fft_start), .enable(enable),
        .ready(fft_ready), .busy(fft_busy), .done(fft_done),
        .in_valid(fft_in_valid), .in_ready(fft_in_ready),
        .in_real(sample_buffer[load_count]), .in_imag({WIDTH{1'b0}}),
        .out_ready(fft_out_ready), .out_valid(fft_out_valid),
        .out_index(fft_out_index), .out_real(fft_out_real),
        .out_imag(fft_out_imag), .out_mag(fft_out_mag), .stage_dbg(fft_stage)
    );

    wire peak_start = fft_start;
    wire peak_busy, peak_done, peak_mag_ready, peak_valid, peak_ready;
    wire [FFT_LOG2N-1:0] peak_bin;
    peak_detector #(.FFT_N(FFT_N), .IDX_WIDTH(FFT_LOG2N),
                    .MAG_WIDTH(WIDTH), .NUM_PEAKS(3)) u_peak_detector (
        .clk(clk), .rst_n(!reset), .start(peak_start),
        .busy(peak_busy), .done(peak_done),
        .mag_valid(fft_out_valid), .mag_ready(peak_mag_ready),
        .mag_data(fft_out_mag), .cfg_threshold(peak_threshold),
        .out_valid(peak_valid), .out_ready(peak_ready), .out_data(peak_bin)
    );
    assign fft_out_ready = peak_mag_ready;

    wire mdc_busy, mdc_done, mdc_in_ready, mdc_valid, mdc_ready;
    wire [FFT_LOG2N-1:0] mdc_bin;
    wire mdc_start = fft_start;
    mdc_gcd #(.IDX_WIDTH(FFT_LOG2N), .NUM_PEAKS(3)) u_mdc (
        .clk(clk), .rst_n(!reset), .start(mdc_start), .busy(mdc_busy),
        .done(mdc_done), .in_valid(peak_valid), .in_ready(peak_ready),
        .in_data(peak_bin), .cfg_min_valid(min_gcd_bin),
        .out_valid(mdc_valid), .out_ready(mdc_ready), .out_data(mdc_bin),
        .out_error(gcd_error)
    );
    assign mdc_ready = f0_in_ready;
    assign fundamental_bin = mdc_bin;

    wire f0_in_ready, f0_busy, f0_done;
    f0_estimator #(.FFT_N(FFT_N), .IDX_WIDTH(FFT_LOG2N),
                   .FS_WIDTH(FS_WIDTH)) u_f0 (
        .clk(clk), .rst_n(!reset), .start(1'b0), .busy(f0_busy), .done(f0_done),
        .in_valid(mdc_valid), .in_ready(f0_in_ready), .in_data(mdc_bin),
        .cfg_fs(sample_rate_hz), .out_valid(fundamental_valid),
        .out_ready(enable), .f0_int(fundamental_hz_int),
        .f0_frac(fundamental_hz_frac)
    );

    CNN_Top #(.WIDTH(WIDTH), .FRAC(FRAC)) u_cnn (
        .clk(clk), .rst(reset), .start(cnn_start), .enable(enable),
        .in_valid(cnn_pixel_valid), .in_ready(cnn_pixel_ready),
        .busy(cnn_busy), .ready(), .done(), .valid_out(cnn_valid),
        .in_pixel(cnn_pixel), .out_class(cnn_class), .out_scores(),
        .out_features()
    );

    gauss_jordan_inv #(.WIDTH(WIDTH), .FRAC(INV_FRAC), .N_MAX(4),
                       .EPSILON(INV_EPSILON)) u_matrix_inverse (
        .clk(clk), .reset(reset), .enable(enable), .start(inv_start), .n(inv_n),
        .valid_in(inv_valid_in), .ready(inv_ready),
        .load_row(inv_load_row), .load_col(inv_load_col), .load_data(inv_load_data),
        .valid_out(inv_valid_out), .busy(inv_busy), .singular(inv_singular),
        .read_row(inv_read_row), .read_col(inv_read_col), .read_data(inv_read_data)
    );

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            load_count <= {FFT_LOG2N{1'b0}};
            fft_finished <= 1'b0;
            frequency_finished <= 1'b0;
            analysis_done <= 1'b0;
        end else begin
            analysis_done <= 1'b0;
            if (lms_valid && state == S_IDLE) begin
                sample_buffer[load_count] <= lms_y;
                if (load_count == FFT_N-1) begin
                    load_count <= {FFT_LOG2N{1'b0}};
                    state <= S_FFT_START;
                    fft_finished <= 1'b0;
                    frequency_finished <= 1'b0;
                end else load_count <= load_count + 1'b1;
            end
            case (state)
                S_IDLE: begin end
                S_FFT_START: state <= S_FFT_LOAD;
                S_FFT_LOAD: if (fft_in_valid && fft_in_ready) begin
                    if (load_count == FFT_N-1) begin
                        load_count <= {FFT_LOG2N{1'b0}};
                        state <= S_WAIT;
                    end else load_count <= load_count + 1'b1;
                end
                S_WAIT: begin
                    if (fft_done) fft_finished <= 1'b1;
                    if (f0_done) frequency_finished <= 1'b1;
                    if ((fft_finished || fft_done) && (frequency_finished || f0_done)) begin
                        state <= S_IDLE;
                        analysis_done <= 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
