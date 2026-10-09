// ============================================================================
// CNN_MAC_Unit -- multiplica-acumula pipelinado em ponto fixo
// ============================================================================

`timescale 1ns / 1ps

module CNN_MAC_Unit #(
    parameter WIDTH = 16,   // Largura das entradas (Q1.15 por padrao)
    parameter ACC_W = 40    // Largura do acumulador (Q?.30 + bits de guarda)
)(
    input  wire                    clk,       // Clock do sistema (50 MHz)
    input  wire                    rst,       // Reset sincrono ativo em alto

    // Interface de controle
    input  wire                    en,        // Par (in_a,in_b) valido neste ciclo
    input  wire                    first,     // Marca o 1o produto da acumulacao
    input  wire                    last,      // Marca o ultimo produto da acumulacao
    input  wire signed [ACC_W-1:0] init_acc,  // Valor inicial (bias << FRAC)

    // Dados
    input  wire signed [WIDTH-1:0] in_a,      // Pixel / feature
    input  wire signed [WIDTH-1:0] in_b,      // Peso do kernel

    // Saidas
    output reg  signed [ACC_W-1:0] out_acc,   // Acumulador (valido em out_valid)
    output reg                     out_valid  // Pulso de 1 ciclo: soma completa
);

    // Estagio 1: registro das entradas (infere registrador de entrada do DSP)
    reg signed [WIDTH-1:0] s1_a, s1_b;
    reg signed [ACC_W-1:0] s1_init;
    reg                    s1_en, s1_first, s1_last;

    // Estagio 2: registro do produto (infere registrador de produto do DSP)
    reg signed [2*WIDTH-1:0] s2_prod;
    reg signed [ACC_W-1:0]   s2_init;
    reg                      s2_en, s2_first, s2_last;

    // Extensao de sinal do produto (2*WIDTH bits) para a largura do acumulador
    wire signed [ACC_W-1:0] prod_ext =
        { {(ACC_W-2*WIDTH){s2_prod[2*WIDTH-1]}}, s2_prod };

    always @(posedge clk) begin
        if (rst) begin
            s1_a     <= {WIDTH{1'b0}};
            s1_b     <= {WIDTH{1'b0}};
            s1_init  <= {ACC_W{1'b0}};
            s1_en    <= 1'b0;
            s1_first <= 1'b0;
            s1_last  <= 1'b0;

            s2_prod  <= {(2*WIDTH){1'b0}};
            s2_init  <= {ACC_W{1'b0}};
            s2_en    <= 1'b0;
            s2_first <= 1'b0;
            s2_last  <= 1'b0;

            out_acc   <= {ACC_W{1'b0}};
            out_valid <= 1'b0;
        end else begin
            // ---- Estagio 1 ----
            s1_a     <= in_a;
            s1_b     <= in_b;
            s1_init  <= init_acc;
            s1_en    <= en;
            s1_first <= first;
            s1_last  <= last;

            // ---- Estagio 2 ---- (multiplicacao sinalizada -> DSP)
            s2_prod  <= s1_a * s1_b;
            s2_init  <= s1_init;
            s2_en    <= s1_en;
            s2_first <= s1_first;
            s2_last  <= s1_last;

            // ---- Estagio 3 ---- (acumulacao)
            if (s2_en) begin
                if (s2_first)
                    out_acc <= s2_init + prod_ext;  // Carrega bias + 1o produto
                else
                    out_acc <= out_acc + prod_ext;  // Acumula
            end

            // Strobe de 1 ciclo quando o produto marcado como 'last' foi somado
            out_valid <= s2_en & s2_last;
        end
    end

endmodule
