// ============================================================================
// FFT_Memory -- RAM dual-port 64 x 32 bits da FFT (in-place)
// ============================================================================

`timescale 1ns / 1ps

module FFT_Memory #(
    parameter DATA_W = 32,  // Largura da palavra: {imag[15:0], real[15:0]}
    parameter ADDR_W = 6,   // log2(N) -> 64 posicoes
    parameter DEPTH  = 64   // Numero de pontos da FFT
)(
    input  wire                 clk,      // Clock do sistema (50 MHz)
    input  wire                 rst,      // Reset sincrono ativo em alto

    // ---- Porta A ----
    input  wire [ADDR_W-1:0]    a_addr,   // Endereco da porta A
    input  wire                 a_we,     // Write enable da porta A
    input  wire [DATA_W-1:0]    a_din,    // Dado de escrita da porta A
    output reg  [DATA_W-1:0]    a_dout,   // Dado lido da porta A (1 ciclo)

    // ---- Porta B ----
    input  wire [ADDR_W-1:0]    b_addr,   // Endereco da porta B
    input  wire                 b_we,     // Write enable da porta B
    input  wire [DATA_W-1:0]    b_din,    // Dado de escrita da porta B
    output reg  [DATA_W-1:0]    b_dout    // Dado lido da porta B (1 ciclo)
);

    // Array de memoria: o sintetizador infere 1 bloco M10K em modo True Dual-Port
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // Porta A - escrita e leitura sincronas
    always @(posedge clk) begin
        if (a_we) begin
            mem[a_addr] <= a_din;
        end
        if (rst) begin
            a_dout <= {DATA_W{1'b0}};
        end else begin
            a_dout <= mem[a_addr];
        end
    end

    // Porta B - escrita e leitura sincronas
    always @(posedge clk) begin
        if (b_we) begin
            mem[b_addr] <= b_din;
        end
        if (rst) begin
            b_dout <= {DATA_W{1'b0}};
        end else begin
            b_dout <= mem[b_addr];
        end
    end

endmodule
