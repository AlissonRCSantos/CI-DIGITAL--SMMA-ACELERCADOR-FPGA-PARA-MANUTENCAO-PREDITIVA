// ============================================================================
// Module: FFT_Log2_Compress
// Description: Compressao logaritmica da magnitude espectral |X[k]| para o
//              pixel do espectrograma consumido pela CNN.
//
// ----------------------------------------------------------------------------
// POR QUE ESTE BLOCO EXISTE
// ----------------------------------------------------------------------------
//   A CNN NAO e treinada com |X[k]| linear: ela recebe o espectrograma em
//   escala logaritmica. Sem este bloco a cadeia FFT -> CNN fica interrompida -
//   era por isso que o testbench da CNN precisava carregar imagens prontas
//   geradas em Python (vetores/top_imagens.hex).
//
//   A especificacao esta em python/smma/espectrograma.py (funcao 'comprime',
//   passo 6 da cadeia), e e reproduzida aqui BIT A BIT:
//
//       m     = |X| + 1
//       e     = floor(log2(m))                      // priority encoder
//       pixel = e*2048 + ((m - 2^e) << 11) >> e     // mantissa normalizada
//       pixel = min(pixel, 32767)
//
//   Esta e a aproximacao de MITCHELL para o logaritmo: o expoente da o degrau
//   grosso (2048 por oitava) e a mantissa interpola LINEARMENTE dentro da
//   oitava. O erro em relacao ao log2 real e de no maximo ~0.086 oitava
//   (~4%), uniforme, e - o que importa aqui - e EXATAMENTE o mesmo erro que o
//   modelo Python cometeu ao gerar os dados de treino. Fidelidade ao modelo
//   treinado vale mais do que exatidao matematica.
//
// ----------------------------------------------------------------------------
// CUSTO DE HARDWARE
// ----------------------------------------------------------------------------
//   ZERO multiplicadores e ZERO divisores: apenas um priority encoder de 17
//   bits, um subtrator, um barrel shifter e um somador. O termo e*2048 e um
//   deslocamento (e << 11), nao uma multiplicacao.
//
//   Por isso a compressao log2 e preferivel a uma normalizacao linear: ela
//   comprime a enorme faixa dinamica da vibracao (as componentes de falha sao
//   ordens de grandeza menores que a fundamental) em 16 bits, sem custo de
//   DSP e sem precisar de ponto flutuante.
//
// Latencia: 1 ciclo (saida registrada), com clock-enable para contrapressao.
// ============================================================================

`timescale 1ns / 1ps

module FFT_Log2_Compress #(
    parameter WIDTH = 16    // Largura da magnitude e do pixel
)(
    input  wire              clk,        // Clock do sistema (50 MHz)
    input  wire              rst,        // Reset sincrono ativo em alto
    input  wire              en,         // Clock-enable (contrapressao)

    input  wire              in_valid,   // Magnitude valida neste ciclo
    input  wire [WIDTH-1:0]  in_mag,     // |X[k]| (Q1.15 sem sinal)

    output reg               out_valid,  // Pixel valido (1 ciclo depois)
    output reg  [WIDTH-1:0]  out_pixel   // Pixel do espectrograma (0..32767)
);

    localparam W_M     = WIDTH + 1;              // 17 bits: m = |X| + 1
    localparam E_W     = 5;                      // expoente 0..16
    localparam PIX_MAX = (1 << (WIDTH-1)) - 1;   // 32767

    // ------------------------------------------------------------------------
    // m = |X| + 1   (o +1 garante m >= 1, logo log2 sempre definido)
    // ------------------------------------------------------------------------
    wire [W_M-1:0] m = {1'b0, in_mag} + 1'b1;

    // ------------------------------------------------------------------------
    // Priority encoder: e = indice do bit mais significativo em 1 = floor(log2 m)
    // O laco tem limite constante (W_M), portanto e desenrolado em sintese.
    // ------------------------------------------------------------------------
    integer i;
    reg [E_W-1:0] e;
    always @(*) begin
        e = {E_W{1'b0}};
        for (i = 0; i < W_M; i = i + 1)
            if (m[i]) e = i[E_W-1:0];
    end

    // ------------------------------------------------------------------------
    // Mantissa normalizada: ((m - 2^e) << 11) >> e
    //
    // (m - 2^e) e a parte fracionaria dentro da oitava e cabe em 'e' bits.
    // O par de deslocamentos vira UM unico barrel shifter: desloca para a
    // esquerda quando e < 11 e para a direita quando e > 11.
    // ------------------------------------------------------------------------
    wire [W_M-1:0] frac   = m - ({{(W_M-1){1'b0}}, 1'b1} << e);
    wire [W_M-1:0] mant   = (e <= 5'd11) ? (frac << (5'd11 - e))
                                         : (frac >> (e - 5'd11));

    // pixel = e*2048 + mantissa  (e*2048 == e << 11, sem multiplicador)
    wire [W_M+4:0] pix_full = ({{(W_M+5-E_W){1'b0}}, e} << 11)
                            + {{5{1'b0}}, mant};

    // ------------------------------------------------------------------------
    // Saida registrada com saturacao em 32767
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            out_pixel <= {WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else if (en) begin
            out_pixel <= (pix_full > PIX_MAX) ? PIX_MAX[WIDTH-1:0]
                                              : pix_full[WIDTH-1:0];
            out_valid <= in_valid;
        end
    end

endmodule
