// ============================================================================
// Module: SMMA_Top
// Description: Top level do SMMA -- Smart Machine Monitoring Accelerator.
//              Acelerador em FPGA para manutencao preditiva de motores
//              industriais (PBL de Circuitos Digitais IV).
//
//              Alvo: DE0-CV, Cyclone V 5CEBA4F23C7N, 50 MHz.
//
// ============================================================================
// ARQUITETURA (diagrama do grupo, com os blocos obrigatorios que faltavam)
// ============================================================================
//
//  Xa --> Sample_Source --> FIR_Decimator --> [ LMS ] --> DATA BUS DRIVER
//         (sensor emulado)  (anti-alias, /8)  LMS_Stage    Data_Bus_Driver
//                                             <-> LMS_Filter_Top   |
//                                                  |               |
//              r_lms ------------------------------+               |
//                                                                  |
//   +--------------------------------------------------------------+
//   |                                                              |
//   v  ramo FFT                                                    v  ramo matriz
//  MEM_A ----------> FFT --------------> MEM_B                  coefficient
//  Frame_Builder     FFT_Top             Spectrum_Accumulator   accumulator
//  (64 amostras)     (64 pts)       |    (espectro medio)       autocorrelacao_yw
//                                   |        |      |               |
//                                   |  PEAK  |      | bandas        v
//                                   | DETECT.|      | BPFO/BPFI  GAUSS_JORDAN
//                                   |  peak_ |      | Feature_   Yule_Walker_Solver
//                                   | detector      | Spectral   <-> gauss_jordan_inv
//                                   |    |          |               |
//                                   | EUCLIDES      |               |
//                                   | mdc_gcd ->    |               |
//                                   | f0_estimator  |               |
//                                   |    |          |               |
//                                   |    +----------+---> PARAMETER REGFILE <--+
//                                   |                     Parameter_RegFile
//                                   |                          |
//                                   |                    DECISION TREE
//                                   |                    ML_Tree_Classifier
//                                   v                          |
//                       FFT_Log2_Compress -> Spectrogram_Buffer -> CNN_Top
//                                                              |       |
//                              SMMA_Global_Control  ---->  SMMA_Panel (HEX/LEDR)
//
//   Acrescentados ao diagrama (obrigatorios pelo enunciado ou pela fisica):
//     FIR_Decimator     sem decimacao a FFT de 64 pts teria bins de 400 Hz e
//                       todas as frequencias de falha cairiam no bin 0
//     f0_estimator      converte o k0 do Euclides em frequencia (3.1)
//     ramo CNN          acelerador CNN obrigatorio (3.6 e secao 4)
//     controle/painel   unidade de controle global e interface de saida (4)
//
// ============================================================================
// PAINEL (DE0-CV) -- ver SMMA_Panel.v
// ============================================================================
//   KEY[0]   reset (ativo em baixo na placa, invertido aqui)
//   KEY[1]   dispara uma janela
//   SW[3:0]  escolhe a janela do dataset (0..11)
//   SW[8]    1 = mostra f0 (MDC) em Hz nos HEX3..HEX0
//   SW[9]    1 = mostra os scores da CNN nos LEDs em vez do estado
// ============================================================================

