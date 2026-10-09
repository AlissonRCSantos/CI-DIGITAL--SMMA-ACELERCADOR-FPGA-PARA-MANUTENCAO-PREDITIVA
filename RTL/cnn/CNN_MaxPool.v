// ============================================================================
// CNN_MaxPool -- max pooling 2x2, stride 2, em streaming
// ============================================================================

`timescale 1ns / 1ps

module CNN_MaxPool #(
    parameter WIDTH  = 16,
    parameter NUM_CH = 8,     // Canais (mapas de caracteristicas) em paralelo
    parameter IN_W   = 32,    // Largura do mapa de entrada (deve ser par)
    parameter IN_H   = 32,    // Altura do mapa de entrada (deve ser par)
    parameter CNT_W  = 6,     // Bits dos contadores de linha/coluna
    parameter IDX_W  = 4      // Bits do indice do buffer: log2(IN_W/2)
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start,      // Pulso: reinicia o quadro

    // ---- Entrada: 1 pixel de cada um dos NUM_CH mapas, em ordem raster ----
    input  wire                     in_valid,
    input  wire [NUM_CH*WIDTH-1:0]  in_data,

    // ---- Saida: mapa reduzido (tambem em ordem raster) ----
    output reg                      out_valid,
    output reg  [NUM_CH*WIDTH-1:0]  out_data
);

    // 1. Contadores de posicao na imagem de entrada
    reg [CNT_W-1:0] in_row;
    reg [CNT_W-1:0] in_col;

    // 2. Armazenamento minimo: registrador de coluna + buffer de meia-linha
    reg [NUM_CH*WIDTH-1:0] prev_data;               // pixel da coluna PAR
    reg [NUM_CH*WIDTH-1:0] row_buf [0:(IN_W/2)-1];  // maximos das linhas PARES

    wire [IDX_W-1:0]        pair_idx   = in_col[IDX_W:1];   // in_col / 2
    wire [NUM_CH*WIDTH-1:0] row_buf_rd = row_buf[pair_idx];

    // 3. Comparadores paralelos (um conjunto por canal)
    wire [NUM_CH*WIDTH-1:0] pair_max;   // max(coluna par, coluna impar)
    wire [NUM_CH*WIDTH-1:0] quad_max;   // max(pair_max, linha de cima)

    genvar c;
    generate
        for (c = 0; c < NUM_CH; c = c + 1) begin : g_cmp
            wire signed [WIDTH-1:0] v_prev = prev_data [c*WIDTH +: WIDTH];
            wire signed [WIDTH-1:0] v_cur  = in_data   [c*WIDTH +: WIDTH];
            wire signed [WIDTH-1:0] v_up   = row_buf_rd[c*WIDTH +: WIDTH];

            assign pair_max[c*WIDTH +: WIDTH] = (v_prev > v_cur) ? v_prev : v_cur;

            wire signed [WIDTH-1:0] v_pair = (v_prev > v_cur) ? v_prev : v_cur;
            assign quad_max[c*WIDTH +: WIDTH] = (v_up > v_pair) ? v_up : v_pair;
        end
    endgenerate

    // 4. Maquina de fluxo
    integer i;

    always @(posedge clk) begin
        if (rst || start) begin
            in_row    <= {CNT_W{1'b0}};
            in_col    <= {CNT_W{1'b0}};
            prev_data <= {(NUM_CH*WIDTH){1'b0}};
            out_valid <= 1'b0;
            out_data  <= {(NUM_CH*WIDTH){1'b0}};
            for (i = 0; i < (IN_W/2); i = i + 1)
                row_buf[i] <= {(NUM_CH*WIDTH){1'b0}};
        end else begin
            out_valid <= 1'b0;   // por padrao, sem saida neste ciclo

            if (in_valid) begin
                if (in_col[0] == 1'b0) begin
                    // -------- Coluna PAR: apenas memoriza --------
                    prev_data <= in_data;
                end else begin
                    // -------- Coluna IMPAR: o par 1x2 esta completo --------
                    if (in_row[0] == 1'b0) begin
                        // Linha PAR: guarda o maximo parcial e espera a proxima linha
                        row_buf[pair_idx] <= pair_max;
                    end else begin
                        // Linha IMPAR: fecha a janela 2x2 e emite o resultado
                        out_data  <= quad_max;
                        out_valid <= 1'b1;
                    end
                end

                // ---- Avanca a varredura raster ----
                if (in_col == (IN_W-1)) begin
                    in_col <= {CNT_W{1'b0}};
                    if (in_row == (IN_H-1))
                        in_row <= {CNT_W{1'b0}};
                    else
                        in_row <= in_row + 1'b1;
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end
        end
    end

endmodule
