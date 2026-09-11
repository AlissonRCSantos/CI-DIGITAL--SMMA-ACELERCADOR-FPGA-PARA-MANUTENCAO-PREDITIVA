// ============================================================================
// Module: CNN_Dense_Classifier
// Description: Etapa final da CNN. Faz tres coisas:
//                1) GLOBAL AVERAGE POOLING (GAP) sobre o mapa 16x16x8
//                2) CAMADA DENSA (totalmente conectada) 8 -> 4
//                3) ARGMAX -> classe final do motor
//
// POR QUE GLOBAL AVERAGE POOLING?
// -------------------------------
// Se ligassemos a camada densa direto no mapa 16x16x8, terrilamos
//        16*16*8 = 2048 entradas x 4 classes = 8192 PESOS
// ou seja 128 kbit so de pesos, alem de 2048 palavras de memoria para guardar
// o mapa inteiro. Inviavel para o prototipo (e o enunciado limita o uso de
// memorias internas).
//
// O GAP resolve isso: em vez de guardar o mapa, ACUMULA cada canal ao longo
// das 256 posicoes e divide pelo total. Sobram apenas 8 numeros -- um por
// filtro -- que respondem a pergunta "o quanto esta caracteristica aparece na
// imagem inteira?". A camada densa passa a ter apenas
//        8 entradas x 4 classes = 32 PESOS.
//
// Ganhos:
//   * 8192 -> 32 pesos            (reducao de 256x)
//   * 2048 -> 8 palavras de estado (nao precisa guardar o mapa!)
//   * o acumulador e atualizado EM STREAMING, no mesmo ciclo em que o pooling
//     entrega o dado; quando o ultimo pixel passa, as features ja estao prontas
//
// A divisao por 256 e apenas um deslocamento aritmetico de 8 bits
// (GAP_SHIFT = log2(256)), portanto NAO usa divisor -- o enunciado pede
// atencao a divisao e aqui ela simplesmente nao existe.
//
// CAMADA DENSA: RECURSO COMPARTILHADO
// -----------------------------------
// Sao 4 x 8 = 32 multiplicacoes. Em vez de instanciar 32 multiplicadores,
// usamos UM UNICO CNN_MAC_Unit reutilizado 32 vezes (32 ciclos = 0,64 us),
// exatamente a mesma estrategia "folded" do PE do filtro LMS. Custo: 1 DSP.
//
// ARGMAX
// ------
// A classe predita e o indice do maior score. Nao usamos softmax porque
// softmax exige exponencial e divisao (caros em FPGA) e NAO altera qual e o
// maior valor -- ela so normaliza os scores em probabilidades. Para decidir a
// classe, comparar os scores brutos e matematicamente equivalente.
// Empate -> vence o menor indice (comportamento deterministico).
// ============================================================================

