// ============================================================================
// Spectrogram_Buffer -- espectrograma 32x32 (32 quadros da FFT) entregue a CNN
// ============================================================================

`timescale 1ns / 1ps

module Spectrogram_Buffer #(
    parameter WIDTH    = 16,     // Q1.15
    parameter N_BINS   = 32,     // bins por quadro (metade util da FFT de 64)
    parameter N_QUADROS = 32     // quadros por imagem
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,      // Pulso: inicia uma imagem
    output wire                     ready,      // Pronto para nova imagem
    output reg                      busy,
    output reg                      done,       // Pulso: imagem entregue

    // ---- Entrada: pixels, bin a bin, quadro a quadro ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire [WIDTH-1:0]         in_pixel,   // ja comprimido em log2

    // ---- Saida: 1024 pixels em ordem raster para a CNN ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire [WIDTH-1:0]         out_pixel
);

    localparam TOTAL  = N_BINS * N_QUADROS;      // 1024
    localparam ADDR_W = 10;                      // log2(1024)
    localparam CNT_W  = 6;                       // conta ate 32

    // Memoria da imagem. Endereco de ESCRITA e organizado por quadro
    reg [WIDTH-1:0] mem [0:TOTAL-1];

    reg [CNT_W-1:0]  bin_cnt;      // bin dentro do quadro corrente
    reg [CNT_W-1:0]  quadro_cnt;   // quadro dentro da imagem
    reg [ADDR_W-1:0] rd_addr;      // posicao de leitura (varredura raster)
    reg [WIDTH-1:0]  rd_dado;

    localparam [1:0] S_IDLE = 2'd0,
                     S_ENCHE = 2'd1,
                     S_LE    = 2'd2;
    reg [1:0] state;

    assign ready    = (state == S_IDLE);
    assign in_ready = (state == S_ENCHE);

    // leitura registrada (1 ciclo) -> 'out_valid' acompanha com um atraso
    reg rd_valid;
    assign out_valid = rd_valid;
    assign out_pixel = rd_dado;

    wire [ADDR_W-1:0] wr_addr = quadro_cnt * N_BINS + bin_cnt;

    // Endereco de leitura em ordem raster: linha = bin, coluna = quadro.
    wire [CNT_W-1:0] lin = rd_addr / N_QUADROS;      // bin
    wire [CNT_W-1:0] col = rd_addr % N_QUADROS;      // quadro
    wire [ADDR_W-1:0] rd_fisico = col * N_BINS + lin;

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            bin_cnt    <= {CNT_W{1'b0}};
            quadro_cnt <= {CNT_W{1'b0}};
            rd_addr    <= {ADDR_W{1'b0}};
            rd_valid   <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        bin_cnt    <= {CNT_W{1'b0}};
                        quadro_cnt <= {CNT_W{1'b0}};
                        busy       <= 1'b1;
                        state      <= S_ENCHE;
                    end
                end

                // Enche a memoria: 32 quadros x 32 bins
                S_ENCHE: begin
                    if (in_valid && in_ready) begin
                        mem[wr_addr] <= in_pixel;
                        if (bin_cnt == N_BINS - 1) begin
                            bin_cnt <= {CNT_W{1'b0}};
                            if (quadro_cnt == N_QUADROS - 1) begin
                                rd_addr  <= {ADDR_W{1'b0}};
                                rd_valid <= 1'b0;
                                state    <= S_LE;
                            end else begin
                                quadro_cnt <= quadro_cnt + 1'b1;
                            end
                        end else begin
                            bin_cnt <= bin_cnt + 1'b1;
                        end
                    end
                end

                // Entrega em ordem raster, com contrapressao.
                S_LE: begin
                    if (!rd_valid) begin
                        rd_dado  <= mem[rd_fisico];
                        rd_valid <= 1'b1;
                    end else if (out_ready) begin
                        // pixel consumido neste ciclo
                        if (rd_addr == TOTAL - 1) begin
                            rd_valid <= 1'b0;
                            busy     <= 1'b0;
                            done     <= 1'b1;
                            state    <= S_IDLE;
                        end else begin
                            rd_addr  <= rd_addr + 1'b1;
                            rd_valid <= 1'b0;      // forca recarga
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