`timescale 1ns / 1ps

module SMMA_Top #(
    parameter WIDTH       = 16,
    parameter FRAC        = 15,
    parameter NFFT        = 64,
    parameter HOP         = 32,
    parameter N_BINS      = 32,
    parameter N_QUADROS   = 32,
    parameter N_NOS       = 141,     // nos em vetores/arvore.hex
    parameter FS_DEC      = 3200,    // taxa apos a decimacao (Hz)
    parameter PICO_LIMIAR = 16'd64,  // limiar do detector de picos (|X| medio)
    parameter MDC_MIN     = 6'd1,    // menor k0 aceito pelo MDC
    parameter SAIDA_LMS   = 0,       // 0: barramento recebe x(n) do FIR; 1: y(n) do LMS
    parameter MODO_RAPIDO = 0        // 1 = ignora a taxa de 25,6 kHz (simulacao)
)(
    input  wire        CLOCK_50,
    input  wire [1:0]  KEY,          // ativo em BAIXO na placa
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);

    localparam L_JANELA = (N_QUADROS-1)*HOP + NFFT;      // 1056 amostras
    localparam [19:0] FS_DEC_20 = FS_DEC;                // largura da porta cfg_fs

    wire clk = CLOCK_50;

    // ------------------------------------------------------------------------
    // Reset e disparo
    //
    // Os botoes da DE0-CV sao ativos em baixo; o projeto todo usa reset
    // sincrono ativo em ALTO, entao a inversao acontece aqui, uma unica vez.
    // Dois registradores de sincronizacao: KEY e assincrono ao CLOCK_50.
    // ------------------------------------------------------------------------
    reg [1:0] key_s0, key_s1, key_s2;
    always @(posedge clk) begin
        key_s0 <= ~KEY;
        key_s1 <= key_s0;
        key_s2 <= key_s1;
    end
    wire rst     = key_s1[0];
    wire disparo = key_s1[1] && !key_s2[1];     // borda de subida, 1 ciclo

    // Start comum a todos os blocos da janela (gerado pelo controle global)
    wire arranca;

    // ========================================================================
    // INTERFACE DE ENTRADA DOS SENSORES (Xa: acelerometro x do mancal A)
    // ========================================================================
    wire                     src_busy, src_done, src_valid, src_ready;
    wire signed [WIDTH-1:0]  src_sample;
    wire [1:0]               classe_verdadeira, classe_modelo;

    Sample_Source #(
        .WIDTH(WIDTH), .MODO_RAPIDO(MODO_RAPIDO)
    ) u_src (
        .clk(clk), .rst(rst), .start(arranca), .janela(SW[3:0]),
        .busy(src_busy), .done(src_done),
        .out_ready(src_ready), .out_valid(src_valid), .out_sample(src_sample),
        .classe_verdadeira(classe_verdadeira),
        .classe_esperada(classe_modelo)
    );

    // FIR anti-alias + decimacao /8  ->  3,2 kHz
    wire                     dec_valid, dec_ready;
    wire signed [WIDTH-1:0]  dec_sample;
    wire                     fir_overflow;

    FIR_Decimator #(
        .WIDTH(WIDTH), .FRAC(FRAC)
    ) u_fir (
        .clk(clk), .rst(rst), .limpa(arranca),
        .in_valid(src_valid), .in_ready(src_ready), .in_sample(src_sample),
        .out_ready(dec_ready), .out_valid(dec_valid), .out_sample(dec_sample),
        .overflow(fir_overflow)
    );

    // ========================================================================
    // MODULO LMS (EM SERIE): toda amostra filtrada pelo FIR atravessa o LMS
    // antes de chegar ao barramento de dados.
    //
    //   FIR_Decimator -> LMS_Stage <-> LMS_Filter_Top -> Data_Bus_Driver
    //
    // SAIDA_LMS = 0: o barramento recebe a amostra filtrada pelo FIR, que e o
    // sinal com que a arvore e a CNN foram treinadas (resultado identico ao
    // validado). Com SAIDA_LMS = 1 o barramento passa a receber y(n), a saida
    // do filtro adaptativo -- exige retreinar os dois classificadores.
    // ========================================================================
    wire                     ls_ready, ls_busy, ls_done;
    wire                     ls_out_valid, ls_out_ready;
    wire signed [WIDTH-1:0]  ls_out_sample;
    wire                     ls_feat_valid, ls_feat_ready;
    wire signed [WIDTH-1:0]  ls_feat_lms;

    wire                     lms_clear, lms_start;
    wire signed [WIDTH-1:0]  lms_x, lms_d, lms_y, lms_error;
    wire                     lms_busy, lms_valid_out;

    LMS_Filter_Top #(
        .WIDTH(WIDTH), .FRAC(FRAC), .MU_SHIFT(3)
    ) u_lms (
        .clk(clk), .rst(rst || lms_clear),
        .start(lms_start), .enable(1'b1), .valid_in(lms_start),
        .ready(), .busy(lms_busy), .valid_out(lms_valid_out),
        .in_x(lms_x), .in_d(lms_d),
        .out_y(lms_y), .out_error(lms_error),
        .w0(), .w1(), .w2(), .w3(), .w4(), .w5(), .w6(), .w7()
    );

    LMS_Stage #(
        .WIDTH(WIDTH), .FRAC(FRAC), .N_AMOSTRAS(L_JANELA), .SAIDA_LMS(SAIDA_LMS)
    ) u_lms_stage (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(ls_ready), .busy(ls_busy), .done(ls_done),
        .in_valid(dec_valid), .in_ready(dec_ready), .in_sample(dec_sample),
        .out_ready(ls_out_ready), .out_valid(ls_out_valid), .out_sample(ls_out_sample),
        .lms_clear(lms_clear), .lms_start(lms_start),
        .lms_x(lms_x), .lms_d(lms_d),
        .lms_busy(lms_busy), .lms_valid_out(lms_valid_out),
        .lms_y(lms_y), .lms_error(lms_error),
        .feat_ready(ls_feat_ready), .feat_valid(ls_feat_valid), .feat_lms(ls_feat_lms)
    );

    // ========================================================================
    // DATA BUS DRIVER: dados filtrados -> MEM_A/FFT e acumulador/Gauss-Jordan
    // ========================================================================
    wire signed [WIDTH-1:0]  bus_sample;
    wire                     fb_in_valid, ac_in_valid;
    wire                     fb_in_ready, ac_in_ready;

    Data_Bus_Driver #(.WIDTH(WIDTH), .N_DEST(2)) u_bus (
        .in_valid (ls_out_valid),
        .in_ready (ls_out_ready),
        .in_sample(ls_out_sample),
        .out_valid({ac_in_valid, fb_in_valid}),
        .out_ready({ac_in_ready, fb_in_ready}),
        .out_sample(bus_sample)
    );

    // ========================================================================
    // MEM_A -- buffer de amostras da FFT: quadros de 64 pontos, salto 32
    // ========================================================================
    wire                     fb_ready, fb_busy, fb_done;
    wire                     fb_out_valid, fb_out_ready;
    wire signed [WIDTH-1:0]  fb_out_sample;
    wire                     fb_frame_ini, fb_frame_fim;

    Frame_Builder #(
        .WIDTH(WIDTH), .NFFT(NFFT), .HOP(HOP), .N_QUADROS(N_QUADROS)
    ) u_fb (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(fb_ready), .busy(fb_busy), .done(fb_done),
        .in_valid(fb_in_valid), .in_ready(fb_in_ready), .in_sample(bus_sample),
        .out_ready(fb_out_ready), .out_valid(fb_out_valid),
        .out_sample(fb_out_sample),
        .out_frame_ini(fb_frame_ini), .out_frame_fim(fb_frame_fim)
    );

    // ========================================================================
    // MODULO FFT (64 pontos, radix-2 DIT, Q1.15, ganho /16)
    //
    // A FFT_Top so levanta in_ready em S_LOAD, isto e, DEPOIS do pulso de
    // start. O quadro fica retido ate a transformada estar armada.
    // ========================================================================
    wire                     fft_ready, fft_busy, fft_done, fft_in_ready;
    wire                     fft_out_valid, fft_out_ready;
    wire [5:0]               fft_out_index;
    wire [WIDTH-1:0]         fft_out_mag;

    reg  fft_armada;
    wire fft_start = fb_out_valid && fb_frame_ini && fft_ready && !fft_armada;

    always @(posedge clk) begin
        if (rst)                fft_armada <= 1'b0;
        else if (fft_start)     fft_armada <= 1'b1;
        else if (fb_out_valid && fb_out_ready && fb_frame_fim)
                                fft_armada <= 1'b0;
    end

    assign fb_out_ready = fft_armada && fft_in_ready;

    FFT_Top #(
        .WIDTH(WIDTH), .FRAC(FRAC), .LOG2N(6), .SCALE_MASK(6'b001111)
    ) u_fft (
        .clk(clk), .rst(rst), .start(fft_start), .enable(1'b1),
        .ready(fft_ready), .busy(fft_busy), .done(fft_done),
        .in_valid(fb_out_valid && fft_armada), .in_ready(fft_in_ready),
        .in_real(fb_out_sample), .in_imag({WIDTH{1'b0}}),
        .out_ready(fft_out_ready), .out_valid(fft_out_valid),
        .out_index(fft_out_index),
        .out_real(), .out_imag(), .out_mag(fft_out_mag), .stage_dbg()
    );

    // ------------------------------------------------------------------------
    // Fork (b): |X[k]| dos bins uteis -> espectro medio + espectrograma
    //
    // Sinal real: so os bins 0..31 carregam informacao. Os bins 32..63 sao
    // ACEITOS e descartados (deixar de aceita-los travaria a FFT).
    // ------------------------------------------------------------------------
    wire bin_util = (fft_out_index < N_BINS);
    wire bin_fork_ready;
    wire sa_in_valid, lg_in_valid;
    wire sa_in_ready, sb_in_ready;

    Stream_Fork #(.N(2)) u_fork_bin (
        .in_valid (fft_out_valid && bin_util),
        .in_ready (bin_fork_ready),
        .out_valid({lg_in_valid, sa_in_valid}),
        .out_ready({sb_in_ready, sa_in_ready})
    );

    assign fft_out_ready = bin_util ? bin_fork_ready : 1'b1;

    // ========================================================================
    // MEM_B -- memoria de espectros: espectro medio dos 32 quadros
    // ========================================================================
    wire              sa_ready, sa_busy, sa_done;
    wire              sa_out_valid, sa_out_ready;
    wire [5:0]        sa_out_bin;
    wire [WIDTH-1:0]  sa_out_mag;

    Spectrum_Accumulator #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) u_sa (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(sa_ready), .busy(sa_busy), .done(sa_done),
        .in_valid(sa_in_valid), .in_ready(sa_in_ready), .in_mag(fft_out_mag),
        .out_ready(sa_out_ready), .out_valid(sa_out_valid),
        .out_bin(sa_out_bin), .out_mag(sa_out_mag)
    );

    // ------------------------------------------------------------------------
    // Fork (c): espectro medio -> features espectrais + detector de picos
    // ------------------------------------------------------------------------
    wire fs_in_valid, pk_in_valid;
    wire fs_in_ready, pk_in_ready;

    Stream_Fork #(.N(2)) u_fork_esp (
        .in_valid (sa_out_valid),
        .in_ready (sa_out_ready),
        .out_valid({pk_in_valid, fs_in_valid}),
        .out_ready({pk_in_ready, fs_in_ready})
    );

    // ========================================================================
    // Caracteristicas espectrais (8), inclusive as bandas de BPFO/BPFI
    // ========================================================================
    wire                     fs_ready, fs_busy, fs_done;
    wire                     fs_out_valid, fs_out_ready;
    wire signed [WIDTH-1:0]  fs_out_feature;

    Feature_Spectral #(
        .WIDTH(WIDTH), .N_BINS(N_BINS)
    ) u_fs (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(fs_ready), .busy(fs_busy), .done(fs_done),
        .in_valid(fs_in_valid), .in_ready(fs_in_ready), .in_mag(sa_out_mag),
        .out_ready(fs_out_ready), .out_valid(fs_out_valid),
        .out_feature(fs_out_feature)
    );

    // ========================================================================
    // PEAK DETECTOR -> EUCLIDES (MDC) -> frequencia fundamental
    //
    //   peak_detector : 3 maiores maximos locais acima de PICO_LIMIAR no
    //                   espectro medio (bins 1..30)
    //   mdc_gcd       : k0 = MDC(picos), Euclides por subtracoes
    //   f0_estimator  : f0 = k0 * fs / N  (N = 64 -> divisao por deslocamento)
    // ========================================================================
    wire              pk_busy, pk_done;
    wire              pk_out_valid, pk_out_ready;
    wire [5:0]        pk_out_data;

    peak_detector #(
        .FFT_N(N_BINS), .IDX_WIDTH(6), .MAG_WIDTH(WIDTH), .NUM_PEAKS(3),
        .SEARCH_START(1), .SEARCH_END(N_BINS-2)
    ) u_peak (
        .clk(clk), .rst_n(!rst),
        .start(arranca), .busy(pk_busy), .done(pk_done),
        .mag_valid(pk_in_valid), .mag_ready(pk_in_ready), .mag_data(sa_out_mag),
        .cfg_threshold(PICO_LIMIAR),
        .out_valid(pk_out_valid), .out_ready(pk_out_ready), .out_data(pk_out_data)
    );

    wire              mdc_busy, mdc_done;
    wire              mdc_out_valid, mdc_out_ready, mdc_out_error;
    wire [5:0]        mdc_k0;

    mdc_gcd #(
        .IDX_WIDTH(6), .NUM_PEAKS(3)
    ) u_mdc (
        .clk(clk), .rst_n(!rst),
        .start(arranca), .busy(mdc_busy), .done(mdc_done),
        .in_valid(pk_out_valid), .in_ready(pk_out_ready), .in_data(pk_out_data),
        .cfg_min_valid(MDC_MIN),
        .out_valid(mdc_out_valid), .out_ready(mdc_out_ready),
        .out_data(mdc_k0), .out_error(mdc_out_error)
    );

    wire              f0_busy, f0_done;
    wire              f0_out_valid, f0_out_ready;
    wire [19:0]       f0_int;
    wire [5:0]        f0_frac;

    f0_estimator #(
        .FFT_N(NFFT), .IDX_WIDTH(6), .FS_WIDTH(20)
    ) u_f0 (
        .clk(clk), .rst_n(!rst),
        .start(1'b0), .busy(f0_busy), .done(f0_done),
        .in_valid(mdc_out_valid), .in_ready(mdc_out_ready), .in_data(mdc_k0),
        .cfg_fs(FS_DEC_20),
        .out_valid(f0_out_valid), .out_ready(f0_out_ready),
        .f0_int(f0_int), .f0_frac(f0_frac)
    );

    // Erro do MDC acompanha o k0 ate a saida do f0_estimator
    reg k0_erro;
    always @(posedge clk) begin
        if (rst || arranca)                      k0_erro <= 1'b0;
        else if (mdc_out_valid && mdc_out_ready) k0_erro <= mdc_out_error;
    end

    // f0 entregue ao classificador: Hz inteiro, saturado; 0 se o MDC falhou
    wire signed [WIDTH-1:0] f0_feature =
        k0_erro                  ? {WIDTH{1'b0}} :
        (f0_int > 20'd32767)     ? 16'sd32767    : $signed(f0_int[WIDTH-1:0]);

    // f0 registrado para o painel
    reg [13:0] r_f0_hz;
    reg        r_f0_erro;
    always @(posedge clk) begin
        if (rst || arranca) begin
            r_f0_hz   <= 14'd0;
            r_f0_erro <= 1'b0;
        end else if (f0_out_valid && f0_out_ready) begin
            r_f0_hz   <= (f0_int > 20'd9999) ? 14'd9999 : f0_int[13:0];
            r_f0_erro <= k0_erro;
        end
    end

    // ========================================================================
    // COEFFICIENT ACCUMULATOR -> GAUSS_JORDAN (estimacao de parametros)
    //
    //   autocorrelacao_yw  : rho[0..3] da janela      -> matriz de Toeplitz
    //   Yule_Walker_Solver : carrega R, a = R^-1 r     (controle + MAC)
    //   gauss_jordan_inv   : R^-1 por Gauss-Jordan com pivotamento parcial
    // ========================================================================
    wire                     ac_ready, ac_busy;
    wire                     ac_r_valid;
    wire [2:0]               ac_r_index;
    wire signed [WIDTH-1:0]  ac_r_data;

    autocorrelacao_yw #(
        .WIDTH(WIDTH), .FRAC(FRAC), .N_AMOSTRAS(L_JANELA), .N_LAGS(3)
    ) u_ac (
        .clk(clk), .reset(rst),
        .start(arranca), .ready(ac_ready), .busy(ac_busy),
        .lms_valid(ac_in_valid), .lms_ready(ac_in_ready), .lms_data(bus_sample),
        .r_valid(ac_r_valid), .r_index(ac_r_index), .r_data(ac_r_data)
    );

    localparam W_INV = 24, F_INV = 16;

    wire                     yw_ready, yw_busy, yw_done, yw_singular;
    wire                     yw_out_valid, yw_out_ready;
    wire signed [WIDTH-1:0]  yw_out_feature;

    wire                     inv_valid_in, inv_ready, inv_start;
    wire                     inv_valid_out, inv_busy, inv_singular;
    wire [1:0]               inv_load_row, inv_load_col, inv_read_row;
    wire [2:0]               inv_n, inv_read_col;
    wire signed [W_INV-1:0]  inv_load_data, inv_read_data;

    Yule_Walker_Solver #(
        .WIDTH(WIDTH), .W_INV(W_INV), .F_INV(F_INV), .ORDEM(3)
    ) u_yw (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(yw_ready), .busy(yw_busy), .done(yw_done),
        .r_valid(ac_r_valid), .r_index(ac_r_index), .r_data(ac_r_data),
        .inv_valid_in(inv_valid_in), .inv_ready(inv_ready),
        .inv_load_row(inv_load_row), .inv_load_col(inv_load_col),
        .inv_load_data(inv_load_data),
        .inv_start(inv_start), .inv_n(inv_n),
        .inv_valid_out(inv_valid_out), .inv_singular(inv_singular),
        .inv_read_row(inv_read_row), .inv_read_col(inv_read_col),
        .inv_read_data(inv_read_data),
        .out_ready(yw_out_ready), .out_valid(yw_out_valid),
        .out_feature(yw_out_feature), .singular(yw_singular)
    );

    gauss_jordan_inv #(
        .WIDTH(W_INV), .FRAC(F_INV), .N_MAX(4), .EPSILON(24'sd128)
    ) u_inv (
        .clk(clk), .reset(rst), .enable(1'b1), .start(inv_start),
        .n(inv_n),
        .valid_in(inv_valid_in), .ready(inv_ready),
        .load_row(inv_load_row), .load_col(inv_load_col),
        .load_data(inv_load_data),
        .valid_out(inv_valid_out), .busy(inv_busy), .singular(inv_singular),
        .read_row(inv_read_row), .read_col(inv_read_col),
        .read_data(inv_read_data)
    );

    // ========================================================================
    // PARAMETER REGFILE: vetor de caracteristicas do classificador
    // ========================================================================
    wire                     col_ready, col_busy, col_done;
    wire                     col_out_valid, col_out_ready;
    wire signed [WIDTH-1:0]  col_out_feature;

    Parameter_RegFile #(.WIDTH(WIDTH)) u_regfile (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(col_ready), .busy(col_busy), .done(col_done),
        .esp_valid(fs_out_valid), .esp_ready(fs_out_ready), .esp_data(fs_out_feature),
        .lms_valid(ls_feat_valid), .lms_ready(ls_feat_ready), .lms_data(ls_feat_lms),
        .r_valid(ac_r_valid), .r_index(ac_r_index), .r_data(ac_r_data),
        .f0_valid(f0_out_valid), .f0_ready(f0_out_ready), .f0_data(f0_feature),
        .ar_valid(yw_out_valid), .ar_ready(yw_out_ready), .ar_data(yw_out_feature),
        .out_ready(col_out_ready), .out_valid(col_out_valid),
        .out_feature(col_out_feature)
    );

    // ========================================================================
    // DECISION TREE (acelerador de Machine Learning)
    // ========================================================================
    wire        tree_start, tree_ready, tree_busy, tree_done;
    wire        tree_out_valid, tree_out_error;
    wire [1:0]  tree_class;

    ML_Tree_Classifier #(
        .WIDTH(WIDTH), .N_FEATURES(16), .N_NOS(N_NOS)
    ) u_tree (
        .clk(clk), .rst(rst), .start(tree_start), .enable(1'b1),
        .ready(tree_ready), .busy(tree_busy), .done(tree_done),
        .in_valid(col_out_valid), .in_ready(col_out_ready),
        .in_feature(col_out_feature),
        .out_ready(1'b1), .out_valid(tree_out_valid),
        .out_class(tree_class), .out_error(tree_out_error)
    );

    // ========================================================================
    // ESPECTROGRAMA + ACELERADOR CNN
    //
    // O 'en' do compressor serve de skid de um nivel: com en = sb_in_ready, o
    // pixel registrado so e substituido quando o buffer puder receber.
    // ========================================================================
    wire             log2_valid;
    wire [WIDTH-1:0] log2_pixel;

    FFT_Log2_Compress #(.WIDTH(WIDTH)) u_log2 (
        .clk(clk), .rst(rst), .en(sb_in_ready),
        .in_valid(lg_in_valid), .in_mag(fft_out_mag),
        .out_valid(log2_valid), .out_pixel(log2_pixel)
    );

    wire             sb_ready, sb_busy, sb_done;
    wire             sb_out_valid, sb_out_ready;
    wire [WIDTH-1:0] sb_out_pixel;

    Spectrogram_Buffer #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) u_sb (
        .clk(clk), .rst(rst), .start(arranca),
        .ready(sb_ready), .busy(sb_busy), .done(sb_done),
        .in_valid(log2_valid), .in_ready(sb_in_ready), .in_pixel(log2_pixel),
        .out_ready(sb_out_ready), .out_valid(sb_out_valid),
        .out_pixel(sb_out_pixel)
    );

    wire        cnn_ready, cnn_busy, cnn_done, cnn_valid;
    wire [1:0]  cnn_class;
    wire signed [WIDTH-1:0] cnn_in_pixel = sb_out_pixel;   // pixel log2 >= 0
    wire [4*WIDTH-1:0] cnn_scores;

    CNN_Top #(
        .WIDTH(WIDTH), .FRAC(FRAC), .IMG_W(N_QUADROS), .IMG_H(N_BINS)
    ) u_cnn (
        .clk(clk), .rst(rst), .start(arranca), .enable(1'b1),
        .in_valid(sb_out_valid), .in_ready(sb_out_ready),
        .in_pixel(cnn_in_pixel),
        .busy(cnn_busy), .ready(cnn_ready), .done(cnn_done),
        .valid_out(cnn_valid),
        .out_class(cnn_class), .out_scores(cnn_scores), .out_features()
    );

    // ========================================================================
    // UNIDADE DE CONTROLE GLOBAL
    // ========================================================================
    wire todos_prontos = fb_ready && sa_ready && fs_ready && sb_ready
                      && ls_ready && ac_ready && yw_ready && col_ready
                      && !pk_busy && !mdc_busy && !f0_busy
                      && tree_ready && cnn_ready;

    wire [1:0] r_tree_class, r_cnn_class, r_verdadeira;
    wire       r_tree_err, r_valido, ocupado;

    SMMA_Global_Control u_ctrl (
        .clk(clk), .rst(rst),
        .disparo(disparo), .todos_prontos(todos_prontos),
        .fb_done(fb_done),
        .tree_out_valid(tree_out_valid), .tree_class(tree_class),
        .tree_out_error(tree_out_error),
        .cnn_valid(cnn_valid), .cnn_class(cnn_class),
        .classe_verdadeira(classe_verdadeira),
        .arranca(arranca), .tree_start(tree_start),
        .r_tree_class(r_tree_class), .r_cnn_class(r_cnn_class),
        .r_verdadeira(r_verdadeira), .r_tree_err(r_tree_err),
        .r_valido(r_valido), .ocupado(ocupado)
    );

    // ========================================================================
    // INTERFACE DE SAIDA DA CLASSIFICACAO
    // ========================================================================
    SMMA_Panel u_panel (
        .SW(SW),
        .r_valido(r_valido), .r_tree_class(r_tree_class),
        .r_cnn_class(r_cnn_class), .r_verdadeira(r_verdadeira),
        .r_tree_err(r_tree_err), .fir_overflow(fir_overflow),
        .classe_modelo(classe_modelo), .cnn_scores_lsb(cnn_scores[3:0]),
        .ocupado(ocupado),
        .f0_hz(r_f0_hz), .f0_erro(r_f0_erro),
        .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

endmodule
