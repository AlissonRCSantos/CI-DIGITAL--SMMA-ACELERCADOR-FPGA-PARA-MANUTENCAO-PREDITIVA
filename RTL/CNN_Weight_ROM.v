// ============================================================================
// Module: CNN_Weight_ROM
// Description: Memoria somente-leitura com TODOS os pesos treinados da CNN.
//              Em um produto real esses valores viriam do treinamento offline
//              (em Python/TensorFlow) e seriam gravados aqui via arquivo .mif
//              ou $readmemh. Para o prototipo eles sao constantes sintetizaveis.
//
// ORGANIZACAO DOS PESOS (ponto importante da avaliacao)
// -----------------------------------------------------
// A convolucao processa 1 tap por ciclo, mas os 8 FILTROS em PARALELO. Logo,
// no ciclo do tap t, precisamos dos 8 pesos w[filtro][t] SIMULTANEAMENTE.
// Por isso a ROM e organizada "por tap":
//
//     endereco = t (0..8)  ->  palavra de 8 x 16 = 128 bits
//                              { w7[t], w6[t], ..., w1[t], w0[t] }
//
// Sao apenas 9 palavras de 128 bits (1152 bits = 144 bytes) para toda a
// camada convolucional. Cabe folgadamente em LUTs/registradores, sem gastar
// nenhum bloco de memoria M10K -- que fica reservado para os line buffers.
//
// FILTROS ESCOLHIDOS (interpretaveis, para a demonstracao na placa)
// -----------------------------------------------------------------
//   F0: Sobel X    -> bordas VERTICAIS   (indica desalinhamento)
//   F1: Sobel Y    -> bordas HORIZONTAIS (indica desbalanceamento: raias
//                                         horizontais no espectrograma)
//   F2: Laplaciano -> transientes/impulsos (indica desgaste de rolamento)
//   F3: Media 3x3  -> energia media de banda (fundo/nivel DC)
//   F4: Diagonal decrescente
//   F5: Diagonal crescente
//   F6: Passa-alta horizontal -> variacao rapida em frequencia
//   F7: Passa-tudo central    -> mantem o pixel original (referencia)
//
// Todos os coeficientes foram ESCALADOS para caber em Q1.15, cuja faixa e
// [-1 , +0.99997]. Ex.: o Sobel classico tem coeficientes +-1 e +-2; aqui
// ele aparece dividido por 4 (+-0.25 e +-0.5). Isso nao muda o formato do
// filtro, apenas o ganho -- que e reabsorvido pelos pesos da camada densa.
//
// Codificacao Q1.15: valor_inteiro = valor_real * 32768
//    0.5    ->  16384        -0.5    -> -16384
//    0.25   ->   8192        -0.25   ->  -8192
//    0.125  ->   4096        -0.125  ->  -4096
//    1/9    ->   3641
//
// Bloco puramente COMBINACIONAL (ROM assincrona): a saida acompanha o
// endereco no mesmo ciclo, alimentando diretamente o registrador de entrada
// do DSP dentro do CNN_MAC_Unit -- ou seja, sem custo de latencia.
// ============================================================================

