// ============================================================================
// Module: CNN_Top
// Description: Topo do acelerador CNN do SMMA (Smart Machine Monitoring
//              Accelerator). Recebe um espectrograma 32x32 do sinal de
//              vibracao (1 pixel por ciclo, ordem raster) e devolve a classe
//              de estado do motor.
//
// ARQUITETURA COMPLETA (fluxo da esquerda para a direita)
// -------------------------------------------------------
//
//  in_pixel                                                          out_class
//  (Q1.15)                                                             (2 bits)
//     |                                                                    ^
//     v                                                                    |
//  +-----------------+   janela 3x3   +----------------+  8 canais         |
//  | CNN_Line_Buffer |--------------->| CNN_Conv_Layer |------------+      |
//  |  2 line buffers |  win_valid/    | 8 MAC paralelos|  out_valid |      |
//  |  padding = 1    |  win_ready     | + bias + ReLU  |            |      |
//  +-----------------+                +----------------+            |      |
//        ^                                    ^                     v      |
//        | push_en                            |          +--------------+  |
//        |                            +---------------+  | CNN_MaxPool  |  |
//        |                            | CNN_Weight_ROM|  |   2x2 / s2   |  |
//        |                            +---------------+  +--------------+  |
//        |                                                       |         |
//  +--------------------+                                        v         |
//  |  CNN_Control_FSM   |                        +-------------------------+--+
//  |  IDLE/STREAM/DRAIN |                        |  CNN_Dense_Classifier      |
//  |  /DENSE/FINISH     |----------------------->|  GAP -> densa 8x4 -> argmax|
//  +--------------------+   dense_run            +----------------------------+
//
// DIMENSOES DOS TENSORES
//   entrada         : 32 x 32 x 1   =  1024 valores
//   conv 3x3 + ReLU : 32 x 32 x 8   =  8192 valores  (padding 1 mantem 32x32)
//   max pool 2x2    : 16 x 16 x 8   =  2048 valores
//   GAP             :  1 x  1 x 8   =     8 valores
//   densa           :          4    =     4 scores
//   argmax          :          1    =  classe (0..3)
//
// CLASSES DE SAIDA
//   0 = operacao normal
//   1 = desbalanceamento
//   2 = desalinhamento
//   3 = desgaste de rolamento
//
// FORMATO NUMERICO: ponto fixo Q1.15 em toda a cadeia de dados; acumuladores
// internos em Q?.30 com 8 bits de guarda (40 bits) para nao perder precisao
// antes do reescalonamento final.
// ============================================================================

