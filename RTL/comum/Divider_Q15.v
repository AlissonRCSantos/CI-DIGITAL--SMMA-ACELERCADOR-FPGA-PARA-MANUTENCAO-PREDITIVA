// ============================================================================
// Module: Divider_Q15
// Description: Divisor sem sinal por restauracao, com resultado em Q1.15.
//              Calcula  q = (num << 15) / den,  saturado em 0x7FFF.
//
// ----------------------------------------------------------------------------
// PARA QUE SERVE
// ----------------------------------------------------------------------------
//   Seis das oito caracteristicas espectrais do classificador sao RAZOES
//   (energia de um bin ou de uma banda dividida pela energia total). Sao elas
//   que tornam a decisao independente do nivel absoluto do sinal -- e por
//   isso que a arvore aguenta a variacao de carga melhor que a CNN. Razao
//   exige divisao, e nao ha divisor em ponto fixo Q1.15 no projeto (o
//   fixed_point_divider existente e Q4.12 e pertence a cadeia AR).
//
// ----------------------------------------------------------------------------
// ALGORITMO
// ----------------------------------------------------------------------------
//   Divisao por restauracao, 1 bit por ciclo: 16 ciclos por resultado. Usa
//   apenas um subtrator e um comparador -- ZERO DSP, que e o recurso escasso
//   (a CNN leva 8 e a FFT 4).
//
//   O orcamento e enorme: sao 7 divisoes por decisao do classificador, isto
//   e, 7 x 16 = 112 ciclos a cada 330 ms (16,5 milhoes de ciclos). Qualquer
//   esquema mais rapido seria otimizar o que ja e irrelevante.
//
//   Como todas as razoes do classificador sao de grandezas NAO NEGATIVAS
//   (magnitudes espectrais), o divisor e sem sinal. Isso evita a ambiguidade
//   de arredondamento de quociente negativo, que e fonte classica de
//   divergencia entre modelo e hardware.
//
//   den = 0 nao trava nem devolve lixo: levanta 'div_zero' e satura a saida.
// ============================================================================

`timescale 1ns / 1ps

module Divider_Q15 #(
    parameter NUM_W = 32,      // largura do numerador
    parameter DEN_W = 32,      // largura do denominador
    parameter FRAC  = 15       // bits fracionarios do quociente
)(
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  start,      // Pulso: inicia uma divisao
    output wire                  ready,      // Pronto para nova divisao
    output reg                   done,       // Pulso: quociente valido

    input  wire [NUM_W-1:0]      num,        // numerador   (sem sinal)
    input  wire [DEN_W-1:0]      den,        // denominador (sem sinal)

    output reg  [FRAC:0]         quociente,  // Q1.15 sem sinal (satura em 0x7FFF)
    output reg                   div_zero    // 1 = denominador era zero
);

    // Para obter floor(num * 2^FRAC / den) sao exatamente FRAC passos de
    // deslocamento-subtracao -- um a mais dobraria o resultado. Como as
    // razoes do classificador tem num < den, o quociente cabe nos FRAC bits.
    localparam PASSOS = FRAC;                     // 15 passos -> 15 bits
    localparam W      = NUM_W + FRAC + 1;         // resto alinhado
    localparam [FRAC:0] SAT = {1'b0, {FRAC{1'b1}}};   // 0x7FFF

    reg [W-1:0]          resto;
    reg [DEN_W-1:0]      divisor;
    reg [FRAC:0]         q;
    reg [5:0]            passo;
    reg                  ocupado;

    assign ready = !ocupado;

    // subtracao tentativa do passo corrente
    wire [W-1:0] resto_desl = {resto[W-2:0], 1'b0};
    wire [W-1:0] tentativa  = resto_desl - {{(W-DEN_W){1'b0}}, divisor};
    wire         cabe       = !tentativa[W-1];          // nao ficou negativo

    always @(posedge clk) begin
        if (rst) begin
            resto     <= {W{1'b0}};
            divisor   <= {DEN_W{1'b0}};
            q         <= {(FRAC+1){1'b0}};
            passo     <= 6'd0;
            ocupado   <= 1'b0;
            done      <= 1'b0;
            quociente <= {(FRAC+1){1'b0}};
            div_zero  <= 1'b0;
        end else begin
            done <= 1'b0;                              // pulso de 1 ciclo

            if (!ocupado) begin
                if (start) begin
                    if (den == {DEN_W{1'b0}}) begin
                        // denominador zero: satura e sinaliza, sem travar
                        quociente <= SAT;
                        div_zero  <= 1'b1;
                        done      <= 1'b1;
                    end else if ({{(DEN_W){1'b0}}, num} >= {{(NUM_W){1'b0}}, den}) begin
                        // quociente >= 1.0 nao e representavel em Q1.15:
                        // satura de imediato em vez de estourar os FRAC bits
                        quociente <= SAT;
                        div_zero  <= 1'b0;
                        done      <= 1'b1;
                    end else begin
                        resto    <= {{(FRAC+1){1'b0}}, num};
                        divisor  <= den;
                        q        <= {(FRAC+1){1'b0}};
                        passo    <= 6'd0;
                        div_zero <= 1'b0;
                        ocupado  <= 1'b1;
                    end
                end
            end else begin
                resto <= cabe ? tentativa : resto_desl;
                q     <= {q[FRAC-1:0], cabe};
                if (passo == PASSOS - 1) begin
                    ocupado   <= 1'b0;
                    done      <= 1'b1;
                    quociente <= {1'b0, q[FRAC-2:0], cabe};
                end else begin
                    passo <= passo + 1'b1;
                end
            end
        end
    end

endmodule
