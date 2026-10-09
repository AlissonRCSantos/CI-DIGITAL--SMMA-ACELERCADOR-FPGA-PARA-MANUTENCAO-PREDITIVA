// ============================================================================
// FFT_Addr_Gen -- enderecos (p, q, k) de cada butterfly da FFT
// ============================================================================

`timescale 1ns / 1ps

module FFT_Addr_Gen #(
    parameter LOG2N = 6   // N = 2^LOG2N = 64 pontos
)(
    input  wire [2:0]         stage,     // Estagio corrente: 1 .. LOG2N
    input  wire [LOG2N-2:0]   bfly_idx,  // Indice do butterfly: 0 .. N/2-1
    output wire [LOG2N-1:0]   addr_p,    // Endereco do operando A
    output wire [LOG2N-1:0]   addr_q,    // Endereco do operando B
    output wire [LOG2N-2:0]   tw_addr    // Indice k do fator de rotacao
);

    // half = 2^(stage-1) : distancia entre os dois operandos do butterfly
    wire [LOG2N-1:0] half = {{(LOG2N-1){1'b0}}, 1'b1} << (stage - 3'd1);

    // Mascara para extrair j = bfly_idx mod half
    wire [LOG2N-1:0] half_mask = half - {{(LOG2N-1){1'b0}}, 1'b1};

    // Indice do butterfly estendido para a largura dos enderecos
    wire [LOG2N-1:0] b_ext = {1'b0, bfly_idx};

    // j = posicao dentro do bloco DFT ; grupo = qual bloco DFT
    wire [LOG2N-1:0] j     = b_ext & half_mask;
    wire [LOG2N-1:0] group = b_ext >> (stage - 3'd1);

    assign addr_p = (group << stage) | j;

    // q = p + half  (idem: o bit 'half' esta livre em p)
    assign addr_q = addr_p | half;

    // k = j * (N/m) = j << (LOG2N - stage)
    wire [LOG2N-1:0] tw_full = j << (LOG2N[2:0] - stage);
    assign tw_addr = tw_full[LOG2N-2:0];

endmodule