`timescale 1ns / 1ps

module CNN_Top #(
    parameter WIDTH       = 16,   // Largura da palavra (Q1.15)
    parameter FRAC        = 15,   // Bits fracionarios
    parameter ACC_W       = 40,   // Largura dos acumuladores MAC
    parameter IMG_W       = 32,   // Largura da imagem de entrada
    parameter IMG_H       = 32,   // Altura da imagem de entrada
    parameter NUM_FILTERS = 8,    // Filtros da camada convolucional
    parameter NUM_CLASSES = 4,    // Classes de saida
    parameter CNT_W       = 6,    // Bits dos contadores de varredura
    parameter GAP_SHIFT   = 8     // log2((IMG_W/2)*(IMG_H/2)) = log2(256)
)(
    input  wire                          clk,        // Clock (50 MHz)
    input  wire                          rst,        // Reset sincrono ativo alto

    // ---- Handshake de controle ----
    input  wire                          start,      // Pulso: processa uma imagem
    input  wire                          enable,     // Habilitacao global
    input  wire                          in_valid,   // Pixel valido
    output wire                          in_ready,   // Aceito o pixel agora
    output wire                          busy,       // Processando
    output wire                          ready,      // Pronto para nova imagem
    output wire                          done,       // Terminou
    output wire                          valid_out,  // Pulso: resultado valido

    // ---- Dados ----
    input  wire signed [WIDTH-1:0]       in_pixel,   // Pixel do espectrograma

    output wire [1:0]                    out_class,  // Classe predita (0..3)
    output wire [NUM_CLASSES*WIDTH-1:0]  out_scores, // Scores brutos (debug)
    output wire [NUM_FILTERS*WIDTH-1:0]  out_features// Features do GAP (debug)
);

    localparam NUM_POOL   = (IMG_W/2) * (IMG_H/2);
    localparam POOL_IDX_W = 4;   // log2(IMG_W/2) = log2(16)

    // ========================================================================
    // Fios de interligacao
    // ========================================================================
    // FSM -> datapath
    wire                          frame_start;
    wire                          push_en;
    wire                          dense_run;

    // Line buffer -> FSM / convolucao
    wire                          need_pixel;
    wire                          last_push;
    wire [9*WIDTH-1:0]            win_data;
    wire                          win_valid;
    wire                          win_ready;
    wire [CNT_W-1:0]              win_row, win_col;

    // Convolucao -> pooling
    wire                          conv_valid;
    wire [NUM_FILTERS*WIDTH-1:0]  conv_data;

    // Pooling -> classificador
    wire                          pool_valid;
    wire [NUM_FILTERS*WIDTH-1:0]  pool_data;

    // Classificador -> FSM
    wire                          dense_valid;

    // ------------------------------------------------------------------------
    // Handshake janela <-> convolucao (padrao valid/ready com saida registrada)
    //
    //   win_ack        : a convolucao esta levando a janela apresentada agora.
    //   lb_advance_ok  : o line buffer pode dar mais um passo, ou seja, ou nao
    //                    ha janela pendente, ou ela esta sendo consumida neste
    //                    exato ciclo. E este sinal que impede a varredura de
    //                    atropelar a convolucao e PERDER janelas.
    // ------------------------------------------------------------------------
    wire win_ack       = win_valid && win_ready;
    wire lb_advance_ok = (!win_valid) || win_ready;

    // ========================================================================
    // 1. Unidade de controle global (handshake + sequenciamento)
    // ========================================================================
    CNN_Control_FSM #(
        .NUM_POOL(NUM_POOL)
    ) u_ctrl (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .busy(busy),
        .ready(ready),
        .done(done),
        .valid_out(valid_out),
        .need_pixel(need_pixel),
        .last_push(last_push),
        .conv_ready(lb_advance_ok),
        .pool_out_valid(pool_valid),
        .dense_done(dense_valid),
        .frame_start(frame_start),
        .push_en(push_en),
        .dense_run(dense_run)
    );

    // ========================================================================
    // 2. Geracao de janelas 3x3 com line buffers e zero-padding
    // ========================================================================
    CNN_Line_Buffer #(
        .WIDTH(WIDTH),
        .IMG_W(IMG_W),
        .IMG_H(IMG_H),
        .CNT_W(CNT_W)
    ) u_linebuf (
        .clk(clk),
        .rst(rst),
        .start(frame_start),
        .push_en(push_en),
        .win_ack(win_ack),
        .in_pixel(in_pixel),
        .need_pixel(need_pixel),
        .last_push(last_push),
        .out_win(win_data),
        .win_valid(win_valid),
        .out_row(win_row),
        .out_col(win_col)
    );

    // ========================================================================
    // 3. Camada convolucional: 8 filtros 3x3 + bias + ReLU
    // ========================================================================
    CNN_Conv_Layer #(
        .WIDTH(WIDTH),
        .FRAC(FRAC),
        .ACC_W(ACC_W),
        .NUM_FILTERS(NUM_FILTERS),
        .NUM_TAPS(9)
    ) u_conv (
        .clk(clk),
        .rst(rst),
        .win_valid(win_valid),
        .win_data(win_data),
        .win_ready(win_ready),
        .out_valid(conv_valid),
        .out_data(conv_data)
    );

    // ========================================================================
    // 4. Max pooling 2x2 (stride 2): 32x32x8 -> 16x16x8
    // ========================================================================
    CNN_MaxPool #(
        .WIDTH(WIDTH),
        .NUM_CH(NUM_FILTERS),
        .IN_W(IMG_W),
        .IN_H(IMG_H),
        .CNT_W(CNT_W),
        .IDX_W(POOL_IDX_W)
    ) u_pool (
        .clk(clk),
        .rst(rst),
        .start(frame_start),
        .in_valid(conv_valid),
        .in_data(conv_data),
        .out_valid(pool_valid),
        .out_data(pool_data)
    );

    // ========================================================================
    // 5. Classificador: GAP -> camada densa 8x4 -> argmax
    // ========================================================================
    CNN_Dense_Classifier #(
        .WIDTH(WIDTH),
        .FRAC(FRAC),
        .ACC_W(ACC_W),
        .NUM_CH(NUM_FILTERS),
        .NUM_CLASSES(NUM_CLASSES),
        .GAP_ACC_W(32),
        .GAP_SHIFT(GAP_SHIFT)
    ) u_dense (
        .clk(clk),
        .rst(rst),
        .start(frame_start),
        .in_valid(pool_valid),
        .in_data(pool_data),
        .run(dense_run),
        .out_valid(dense_valid),
        .out_class(out_class),
        .out_scores(out_scores),
        .out_features(out_features)
    );

endmodule
