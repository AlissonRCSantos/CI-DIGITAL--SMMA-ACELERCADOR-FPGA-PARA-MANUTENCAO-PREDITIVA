// ============================================================================
// Module: FFT_Bit_Reverse
// Description: Reversor de bits (bit-reversal) puramente combinacional.
//
//   A FFT radix-2 por decimacao no tempo (DIT) executada "in-place" exige que
//   as amostras sejam armazenadas em ordem de bits invertidos. Assim, o
//   resultado sai em ordem natural de frequencia (bin 0, 1, 2, ... N-1) e o
//   detector de picos / modulo MDC recebe os indices espectrais ja corretos.
//
//   Exemplo para N = 64 (LOG2N = 6):
//       n = 1  = 000001b  ->  bit_rev = 100000b = 32
//       n = 3  = 000011b  ->  bit_rev = 110000b = 48
//       n = 12 = 001100b  ->  bit_rev = 001100b = 12
//
// Custo de hardware: ZERO. A inversao de bits e apenas um reordenamento de
// fios (roteamento), sem LUTs, registradores ou ciclos de clock. Por isso ela
// e aplicada no momento da ESCRITA das amostras de entrada, evitando um passo
// de permutacao em memoria que custaria N ciclos adicionais.
//
// O laco 'for' abaixo e desenrolado em tempo de sintese (limite constante
// LOG2N), atendendo a restricao do enunciado de que lacos em HDL devem ter
// limites determinaveis em tempo de sintese.
// ============================================================================

`timescale 1ns / 1ps

module FFT_Bit_Reverse #(
    parameter LOG2N = 6   // Numero de bits do indice (N = 2^LOG2N = 64)
)(
    input  wire [LOG2N-1:0] index_in,   // Indice em ordem natural
    output wire [LOG2N-1:0] index_out   // Indice com os bits invertidos
);

    genvar i;
    generate
        for (i = 0; i < LOG2N; i = i + 1) begin : g_reverse
            assign index_out[i] = index_in[LOG2N-1-i];
        end
    endgenerate

endmodule
