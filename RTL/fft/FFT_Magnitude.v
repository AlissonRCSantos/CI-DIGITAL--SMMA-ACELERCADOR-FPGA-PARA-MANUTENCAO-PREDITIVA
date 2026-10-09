// ============================================================================
// Module: FFT_Magnitude
// Description: Estimador de magnitude espectral |X[k]| sem multiplicadores,
//              pelo metodo "alpha-max plus beta-min".
//
//   |X| = sqrt(re^2 + im^2)  ~=  alpha*max(|re|,|im|) + beta*min(|re|,|im|)
//
//   Com alpha = 1 e beta = 3/8:
//       |X| ~= max + (min >> 2) + (min >> 3)
//
//   Erro maximo de aproximadamente 6,8% e erro medio proximo de 1%, obtidos
//   usando APENAS deslocamentos e somas: 0 DSP, 0 divisores, 0 raiz quadrada.
//
// Justificativa de projeto: o detector de picos e o modulo MDC trabalham com
// COMPARACOES entre bins (qual bin e maior que o limiar) e nao com o valor
// absoluto exato da energia. Um erro relativo de ate 6,8%, aplicado de forma
// uniforme a todos os bins, preserva a ORDENACAO dos picos espectrais, que e
// a unica informacao realmente consumida a jusante. Usar um CORDIC ou uma
// raiz quadrada real custaria muito mais area sem beneficio pratico para a
// classificacao de falhas.
//
// Formato numerico:
//   Entradas : Q1.15 com sinal   (faixa -1,0 .. +0,999969)
//   Saida    : Q1.15 SEM sinal   (faixa 0 .. 1,999969)
//              O bit inteiro extra e necessario porque max + 0,375*min pode
//              chegar a 1,375 quando as duas componentes estao em fundo de
//              escala; nao ha, portanto, possibilidade de overflow.
//
// Latencia: 2 ciclos.
//   Estagio 1: valor absoluto e ordenacao (max/min)
//   Estagio 2: soma deslocada
// ============================================================================

`timescale 1ns / 1ps

module FFT_Magnitude #(
    parameter WIDTH = 16   // Largura das componentes de entrada (Q1.15)
)(
    input  wire                    clk,        // Clock do sistema (50 MHz)
    input  wire                    rst,        // Reset sincrono ativo em alto
    input  wire                    en,         // Clock-enable (contrapressao da saida)
    input  wire                    in_valid,   // Entrada valida neste ciclo
    input  wire signed [WIDTH-1:0] in_real,    // Parte real   de X[k] (Q1.15)
    input  wire signed [WIDTH-1:0] in_imag,    // Parte imag.  de X[k] (Q1.15)
    output reg                     out_valid,  // Saida valida (2 ciclos depois)
    output reg  [WIDTH-1:0]        out_mag     // |X[k]| aproximado (Q1.15 sem sinal)
);

    localparam W_ABS = WIDTH + 1;   // 17 bits: |-32768| = 32768 nao cabe em 16 bits

    // ------------------------------------------------------------------------
    // ESTAGIO 1: valor absoluto e ordenacao
    // ------------------------------------------------------------------------
    wire [W_ABS-1:0] abs_real = in_real[WIDTH-1] ? (~{in_real[WIDTH-1], in_real} + 1'b1)
                                                 :  {in_real[WIDTH-1], in_real};
    wire [W_ABS-1:0] abs_imag = in_imag[WIDTH-1] ? (~{in_imag[WIDTH-1], in_imag} + 1'b1)
                                                 :  {in_imag[WIDTH-1], in_imag};

    reg [W_ABS-1:0] max_val, min_val;
    reg             valid_s1;

    always @(posedge clk) begin
        if (rst) begin
            max_val  <= {W_ABS{1'b0}};
            min_val  <= {W_ABS{1'b0}};
            valid_s1 <= 1'b0;
        end else if (en) begin
            if (abs_real >= abs_imag) begin
                max_val <= abs_real;
                min_val <= abs_imag;
            end else begin
                max_val <= abs_imag;
                min_val <= abs_real;
            end
            valid_s1 <= in_valid;
        end
    end

    // ------------------------------------------------------------------------
    // ESTAGIO 2: |X| = max + min/4 + min/8   (beta = 3/8)
    // ------------------------------------------------------------------------
    wire [W_ABS+1:0] mag_sum = {2'b00, max_val}
                             + {2'b00, (min_val >> 2)}
                             + {2'b00, (min_val >> 3)};

    always @(posedge clk) begin
        if (rst) begin
            out_mag   <= {WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else if (en) begin
            // O resultado maximo (1,375 * 32768 = 45056) cabe em 16 bits sem
            // sinal; a saturacao abaixo e apenas uma protecao formal.
            if (mag_sum > {{(W_ABS+2-WIDTH){1'b0}}, {WIDTH{1'b1}}})
                out_mag <= {WIDTH{1'b1}};
            else
                out_mag <= mag_sum[WIDTH-1:0];
            out_valid <= valid_s1;
        end
    end

endmodule
