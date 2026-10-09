// ============================================================================
// Module: FFT_Addr_Gen
// Description: Gerador combinacional de enderecos da FFT radix-2 DIT in-place.
//
//   A partir do par (estagio, indice do butterfly) este bloco produz:
//     - addr_p : endereco do operando superior A (que recebe A + t)
//     - addr_q : endereco do operando inferior B (que recebe A - t)
//     - tw_addr: indice k do fator de rotacao W_64^k usado no butterfly
//
// Mapeamento algoritmo -> arquitetura (Cooley-Tukey iterativo, DIT):
//
//   para s = 1 .. log2(N):                  // 6 estagios
//       m    = 2^s                          // tamanho do bloco DFT do estagio
//       half = m/2 = 2^(s-1)                // distancia entre A e B
//       para b = 0 .. N/2-1:                // 32 butterflies por estagio
//           j     = b mod half              // posicao dentro do bloco
//           grupo = b / half                // qual bloco DFT
//           p     = grupo*m + j
//           q     = p + half
//           k     = j * (N/m) = j << (log2N - s)
//
//   As divisoes/multiplicacoes por potencia de 2 viram deslocamentos, e as
//   operacoes de modulo viram mascaras de bits. O bloco e, portanto, apenas
//   um barrel shifter + AND + OR: sem multiplicadores e sem registradores.
//
//   Propriedade importante: dentro de um mesmo estagio todos os pares (p,q)
//   sao DISJUNTOS. Isso garante que nao existe hazard RAW entre butterflies
//   consecutivos e permite emitir um novo butterfly a cada 2 ciclos sem
//   qualquer logica de bypass.
//
// Custo: 0 DSP, 0 registradores, ~30 LUTs (barrel shifters de 6 bits).
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

    // p = grupo * 2^stage + j     (o OR substitui a soma pois os campos de
    //                              bits de 'group << stage' e 'j' nao se
    //                              sobrepoem: j < half <= 2^(stage-1))
    assign addr_p = (group << stage) | j;

    // q = p + half  (idem: o bit 'half' esta livre em p)
    assign addr_q = addr_p | half;

    // k = j * (N/m) = j << (LOG2N - stage)
    wire [LOG2N-1:0] tw_full = j << (LOG2N[2:0] - stage);
    assign tw_addr = tw_full[LOG2N-2:0];

endmodule