`timescale 1ns / 1ps

module CNN_Dense_Classifier #(
    parameter WIDTH       = 16,
    parameter FRAC        = 15,
    parameter ACC_W       = 40,
    parameter NUM_CH      = 8,    // features (= numero de filtros da conv)
    parameter NUM_CLASSES = 4,
    parameter GAP_ACC_W   = 32,   // acumulador do global average pooling
    parameter GAP_SHIFT   = 8     // log2(numero de posicoes) = log2(16*16)
)(
    input  wire                        clk,
    input  wire                        rst,
    input  wire                        start,      // Pulso: zera os acumuladores GAP

    // ---- Entrada: stream vindo do max pooling ----
    input  wire                        in_valid,
    input  wire [NUM_CH*WIDTH-1:0]     in_data,

    // ---- Disparo da camada densa (apos o ultimo pixel do pooling) ----
    input  wire                        run,

    // ---- Saidas ----
    output reg                         out_valid,   // Pulso: classificacao pronta
    output reg  [1:0]                  out_class,   // 0..3
    output wire [NUM_CLASSES*WIDTH-1:0] out_scores, // Scores brutos (debug/demo)
    output wire [NUM_CH*WIDTH-1:0]     out_features // Features do GAP (debug/demo)
);

    // ========================================================================
    // 1. GLOBAL AVERAGE POOLING (acumulacao em streaming)
    // ========================================================================
    reg signed [GAP_ACC_W-1:0] gap_acc [0:NUM_CH-1];
    wire [NUM_CH*WIDTH-1:0]    gap_feat;   // media ja reescalada para Q1.15

    integer g;

    always @(posedge clk) begin
        if (rst || start) begin
            for (g = 0; g < NUM_CH; g = g + 1)
                gap_acc[g] <= {GAP_ACC_W{1'b0}};
        end else if (in_valid) begin
            for (g = 0; g < NUM_CH; g = g + 1)
                gap_acc[g] <= gap_acc[g] +
                    { {(GAP_ACC_W-WIDTH){in_data[g*WIDTH + WIDTH-1]}},
                      in_data[g*WIDTH +: WIDTH] };
        end
    end

    // Divisao por 2^GAP_SHIFT + arredondamento + saturacao (sem divisor!)
    genvar gc;
    generate
        for (gc = 0; gc < NUM_CH; gc = gc + 1) begin : g_gap
            CNN_ReLU #(
                .ACC_W(GAP_ACC_W),
                .WIDTH(WIDTH),
                .SHIFT(GAP_SHIFT),
                .ENABLE_RELU(1)
            ) u_gap_scale (
                .in_acc(gap_acc[gc]),
                .out_y(gap_feat[gc*WIDTH +: WIDTH])
            );
        end
    endgenerate

    // Features congeladas no instante do disparo (estaveis durante os 32 ciclos)
    reg [NUM_CH*WIDTH-1:0] feat_reg;
    assign out_features = feat_reg;

    // ========================================================================
    // 2. Sequenciador da camada densa (1 MAC reutilizado 32 vezes)
    // ========================================================================
    reg       d_active;
    reg [5:0] d_cnt;      // 0..31  -> d_cnt[4:3]=classe, d_cnt[2:0]=feature

    always @(posedge clk) begin
        if (rst) begin
            d_active <= 1'b0;
            d_cnt    <= 6'd0;
            feat_reg <= {(NUM_CH*WIDTH){1'b0}};
        end else if (run && !d_active) begin
            d_active <= 1'b1;
            d_cnt    <= 6'd0;
            feat_reg <= gap_feat;            // congela as features do GAP
        end else if (d_active) begin
            if (d_cnt == 6'd31)
                d_active <= 1'b0;
            else
                d_cnt <= d_cnt + 6'd1;
        end
    end

    wire       mac_en    = d_active;
    wire       mac_first = d_active && (d_cnt[2:0] == 3'd0);
    wire       mac_last  = d_active && (d_cnt[2:0] == 3'd7);

    // Multiplexador da feature (case explicito, sem indexacao variavel)
    reg signed [WIDTH-1:0] feat_sel;
    always @(*) begin
        case (d_cnt[2:0])
            3'd0: feat_sel = feat_reg[0*WIDTH +: WIDTH];
            3'd1: feat_sel = feat_reg[1*WIDTH +: WIDTH];
            3'd2: feat_sel = feat_reg[2*WIDTH +: WIDTH];
            3'd3: feat_sel = feat_reg[3*WIDTH +: WIDTH];
            3'd4: feat_sel = feat_reg[4*WIDTH +: WIDTH];
            3'd5: feat_sel = feat_reg[5*WIDTH +: WIDTH];
            3'd6: feat_sel = feat_reg[6*WIDTH +: WIDTH];
            3'd7: feat_sel = feat_reg[7*WIDTH +: WIDTH];
            default: feat_sel = {WIDTH{1'b0}};
        endcase
    end

    // ========================================================================
    // 3. ROM de pesos da camada densa
    // ========================================================================
    wire signed [WIDTH-1:0] dense_w;
    wire signed [WIDTH-1:0] dense_bias;

    CNN_Weight_ROM #(
        .WIDTH(WIDTH),
        .NUM_FILTERS(NUM_CH)
    ) u_rom (
        .tap_addr(4'd0),
        .conv_w(),
        .conv_bias(),
        .dense_addr(d_cnt[4:0]),
        .dense_w(dense_w),
        .dense_bias_addr(d_cnt[4:3]),
        .dense_bias(dense_bias)
    );

    // Bias alinhado ao acumulador (bias << FRAC)
    wire signed [ACC_W-1:0] dense_init =
        { {(ACC_W-WIDTH-FRAC){dense_bias[WIDTH-1]}}, dense_bias, {FRAC{1'b0}} };

    // ========================================================================
    // 4. MAC compartilhado
    // ========================================================================
    wire signed [ACC_W-1:0] dense_acc;
    wire                    dense_mac_valid;

    CNN_MAC_Unit #(
        .WIDTH(WIDTH),
        .ACC_W(ACC_W)
    ) u_dense_mac (
        .clk(clk),
        .rst(rst),
        .en(mac_en),
        .first(mac_first),
        .last(mac_last),
        .init_acc(dense_init),
        .in_a(feat_sel),
        .in_b(dense_w),
        .out_acc(dense_acc),
        .out_valid(dense_mac_valid)
    );

    // Score reescalado para Q1.15 -- SEM ReLU (scores podem ser negativos)
    wire signed [WIDTH-1:0] score_now;

    CNN_ReLU #(
        .ACC_W(ACC_W),
        .WIDTH(WIDTH),
        .SHIFT(FRAC),
        .ENABLE_RELU(0)
    ) u_score_scale (
        .in_acc(dense_acc),
        .out_y(score_now)
    );

    // ========================================================================
    // 5. Coleta dos 4 scores e ARGMAX
    // ========================================================================
    reg signed [WIDTH-1:0] score0, score1, score2, score3;
    reg [2:0]              score_idx;

    assign out_scores = {score3, score2, score1, score0};

    // Argmax combinacional (empate -> menor indice)
    wire signed [WIDTH-1:0] best_a_val = (score0 >= score1) ? score0 : score1;
    wire [1:0]              best_a_idx = (score0 >= score1) ? 2'd0   : 2'd1;
    wire signed [WIDTH-1:0] best_b_val = (score2 >= score3) ? score2 : score3;
    wire [1:0]              best_b_idx = (score2 >= score3) ? 2'd2   : 2'd3;
    wire [1:0]              arg_max    = (best_a_val >= best_b_val) ? best_a_idx
                                                                    : best_b_idx;

    always @(posedge clk) begin
        if (rst) begin
            score0    <= {WIDTH{1'b0}};
            score1    <= {WIDTH{1'b0}};
            score2    <= {WIDTH{1'b0}};
            score3    <= {WIDTH{1'b0}};
            score_idx <= 3'd0;
            out_valid <= 1'b0;
            out_class <= 2'd0;
        end else begin
            out_valid <= 1'b0;

            if (run && !d_active)
                score_idx <= 3'd0;          // nova classificacao

            if (dense_mac_valid) begin
                case (score_idx)
                    3'd0: score0 <= score_now;
                    3'd1: score1 <= score_now;
                    3'd2: score2 <= score_now;
                    3'd3: score3 <= score_now;
                    default: ;
                endcase
                score_idx <= score_idx + 3'd1;
            end

            // Um ciclo APOS o 4o score ter sido registrado, o argmax e valido
            if (score_idx == 3'd4) begin
                out_class <= arg_max;
                out_valid <= 1'b1;
                score_idx <= 3'd5;          // trava ate a proxima classificacao
            end
        end
    end

endmodule
