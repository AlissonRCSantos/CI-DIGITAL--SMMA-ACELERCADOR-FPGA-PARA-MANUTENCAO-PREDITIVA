// ============================================================================
// FFT_Bit_Reverse -- inversao de bits do endereco de carga da FFT
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
