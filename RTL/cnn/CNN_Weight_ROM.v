// ============================================================================
// CNN_Weight_ROM -- pesos treinados da CNN (gerado por python/scripts/05_exportar_rtl.py)
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

    // 1. Kernels convolucionais 3x3 (8 filtros treinados)
    //    Formato da palavra: { F7, F6, F5, F4, F3, F2, F1, F0 }
    always @(*) begin
        case (tap_addr)
            4'd0: conv_w = {  -16'sd32737,  -16'sd11103,     16'sd989,  -16'sd18437,   -16'sd5866,  -16'sd20767,   16'sd14414,  -16'sd12872 };
            4'd1: conv_w = {  -16'sd32736,  -16'sd13398,     16'sd171,  -16'sd31713,   -16'sd2507,   16'sd11999,   16'sd15634,  -16'sd14111 };
            4'd2: conv_w = {  -16'sd32028,   -16'sd4422,   -16'sd1988,  -16'sd18748,   -16'sd8794,  -16'sd16420,   16'sd10516,  -16'sd10184 };
            4'd3: conv_w = {  -16'sd15581,    -16'sd359,  -16'sd23809,    16'sd1822,  -16'sd17934,  -16'sd12714,   16'sd27116,   -16'sd2588 };
            4'd4: conv_w = {   -16'sd1232,   -16'sd1265,  -16'sd25552,    16'sd2225,  -16'sd13215,   16'sd15250,   16'sd32121,   -16'sd6374 };
            4'd5: conv_w = {  -16'sd16887,     16'sd853,  -16'sd22815,    16'sd2484,  -16'sd15409,   -16'sd8552,   16'sd26796,    -16'sd736 };
            4'd6: conv_w = {   16'sd32767,  -16'sd16771,   -16'sd6071,  -16'sd32767,   -16'sd7523,  -16'sd32760,   -16'sd7308,  -16'sd10528 };
            4'd7: conv_w = {   16'sd32766,  -16'sd16568,   -16'sd1908,  -16'sd32765,   -16'sd6671,    16'sd7063,    16'sd1373,  -16'sd20151 };
            4'd8: conv_w = {   16'sd32766,  -16'sd17047,   -16'sd2096,  -16'sd32767,   -16'sd1537,  -16'sd32760,   -16'sd3780,  -16'sd17247 };
            default: conv_w = {(NUM_FILTERS*WIDTH){1'b0}};
        endcase
    end

    // Ordem: { b7, b6, b5, b4, b3, b2, b1, b0 }
    assign conv_bias = { -16'sd13305, -16'sd2132, -16'sd2544, 16'sd32752, 16'sd3040, 16'sd31392, -16'sd32766, -16'sd2269 };

    // 2. Camada densa (classificador): 4 classes x 8 features
    always @(*) begin
        case (dense_addr)
            // ---- Classe 0: NORMAL ----
            5'd0 : dense_w =  16'sd18881;   // feature F0
            5'd1 : dense_w = -16'sd18818;   // feature F1
            5'd2 : dense_w =  16'sd32735;   // feature F2
            5'd3 : dense_w = -16'sd12405;   // feature F3
            5'd4 : dense_w =  16'sd32767;   // feature F4
            5'd5 : dense_w = -16'sd8833;   // feature F5
            5'd6 : dense_w =  16'sd6193;   // feature F6
            5'd7 : dense_w = -16'sd32768;   // feature F7
            // ---- Classe 1: DESBALANCEAMENTO ----
            5'd8 : dense_w =  16'sd5577;   // feature F0
            5'd9 : dense_w = -16'sd32740;   // feature F1
            5'd10: dense_w = -16'sd5178;   // feature F2
            5'd11: dense_w =  16'sd10644;   // feature F3
            5'd12: dense_w = -16'sd32768;   // feature F4
            5'd13: dense_w =  16'sd6115;   // feature F5
            5'd14: dense_w = -16'sd5448;   // feature F6
            5'd15: dense_w =  16'sd32767;   // feature F7
            // ---- Classe 2: DESALINHAMENTO ----
            5'd16: dense_w =  16'sd14415;   // feature F0
            5'd17: dense_w = -16'sd5288;   // feature F1
            5'd18: dense_w = -16'sd32762;   // feature F2
            5'd19: dense_w =  16'sd4963;   // feature F3
            5'd20: dense_w =  16'sd32767;   // feature F4
            5'd21: dense_w =  16'sd6144;   // feature F5
            5'd22: dense_w =  16'sd4810;   // feature F6
            5'd23: dense_w = -16'sd32768;   // feature F7
            // ---- Classe 3: ROLAMENTO ----
            5'd24: dense_w =  16'sd4947;   // feature F0
            5'd25: dense_w =  16'sd32767;   // feature F1
            5'd26: dense_w = -16'sd32768;   // feature F2
            5'd27: dense_w = -16'sd12227;   // feature F3
            5'd28: dense_w = -16'sd18300;   // feature F4
            5'd29: dense_w =  16'sd4240;   // feature F5
            5'd30: dense_w = -16'sd3407;   // feature F6
            5'd31: dense_w =  16'sd29568;   // feature F7
            default: dense_w = 16'sd0;
        endcase
    end

    always @(*) begin
        case (dense_bias_addr)
            2'd0: dense_bias = -16'sd997;   // normal
            2'd1: dense_bias =  16'sd13744;   // desbalanceamento
            2'd2: dense_bias =  16'sd3830;   // desalinhamento
            2'd3: dense_bias = -16'sd22057;   // rolamento
            default: dense_bias = 16'sd0;
        endcase
    end

endmodule
