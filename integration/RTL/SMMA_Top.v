`timescale 1ns / 1ps

// Integra a cadeia LMS -> FFT -> detector de picos -> MDC -> f0 e o caminho
// de features da arvore de decisao alimentado pelas amostras cruas.
// A CNN recebe o espectrograma da janela de vibracao por padrao; opcionalmente
// aceita pixels externos. O inversor recebe a matriz pela interface inv_*.
module SMMA_Top #(
    parameter WIDTH = 16,
    parameter FRAC = 15,
    parameter FFT_LOG2N = 6,
    parameter FS_WIDTH = 20,
    parameter INV_FRAC = 12,
    parameter signed [WIDTH-1:0] INV_EPSILON = 16'sd8,
    parameter TREE_N_NODES = 141,
    parameter AUTO_CNN_FROM_VIBRATION = 1,
    parameter USE_VIBRATION_ROM = 1,
    parameter DATA_ROM_SAMPLES = 8503,
    parameter DATA_ROM_RATE_DIV = 1953,
    parameter DATA_ROM_FAST = 0,
    parameter DATA_ROM_FILE = "vetores/vibration_input.hex"
)(
    input wire clk,
    input wire reset,
    input wire enable,
    input wire dataset_start,
    output wire dataset_busy,
    output wire dataset_done,

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

    // Interface manual/legada para fornecer features externamente.
    input wire tree_start,
    input wire tree_feature_valid,
    input wire signed [WIDTH-1:0] tree_feature,
    output wire tree_feature_ready,
    output wire tree_ready,
    output wire tree_busy,
    output wire tree_done,
    input wire tree_class_ready,
    output wire tree_class_valid,
    output wire [1:0] tree_class,
    output wire tree_error,

    // Caminho automatico da arvore: janela completa de vibracao em sample_x.
    output wire auto_tree_busy,
    output wire auto_tree_done,
    output wire auto_tree_class_valid,
    output wire [1:0] auto_tree_class,
    output wire auto_tree_error,
    output wire auto_cnn_busy,
    output wire auto_cnn_done,
    output wire auto_cnn_class_valid,
    output wire [1:0] auto_cnn_class,

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
    wire tree_source_ready;
    wire auto_window_start, auto_image_valid;
    wire [WIDTH-1:0] auto_image_pixel;
    wire cnn_core_ready, cnn_core_done;
    wire signed [WIDTH-1:0] lms_w0,lms_w1,lms_w2,lms_w3;
    wire signed [WIDTH-1:0] lms_w4,lms_w5,lms_w6,lms_w7;
    wire core_sample_valid, core_sample_start;
    wire signed [WIDTH-1:0] core_sample_x, core_sample_d;
    wire core_sample_ready;
    wire [31:0] rom_sample_word;
    wire rom_sample_valid, rom_sample_busy, rom_sample_done;
    wire lms_start = core_sample_start && core_sample_valid && core_sample_ready && enable;
    assign core_sample_ready = (state == S_IDLE) && enable && lms_ready && !lms_busy &&
                               tree_source_ready;
    assign analysis_busy = (state != S_IDLE) || lms_busy || (load_count != 0);

    generate if (USE_VIBRATION_ROM) begin : g_vibration_rom
        Vibration_ROM_Source #(.WIDTH(32), .N_SAMPLES(DATA_ROM_SAMPLES),
            .DIV_RATE(DATA_ROM_RATE_DIV), .FAST(DATA_ROM_FAST),
            .ROM_FILE(DATA_ROM_FILE)) u_source (
            .clk(clk), .rst(reset), .start(dataset_start),
            .busy(rom_sample_busy), .done(rom_sample_done),
            .out_ready(core_sample_ready), .out_valid(rom_sample_valid),
            .out_sample(rom_sample_word)
        );
        assign core_sample_valid = rom_sample_valid;
        assign core_sample_start = rom_sample_valid;
        assign core_sample_x = $signed(rom_sample_word[WIDTH-1:0]);
        assign core_sample_d = $signed(rom_sample_word[2*WIDTH-1:WIDTH]);
        assign sample_ready = 1'b0;
        assign dataset_busy = rom_sample_busy;
        assign dataset_done = rom_sample_done;
    end else begin : g_external_stream
        assign core_sample_valid = sample_valid;
        assign core_sample_start = sample_start;
        assign core_sample_x = sample_x;
        assign core_sample_d = sample_d;
        assign sample_ready = core_sample_ready;
        assign dataset_busy = 1'b0;
        assign dataset_done = 1'b0;
    end endgenerate

    LMS_Filter_Top #(.WIDTH(WIDTH), .FRAC(FRAC)) u_lms (
        .clk(clk), .rst(reset), .start(lms_start), .enable(enable),
        .valid_in(core_sample_valid && core_sample_start && core_sample_ready),
        .ready(lms_ready), .busy(lms_busy), .valid_out(lms_valid),
        .in_x(core_sample_x), .in_d(core_sample_d), .out_y(lms_y), .out_error(lms_error),
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
    // Preserve o escalonamento historico (/64) usado pela analise de picos.
    FFT_Top #(.WIDTH(WIDTH), .FRAC(FRAC), .LOG2N(FFT_LOG2N),
              .SCALE_MASK(6'b111111)) u_fft (
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

    // A mesma amostra aceita segue em paralelo ao pipeline original e ao
    // front-end da arvore (FIR/decimacao, 32 FFTs, 12 features e classificacao).
    SMMA_Tree_Feature_Pipeline #(.WIDTH(WIDTH), .FRAC(FRAC),
        .TREE_N_NODES(TREE_N_NODES), .FIR_COEF("vetores/fir_coef.hex"),
        .TREE_ROM("vetores/arvore.hex")) u_tree_pipeline (
        .clk(clk), .rst(reset), .enable(enable),
        .sample_valid(core_sample_valid && core_sample_start && core_sample_ready),
        .sample(core_sample_x), .sample_ready(tree_source_ready),
        .window_start(auto_window_start),
        .image_ready(AUTO_CNN_FROM_VIBRATION ? cnn_core_ready : 1'b1),
        .image_done(AUTO_CNN_FROM_VIBRATION ? cnn_core_done : 1'b1),
        .image_valid(auto_image_valid), .image_pixel(auto_image_pixel),
        .busy(auto_tree_busy), .done(auto_tree_done),
        .class_valid(auto_tree_class_valid), .class_out(auto_tree_class),
        .tree_error(auto_tree_error)
    );

    ML_Tree_Classifier #(
        .WIDTH(WIDTH), .N_FEATURES(12), .N_NOS(TREE_N_NODES),
        .PROF_MAX(9), .ARQ_ROM("vetores/arvore.hex")
    ) u_tree_classifier (
        .clk(clk), .rst(reset), .start(tree_start), .enable(enable),
        .ready(tree_ready), .busy(tree_busy), .done(tree_done),
        .in_valid(tree_feature_valid), .in_ready(tree_feature_ready),
        .in_feature(tree_feature), .out_ready(tree_class_ready),
        .out_valid(tree_class_valid), .out_class(tree_class),
        .out_error(tree_error)
    );

    wire cnn_core_start = AUTO_CNN_FROM_VIBRATION ? auto_window_start : cnn_start;
    wire cnn_core_valid = AUTO_CNN_FROM_VIBRATION ? auto_image_valid : cnn_pixel_valid;
    wire signed [WIDTH-1:0] cnn_core_pixel = AUTO_CNN_FROM_VIBRATION
                                             ? $signed(auto_image_pixel) : cnn_pixel;
    assign cnn_pixel_ready = AUTO_CNN_FROM_VIBRATION ? 1'b0 : cnn_core_ready;
    assign auto_cnn_busy = AUTO_CNN_FROM_VIBRATION ? cnn_busy : 1'b0;
    assign auto_cnn_done = AUTO_CNN_FROM_VIBRATION ? cnn_core_done : 1'b0;
    assign auto_cnn_class_valid = AUTO_CNN_FROM_VIBRATION ? cnn_valid : 1'b0;
    assign auto_cnn_class = cnn_class;
    CNN_Top #(.WIDTH(WIDTH), .FRAC(FRAC)) u_cnn (
        .clk(clk), .rst(reset), .start(cnn_core_start), .enable(enable),
        .in_valid(cnn_core_valid), .in_ready(cnn_core_ready),
        .busy(cnn_busy), .ready(), .done(cnn_core_done), .valid_out(cnn_valid),
        .in_pixel(cnn_core_pixel), .out_class(cnn_class), .out_scores(),
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
