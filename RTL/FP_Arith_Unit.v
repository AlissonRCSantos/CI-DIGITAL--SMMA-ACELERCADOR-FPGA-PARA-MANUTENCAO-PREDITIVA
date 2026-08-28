// FP_Arith_Unit.v
// Unidade de Soma e Subtração Parametrizável em Ponto Fixo (Verilog)
// Projetado para operação em alta frequência (50MHz+) no FPGA.

`timescale 1ns / 1ps

module FP_Arith_Unit #(
    parameter INT_A = 1,      // Número de bits inteiros de A (excluindo bit de sinal)
    parameter FRAC_A = 15,    // Número de bits fracionários de A
    parameter INT_B = 1,      // Número de bits inteiros de B (excluindo bit de sinal)
    parameter FRAC_B = 15,    // Número de bits fracionários de B
    parameter INT_Y = 1,      // Número de bits inteiros de Saída Y (excluindo bit de sinal)
    parameter FRAC_Y = 15,    // Número de bits fracionários de Saída Y
    parameter ROUNDING = 1    // 1: Arredondamento (Round to Nearest), 0: Truncamento
) (
    input  wire                     clk,      // Clock do sistema (50 MHz)
    input  wire                     rst,      // Reset síncrono ativo em alto
    input  wire                     add_sub,  // 0: Soma (A + B), 1: Subtração (A - B)
    input  wire [INT_A + FRAC_A:0]  in_A,     // Entrada A (sinalizada, Q(INT_A).(FRAC_A))
    input  wire [INT_B + FRAC_B:0]  in_B,     // Entrada B (sinalizada, Q(INT_B).(FRAC_B))
    output reg  [INT_Y + FRAC_Y:0]  out_Y     // Saída Y (sinalizada, Q(INT_Y).(FRAC_Y))
);

    // Larguras totais das palavras de entrada e saída
    localparam W_A = 1 + INT_A + FRAC_A;
    localparam W_B = 1 + INT_B + FRAC_B;
    localparam W_Y = 1 + INT_Y + FRAC_Y;

    // Determina o formato intermediário máximo para alinhamento
    localparam MAX_FRAC = (FRAC_A > FRAC_B) ? FRAC_A : FRAC_B;
    localparam MAX_INT  = (INT_A > INT_B) ? INT_A : INT_B;

    // O formato temporário ganha 1 bit extra na parte inteira para evitar overflow antes da saturação
    localparam INT_TEMP  = MAX_INT + 1;
    localparam FRAC_TEMP = MAX_FRAC;
    localparam W_TEMP    = 1 + INT_TEMP + FRAC_TEMP;

    // Deslocamentos necessários para alinhar os pontos binários
    localparam SHIFT_A = MAX_FRAC - FRAC_A;
    localparam SHIFT_B = MAX_FRAC - FRAC_B;

    // ---- ETAPA 1: ALINHAMENTO E SINALIZAÇÃO ----
    wire signed [W_A-1:0] s_A = in_A;
    wire signed [W_B-1:0] s_B = in_B;

    // Extensão de sinal síncrona/estática no Verilog
    wire signed [W_TEMP-1:0] sign_ext_A = s_A;
    wire signed [W_TEMP-1:0] sign_ext_B = s_B;

    // Alinhamento fracionário (shift-left insere zeros no LSB, mantendo o ponto binário alinhado em MAX_FRAC)
    wire signed [W_TEMP-1:0] aligned_A = sign_ext_A <<< SHIFT_A;
    wire signed [W_TEMP-1:0] aligned_B = sign_ext_B <<< SHIFT_B;

    // ---- ETAPA 2: OPERAÇÃO SÍNCRONA (PIPELINE DE CÁLCULO) ----
    reg signed [W_TEMP-1:0] sum_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sum_reg <= {W_TEMP{1'b0}};
        end else begin
            if (add_sub) begin
                sum_reg <= aligned_A - aligned_B;
            end else begin
                sum_reg <= aligned_A + aligned_B;
            end
        end
    end

    // ---- ETAPA 3: REDIMENSIONAMENTO DO FORMATO FRACIONÁRIO (ARREDONDAMENTO) ----
    wire signed [W_TEMP-1:0] shifted_sum;

    generate
        if (FRAC_TEMP > FRAC_Y) begin : g_frac_reduction
            localparam FRAC_DIFF = FRAC_TEMP - FRAC_Y;
            if (ROUNDING) begin : g_rounding
                // Soma a metade do peso do LSB descartado (0.5 de Y, ou seja, 1 << (FRAC_DIFF-1))
                // para realizar o arredondamento simétrico síncrono.
                wire signed [W_TEMP:0] sum_rounded = sum_reg + (1 << (FRAC_DIFF - 1));
                assign shifted_sum = sum_rounded[W_TEMP:0] >>> FRAC_DIFF;
            end else begin : g_truncation
                assign shifted_sum = sum_reg >>> FRAC_DIFF;
            end
        end else if (FRAC_TEMP < FRAC_Y) begin : g_frac_expansion
            localparam FRAC_DIFF = FRAC_Y - FRAC_TEMP;
            assign shifted_sum = sum_reg <<< FRAC_DIFF;
        end else begin : g_frac_equal
            assign shifted_sum = sum_reg;
        end
    endgenerate

    // ---- ETAPA 4: VERIFICAÇÃO DE OVERFLOW E SATURAÇÃO SIMÉTRICA ----
    reg [W_Y-1:0] sat_Y;

    generate
        if (W_TEMP > W_Y) begin : g_saturation_check
            localparam UPPER_WIDTH = W_TEMP - W_Y + 1;
            wire [UPPER_WIDTH-1:0] upper_bits = shifted_sum[W_TEMP-1 : W_Y-1];
            
            // Se o MSB (sinal) for 0, mas qualquer outro bit superior for 1 -> Overflow Positivo
            wire is_positive_overflow = (upper_bits[UPPER_WIDTH-1] == 1'b0) && (upper_bits[UPPER_WIDTH-2:0] != {(UPPER_WIDTH-1){1'b0}});
            // Se o MSB (sinal) for 1, mas qualquer outro bit superior for 0 -> Overflow Negativo (Underflow)
            wire is_negative_overflow = (upper_bits[UPPER_WIDTH-1] == 1'b1) && (upper_bits[UPPER_WIDTH-2:0] != {(UPPER_WIDTH-1){1'b1}});

            always @(*) begin
                if (is_positive_overflow) begin
                    sat_Y = {1'b0, {(W_Y-1){1'b1}}}; // Máximo positivo representável (011...11)
                end else if (is_negative_overflow) begin
                    sat_Y = {1'b1, {(W_Y-1){1'b0}}}; // Mínimo negativo representável (100...00)
                end else begin
                    sat_Y = shifted_sum[W_Y-1:0];
                end
            end
        end else begin : g_no_saturation_needed
            if (W_Y > W_TEMP) begin : g_padding
                always @(*) begin
                    sat_Y = { { (W_Y - W_TEMP){shifted_sum[W_TEMP-1]} }, shifted_sum };
                end
            end else begin : g_equal
                always @(*) begin
                    sat_Y = shifted_sum;
                end
            end
        end
    endgenerate

    // ---- ETAPA 5: REGISTRO DE SAÍDA SÍNCRONO ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_Y <= {W_Y{1'b0}};
        end else begin
            out_Y <= sat_Y;
        end
    end

endmodule
