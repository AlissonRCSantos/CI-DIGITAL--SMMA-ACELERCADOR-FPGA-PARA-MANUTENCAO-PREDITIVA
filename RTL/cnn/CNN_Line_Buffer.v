// ============================================================================
// CNN_Line_Buffer -- janelas 3x3 por line buffers, com zero-padding
// ============================================================================

`timescale 1ns / 1ps

module CNN_Line_Buffer #(
    parameter WIDTH = 16,   // Largura do pixel (Q1.15)
    parameter IMG_W = 32,   // Largura da imagem
    parameter IMG_H = 32,   // Altura da imagem
    parameter CNT_W = 6     // Bits dos contadores (precisa contar ate IMG_W)
)(
    input  wire                    clk,        // Clock do sistema (50 MHz)
    input  wire                    rst,        // Reset sincrono ativo em alto

    // Controle de quadro
    input  wire                    start,      // Pulso: inicia um novo quadro
    input  wire                    push_en,    // Avanca um passo da varredura
    input  wire                    win_ack,    // Consumidor aceitou a janela atual

    // Entrada de pixel
    input  wire signed [WIDTH-1:0] in_pixel,   // Pixel real da imagem
    output wire                    need_pixel, // 1: este passo consome um pixel real
    output wire                    last_push,  // 1: este e o ultimo passo do quadro

    // Saida da janela 3x3 (achatada: indice k = linha*3 + coluna)
    output wire [9*WIDTH-1:0]      out_win,    // {w22,w21,w20,w12,w11,w10,w02,w01,w00}
    output reg                     win_valid,  // Janela valida neste ciclo
    output reg  [CNT_W-1:0]        out_row,    // Coordenada da janela (linha)
    output reg  [CNT_W-1:0]        out_col     // Coordenada da janela (coluna)
);

    // 1. Contadores de varredura (vao ate IMG_W / IMG_H INCLUSIVE = padding)
    reg [CNT_W-1:0] p_row;   // 0 .. IMG_H
    reg [CNT_W-1:0] p_col;   // 0 .. IMG_W

    // Existe pixel real neste passo? (fora disso, empurramos zero de padding)
    assign need_pixel = (p_row < IMG_H) && (p_col < IMG_W);
    assign last_push  = (p_row == IMG_H) && (p_col == IMG_W);

    // Valor efetivamente empurrado: pixel real ou zero de padding
    wire signed [WIDTH-1:0] px = need_pixel ? in_pixel : {WIDTH{1'b0}};

    // 2. Memorias de linha (line buffers)
    reg signed [WIDTH-1:0] line_mem0 [0:IMG_W];
    reg signed [WIDTH-1:0] line_mem1 [0:IMG_W];

    // Leitura combinacional ANTES da escrita (le o valor antigo no mesmo ciclo)
    wire signed [WIDTH-1:0] mid = line_mem0[p_col];  // pixel (r-1, c)
    wire signed [WIDTH-1:0] top = line_mem1[p_col];  // pixel (r-2, c)

    // 3. Registradores da janela 3x3 (registradores "planos", sem array,
    reg signed [WIDTH-1:0] w00, w01, w02;
    reg signed [WIDTH-1:0] w10, w11, w12;
    reg signed [WIDTH-1:0] w20, w21, w22;

    assign out_win = {w22, w21, w20, w12, w11, w10, w02, w01, w00};

    integer i;

    always @(posedge clk) begin
        if (rst || start) begin
            // ---- Limpa contadores, janela e memorias de linha ----
            p_row     <= {CNT_W{1'b0}};
            p_col     <= {CNT_W{1'b0}};
            win_valid <= 1'b0;
            out_row   <= {CNT_W{1'b0}};
            out_col   <= {CNT_W{1'b0}};

            w00 <= {WIDTH{1'b0}}; w01 <= {WIDTH{1'b0}}; w02 <= {WIDTH{1'b0}};
            w10 <= {WIDTH{1'b0}}; w11 <= {WIDTH{1'b0}}; w12 <= {WIDTH{1'b0}};
            w20 <= {WIDTH{1'b0}}; w21 <= {WIDTH{1'b0}}; w22 <= {WIDTH{1'b0}};

            for (i = 0; i <= IMG_W; i = i + 1) begin
                line_mem0[i] <= {WIDTH{1'b0}};
                line_mem1[i] <= {WIDTH{1'b0}};
            end
        end else if (push_en) begin
            // 3.1 Desloca a janela e insere a coluna nova {top, mid, px}
            if (p_col == {CNT_W{1'b0}}) begin
                // Inicio de linha: as duas colunas a esquerda sao PADDING (zero)
                w00 <= {WIDTH{1'b0}}; w01 <= {WIDTH{1'b0}}; w02 <= top;
                w10 <= {WIDTH{1'b0}}; w11 <= {WIDTH{1'b0}}; w12 <= mid;
                w20 <= {WIDTH{1'b0}}; w21 <= {WIDTH{1'b0}}; w22 <= px;
            end else begin
                // Deslocamento normal para a esquerda
                w00 <= w01; w01 <= w02; w02 <= top;
                w10 <= w11; w11 <= w12; w12 <= mid;
                w20 <= w21; w21 <= w22; w22 <= px;
            end

            // 3.2 Atualiza as memorias de linha (cascata r-1 -> r-2)
            line_mem1[p_col] <= mid;  // o que era r-1 vira r-2
            line_mem0[p_col] <= px;   // o pixel atual vira a nova r-1

            // 3.3 Validacao e coordenadas da janela emitida
            //     A janela fica centrada em (p_row-1, p_col-1)
            win_valid <= (p_row != {CNT_W{1'b0}}) && (p_col != {CNT_W{1'b0}});
            out_row   <= p_row - 1'b1;
            out_col   <= p_col - 1'b1;

            // 3.4 Avanco da varredura raster (inclui coluna/linha de padding)
            if (p_col == IMG_W) begin
                p_col <= {CNT_W{1'b0}};
                if (p_row == IMG_H)
                    p_row <= {CNT_W{1'b0}};   // quadro terminou
                else
                    p_row <= p_row + 1'b1;
            end else begin
                p_col <= p_col + 1'b1;
            end
        end else if (win_ack) begin
            win_valid <= 1'b0;
        end
    end

endmodule
