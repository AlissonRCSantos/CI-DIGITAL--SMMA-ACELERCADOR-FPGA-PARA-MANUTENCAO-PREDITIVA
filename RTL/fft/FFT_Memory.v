// ============================================================================
// Module: FFT_Memory
// Description: Memoria de dados da FFT - RAM verdadeiramente dual-port (True
//              Dual-Port), com leitura registrada e computacao "in-place".
//
// Organizacao (restricao do enunciado: no maximo DUAS memorias internas para
// os dados da FFT):
//   - Uma UNICA instancia de 64 x 32 bits armazena o vetor complexo completo,
//     empacotando {parte imaginaria[15:0], parte real[15:0]} na mesma palavra.
//   - 64 x 32 = 2048 bits -> cabe em 1 unico bloco M10K do Cyclone V.
//   - Como a FFT e in-place, o resultado de cada estagio sobrescreve o proprio
//     operando: nao ha buffer de "ping-pong" entre estagios e o consumo de
//     memoria e constante (1 memoria), independentemente do numero de estagios.
//   - Sobra, portanto, 1 memoria do orcamento, que pode ser usada como buffer
//     de aquisicao (ping-pong) para carregar a proxima janela de 10 ms enquanto
//     a janela atual e processada. Basta instanciar este mesmo modulo 2x.
//
// Por que DUAS portas:
//   Cada operacao butterfly le 2 palavras (A e B) e escreve 2 palavras. Com
//   2 portas independentes temos 2 acessos por ciclo, logo 4 acessos por
//   butterfly = 2 ciclos/butterfly. O escalonador do FSM garante que as
//   LEITURAS ocorrem em ciclos pares e as ESCRITAS em ciclos impares, de modo
//   que as duas portas nunca disputam o mesmo recurso no mesmo ciclo e nunca
//   ha leitura e escrita simultaneas no mesmo endereco.
//
// Latencia de leitura: 1 ciclo (saida registrada) - necessario para inferir
// block RAM dedicada em vez de registradores distribuidos.
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

    // ------------------------------------------------------------------------
    // Porta A - escrita e leitura sincronas
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (a_we) begin
            mem[a_addr] <= a_din;
        end
        // Leitura registrada (modo read-first: nao ha acesso simultaneo ao
        // mesmo endereco pelo escalonamento do FSM, portanto o comportamento
        // de read-during-write e irrelevante para a funcionalidade)
        if (rst) begin
            a_dout <= {DATA_W{1'b0}};
        end else begin
            a_dout <= mem[a_addr];
        end
    end

    // ------------------------------------------------------------------------
    // Porta B - escrita e leitura sincronas
    // ------------------------------------------------------------------------
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
