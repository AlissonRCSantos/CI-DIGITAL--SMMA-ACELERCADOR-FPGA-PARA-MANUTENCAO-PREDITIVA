// ============================================================================
// Module: FFT_Butterfly
// Description: Unidade Butterfly radix-2 por decimacao no tempo (DIT) com
//              escalonamento de 1/2 por estagio, em ponto fixo Q1.15.
//
// Operacao implementada:
//       t  = W * B                     (multiplicacao complexa)
//       P  = (A + t) / 2               (saida superior)
//       Q  = (A - t) / 2               (saida inferior)
//
// Multiplicacao complexa (4 multiplicadores reais + 2 somadores):
//       t_real = B_real*W_real - B_imag*W_imag
//       t_imag = B_real*W_imag + B_imag*W_real
//
// ----------------------------------------------------------------------------
// POR QUE DIVIDIR POR 2 A CADA ESTAGIO (escalonamento fixo)
// ----------------------------------------------------------------------------
//   Um butterfly radix-2 pode DOBRAR a magnitude do dado (|A|+|t| <= 2|max|).
//   Em 6 estagios o crescimento maximo seria 2^6 = 64x, o que estouraria
//   qualquer palavra de 16 bits. Com o escalonamento de 1/2 embutido em cada
//   estagio, a saida fica limitada a |X[k]|/N e permanece sempre dentro da
//   faixa Q1.15, sem necessidade de deteccao dinamica de overflow.
//
//   Consequencia: a saida da FFT e X[k]/N (DFT normalizada). Como o detector
//   de picos e o modulo MDC trabalham com magnitudes RELATIVAS entre bins, o
//   fator constante 1/64 nao altera a identificacao das harmonicas nem a
//   estimativa da frequencia fundamental.
//
//   Custo: perde-se ~1 bit de SNR por estagio nos sinais de baixa amplitude.
//   Alternativa possivel (block floating-point / escalonamento condicional):
//   escalar somente quando houver risco real de overflow, preservando SNR ao
//   custo de um detector de overflow por estagio e de um expoente global.
//
// ----------------------------------------------------------------------------
// RECURSOS E PIPELINE
// ----------------------------------------------------------------------------
//   Multiplicadores : 4 (instancias de FP_Mult_Unit -> 4 DSPs 18x18)
//   Somadores       : 2 (combinacao complexa) + 4 (A+t / A-t) = 6
//   Latencia total  : 6 ciclos, totalmente pipelinizada (1 butterfly/ciclo de
//                     vazao potencial; o gargalo real sao as portas de memoria)
//
//   Estagio 1-3 : FP_Mult_Unit (registro de entrada, registro de produto,
//                 arredondamento/saturacao) -> reuso do bloco ja validado
//                 na branch feat/fixed_poit.
//   Estagio 4   : combinacao complexa t = W*B (17 bits, Q2.15)
//   Estagio 5   : somas/subtracoes A +/- t (18 bits, Q3.15)
//   Estagio 6   : escala 1/2 + arredondamento + saturacao -> Q1.15 (16 bits)
//
//   O caminho critico e a soma de 18 bits do estagio 5 (~3 ns em Cyclone V),
//   folgado para os 20 ns exigidos pelos 50 MHz.
// ============================================================================