`timescale 1ns / 1ps

module CNN_Weight_ROM #(
    parameter WIDTH        = 16,
    parameter NUM_FILTERS  = 8
)(
    // ---- Porta de leitura dos kernels convolucionais ----
    input  wire [3:0]                        tap_addr,    // 0..8 (tap da janela 3x3)
    output reg  [NUM_FILTERS*WIDTH-1:0]      conv_w,      // 8 pesos (1 por filtro)
    output wire [NUM_FILTERS*WIDTH-1:0]      conv_bias,   // 8 bias (1 por filtro)

    // ---- Porta de leitura da camada densa ----
    input  wire [4:0]                        dense_addr,  // classe*8 + feature
    output reg  signed [WIDTH-1:0]           dense_w,
    input  wire [1:0]                        dense_bias_addr,
    output reg  signed [WIDTH-1:0]           dense_bias
);

    // ========================================================================
    // 1. Kernels convolucionais 3x3 (8 filtros)
    //    Formato da palavra: { F7, F6, F5, F4, F3, F2, F1, F0 }
    //    (o filtro f ocupa os bits [f*16 +: 16])
    // ========================================================================
    always @(*) begin
        case (tap_addr)
            //                     F7          F6           F5           F4
            //                     F3          F2           F1           F0
            // tap 0 = posicao (linha 0, coluna 0) da janela
            4'd0: conv_w = { 16'sd0,      16'sd0,      16'sd0,     -16'sd16384,
                             16'sd3641,   16'sd0,     -16'sd8192,  -16'sd8192 };
            // tap 1 = (0,1)
            4'd1: conv_w = { 16'sd0,      16'sd0,     -16'sd8192,  -16'sd8192,
                             16'sd3641,  -16'sd4096,  -16'sd16384,  16'sd0 };
            // tap 2 = (0,2)
            4'd2: conv_w = { 16'sd0,      16'sd0,     -16'sd16384,  16'sd0,
                             16'sd3641,   16'sd0,     -16'sd8192,   16'sd8192 };
            // tap 3 = (1,0)
            4'd3: conv_w = { 16'sd0,     -16'sd8192,   16'sd8192,  -16'sd8192,
                             16'sd3641,  -16'sd4096,   16'sd0,     -16'sd16384 };
            // tap 4 = (1,1) -> centro da janela
            4'd4: conv_w = { 16'sd16384,  16'sd16384,  16'sd0,      16'sd0,
                             16'sd3641,   16'sd16384,  16'sd0,      16'sd0 };
            // tap 5 = (1,2)
            4'd5: conv_w = { 16'sd0,     -16'sd8192,  -16'sd8192,   16'sd8192,
                             16'sd3641,  -16'sd4096,   16'sd0,      16'sd16384 };
            // tap 6 = (2,0)
            4'd6: conv_w = { 16'sd0,      16'sd0,      16'sd16384,  16'sd0,
                             16'sd3641,   16'sd0,      16'sd8192,  -16'sd8192 };
            // tap 7 = (2,1)
            4'd7: conv_w = { 16'sd0,      16'sd0,      16'sd8192,   16'sd8192,
                             16'sd3641,  -16'sd4096,   16'sd16384,  16'sd0 };
            // tap 8 = (2,2)
            4'd8: conv_w = { 16'sd0,      16'sd0,      16'sd0,      16'sd16384,
                             16'sd3641,   16'sd0,      16'sd8192,   16'sd8192 };
            default:
                  conv_w = {(NUM_FILTERS*WIDTH){1'b0}};
        endcase
    end

    // Ordem: { b7, b6, b5, b4, b3, b2, b1, b0 }
    // Valores pequenos (|b| <= 0.0625) apenas para deslocar o limiar do ReLU.
    assign conv_bias = { 16'sd2048, -16'sd1024,  16'sd1024, -16'sd512,
                         16'sd512,  -16'sd256,   16'sd256,   16'sd0 };

    // ========================================================================
    // 2. Camada densa (classificador): 4 classes x 8 features
    //    Endereco = classe*8 + indice_da_feature
    //
    //    Classe 0 = OPERACAO NORMAL      -> premia energia media (F3, F7),
    //                                       penaliza bordas/transientes
    //    Classe 1 = DESBALANCEAMENTO     -> premia Sobel Y (F1)
    //    Classe 2 = DESALINHAMENTO       -> premia Sobel X (F0)
    //    Classe 3 = DESGASTE DE ROLAMENTO-> premia Laplaciano (F2) e
    //                                       passa-alta (F6)
    // ========================================================================
    always @(*) begin
        case (dense_addr)
            // ---- Classe 0: OPERACAO NORMAL ----
            // Premia energia media suave (F3) e penaliza qualquer estrutura
            // de borda ou transiente.
            5'd0 : dense_w = -16'sd16384;  // F0 Sobel X
            5'd1 : dense_w = -16'sd16384;  // F1 Sobel Y
            5'd2 : dense_w = -16'sd16384;  // F2 Laplaciano
            5'd3 : dense_w =  16'sd16384;  // F3 Media          (+)
            5'd4 : dense_w =  16'sd0;      // F4 Diagonal
            5'd5 : dense_w =  16'sd0;      // F5 Diagonal
            5'd6 : dense_w = -16'sd16384;  // F6 Passa-alta
            5'd7 : dense_w =  16'sd0;      // F7 Centro

            // ---- Classe 1: DESBALANCEAMENTO ----
            // Raias HORIZONTAIS no espectrograma -> Sobel Y (F1) domina.
            5'd8 : dense_w = -16'sd16384;
            5'd9 : dense_w =  16'sd16384;  // F1 Sobel Y        (+)
            5'd10: dense_w = -16'sd16384;
            5'd11: dense_w =  16'sd0;
            5'd12: dense_w =  16'sd0;
            5'd13: dense_w =  16'sd0;
            5'd14: dense_w = -16'sd16384;
            5'd15: dense_w =  16'sd0;

            // ---- Classe 2: DESALINHAMENTO ----
            // Raias VERTICAIS no espectrograma -> Sobel X (F0) domina.
            5'd16: dense_w =  16'sd16384;  // F0 Sobel X        (+)
            5'd17: dense_w = -16'sd16384;
            5'd18: dense_w = -16'sd16384;
            5'd19: dense_w =  16'sd0;
            5'd20: dense_w =  16'sd0;
            5'd21: dense_w =  16'sd0;
            5'd22: dense_w = -16'sd16384;
            5'd23: dense_w =  16'sd0;

            // ---- Classe 3: DESGASTE DE ROLAMENTO ----
            // Impulsos isolados / transientes -> Laplaciano (F2) e
            // passa-alta (F6) dominam.
            5'd24: dense_w = -16'sd16384;
            5'd25: dense_w = -16'sd16384;
            5'd26: dense_w =  16'sd16384;  // F2 Laplaciano     (+)
            5'd27: dense_w =  16'sd0;
            5'd28: dense_w =  16'sd0;
            5'd29: dense_w =  16'sd0;
            5'd30: dense_w =  16'sd16384;  // F6 Passa-alta     (+)
            5'd31: dense_w =  16'sd0;

            default: dense_w = 16'sd0;
        endcase
    end

    always @(*) begin
        case (dense_bias_addr)
            2'd0: dense_bias =  16'sd0;
            2'd1: dense_bias = -16'sd512;
            2'd2: dense_bias = -16'sd512;
            2'd3: dense_bias = -16'sd1024;
            default: dense_bias = 16'sd0;
        endcase
    end

endmodule