`timescale 1ns / 1ps

module FFT_Butterfly #(
    parameter WIDTH = 16,   // Largura da palavra (Q1.15)
    parameter FRAC  = 15    // Bits fracionarios
)(
    input  wire                     clk,        // Clock do sistema (50 MHz)
    input  wire                     rst,        // Reset sincrono ativo em alto

    input  wire                     in_valid,   // Operandos validos neste ciclo
    input  wire signed [WIDTH-1:0]  a_real,     // A (operando superior) - real
    input  wire signed [WIDTH-1:0]  a_imag,     // A - imaginario
    input  wire signed [WIDTH-1:0]  b_real,     // B (operando inferior) - real
    input  wire signed [WIDTH-1:0]  b_imag,     // B - imaginario
    input  wire signed [WIDTH-1:0]  w_real,     // Fator de rotacao - real
    input  wire signed [WIDTH-1:0]  w_imag,     // Fator de rotacao - imaginario

    output wire                     out_valid,  // Resultados validos (6 ciclos depois)
    output reg  signed [WIDTH-1:0]  p_real,     // P = (A + W*B)/2 - real
    output reg  signed [WIDTH-1:0]  p_imag,     // P - imaginario
    output reg  signed [WIDTH-1:0]  q_real,     // Q = (A - W*B)/2 - real
    output reg  signed [WIDTH-1:0]  q_imag      // Q - imaginario
);

    localparam LATENCY = 6;            // Latencia do pipeline, em ciclos
    localparam W_T     = WIDTH + 1;    // 17 bits: t = W*B  (Q2.15)
    localparam W_S     = WIDTH + 2;    // 18 bits: A +/- t  (Q3.15)

    // Limites de saturacao no dominio estendido de 18 bits
    localparam signed [W_S-1:0] OUT_MAX =  (1 << (WIDTH-1)) - 1;  // +32767
    localparam signed [W_S-1:0] OUT_MIN = -(1 << (WIDTH-1));      // -32768

    // ========================================================================
    // ESTAGIOS 1-3: MULTIPLICACAO COMPLEXA (4 DSPs em paralelo)
    // ========================================================================
    wire signed [WIDTH-1:0] m_rr;  // B_real * W_real
    wire signed [WIDTH-1:0] m_ii;  // B_imag * W_imag
    wire signed [WIDTH-1:0] m_ri;  // B_real * W_imag
    wire signed [WIDTH-1:0] m_ir;  // B_imag * W_real

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_rr (
        .clk(clk), .rst(rst), .in_A(b_real), .in_B(w_real), .out_Y(m_rr)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ii (
        .clk(clk), .rst(rst), .in_A(b_imag), .in_B(w_imag), .out_Y(m_ii)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ri (
        .clk(clk), .rst(rst), .in_A(b_real), .in_B(w_imag), .out_Y(m_ri)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ir (
        .clk(clk), .rst(rst), .in_A(b_imag), .in_B(w_real), .out_Y(m_ir)
    );

    // ------------------------------------------------------------------------
    // Linha de atraso do operando A: 3 ciclos para alinhar com os produtos
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] a_r_d1, a_r_d2, a_r_d3;
    reg signed [WIDTH-1:0] a_i_d1, a_i_d2, a_i_d3;

    always @(posedge clk) begin
        if (rst) begin
            a_r_d1 <= {WIDTH{1'b0}}; a_r_d2 <= {WIDTH{1'b0}}; a_r_d3 <= {WIDTH{1'b0}};
            a_i_d1 <= {WIDTH{1'b0}}; a_i_d2 <= {WIDTH{1'b0}}; a_i_d3 <= {WIDTH{1'b0}};
        end else begin
            a_r_d1 <= a_real;  a_r_d2 <= a_r_d1;  a_r_d3 <= a_r_d2;
            a_i_d1 <= a_imag;  a_i_d2 <= a_i_d1;  a_i_d3 <= a_i_d2;
        end
    end

    // ========================================================================
    // ESTAGIO 4: COMBINACAO COMPLEXA  t = W*B   (Q2.15, 17 bits)
    // ========================================================================
    reg signed [W_T-1:0]   t_real, t_imag;
    reg signed [WIDTH-1:0] a_r_d4, a_i_d4;

    always @(posedge clk) begin
        if (rst) begin
            t_real <= {W_T{1'b0}};
            t_imag <= {W_T{1'b0}};
            a_r_d4 <= {WIDTH{1'b0}};
            a_i_d4 <= {WIDTH{1'b0}};
        end else begin
            // Extensao de sinal implicita para 17 bits antes da soma/subtracao
            t_real <= {m_rr[WIDTH-1], m_rr} - {m_ii[WIDTH-1], m_ii};
            t_imag <= {m_ri[WIDTH-1], m_ri} + {m_ir[WIDTH-1], m_ir};
            a_r_d4 <= a_r_d3;
            a_i_d4 <= a_i_d3;
        end
    end

    // ========================================================================
    // ESTAGIO 5: SOMAS E SUBTRACOES DO BUTTERFLY  (Q3.15, 18 bits)
    // ========================================================================
    wire signed [W_S-1:0] a_r_ext = {{2{a_r_d4[WIDTH-1]}}, a_r_d4};
    wire signed [W_S-1:0] a_i_ext = {{2{a_i_d4[WIDTH-1]}}, a_i_d4};
    wire signed [W_S-1:0] t_r_ext = {t_real[W_T-1], t_real};
    wire signed [W_S-1:0] t_i_ext = {t_imag[W_T-1], t_imag};

    reg signed [W_S-1:0] sum_r, sum_i, dif_r, dif_i;

    always @(posedge clk) begin
        if (rst) begin
            sum_r <= {W_S{1'b0}};  sum_i <= {W_S{1'b0}};
            dif_r <= {W_S{1'b0}};  dif_i <= {W_S{1'b0}};
        end else begin
            sum_r <= a_r_ext + t_r_ext;   // A + t
            sum_i <= a_i_ext + t_i_ext;
            dif_r <= a_r_ext - t_r_ext;   // A - t
            dif_i <= a_i_ext - t_i_ext;
        end
    end

    // ========================================================================
    // ESTAGIO 6: ESCALA 1/2 + ARREDONDAMENTO + SATURACAO -> Q1.15
    // ========================================================================
    // Arredondamento "round half up": soma 0.5 LSB antes do deslocamento.
    // A saturacao e uma rede de seguranca: com o escalonamento de 1/2 por
    // estagio ela so pode atuar em sinais de entrada patologicos (parte real
    // e imaginaria simultaneamente em fundo de escala).
    // ATENCAO: a constante de arredondamento precisa ser um literal COM SINAL.
    // Uma concatenacao {..., 1'b1} e sempre tratada como SEM SINAL pelo
    // Verilog, o que contamina toda a expressao "value + round" e faz o
    // deslocamento ">>> 1" perder a extensao de sinal para 'value' negativo
    // (vira um shift logico). O sintoma e catastrofico: qualquer soma/
    // diferenca negativa do butterfly e interpretada como um numero positivo
    // enorme e satura erroneamente em +32767. Por isso a constante abaixo e
    // declarada como localparam COM SINAL (mesmo padrao usado em
    // FP_Mult_Unit.v, que nao sofre deste problema).
    localparam signed [W_S-1:0] ROUND_HALF = {{(W_S-1){1'b0}}, 1'b1};

    function signed [WIDTH-1:0] scale_round_sat;
        input signed [W_S-1:0] value;
        reg   signed [W_S-1:0] scaled;
        begin
            scaled = (value + ROUND_HALF) >>> 1;
            if (scaled > OUT_MAX)
                scale_round_sat = OUT_MAX[WIDTH-1:0];
            else if (scaled < OUT_MIN)
                scale_round_sat = OUT_MIN[WIDTH-1:0];
            else
                scale_round_sat = scaled[WIDTH-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            p_real <= {WIDTH{1'b0}};  p_imag <= {WIDTH{1'b0}};
            q_real <= {WIDTH{1'b0}};  q_imag <= {WIDTH{1'b0}};
        end else begin
            p_real <= scale_round_sat(sum_r);
            p_imag <= scale_round_sat(sum_i);
            q_real <= scale_round_sat(dif_r);
            q_imag <= scale_round_sat(dif_i);
        end
    end

    // ========================================================================
    // PIPELINE DE VALIDADE (acompanha os dados ao longo dos 6 estagios)
    // ========================================================================
    reg [LATENCY-1:0] valid_pipe;

    always @(posedge clk) begin
        if (rst)
            valid_pipe <= {LATENCY{1'b0}};
        else
            valid_pipe <= {valid_pipe[LATENCY-2:0], in_valid};
    end

    assign out_valid = valid_pipe[LATENCY-1];

endmodule
