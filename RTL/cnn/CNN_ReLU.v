// ============================================================================
// Module: CNN_ReLU
// Description: Unidade de ativacao / requantizacao da CNN. Faz as tres coisas
//              que precisam acontecer na saida de todo acumulador MAC:
//
//              1) REESCALA  : o acumulador esta em Q?.30 (produto de dois
//                             Q1.15). Precisamos voltar para Q1.15, o que
//                             significa descartar 15 bits fracionarios.
//                             Usa arredondamento simetrico (round-to-nearest),
//                             igual ao FP_Mult_Unit / FP_Arith_Unit do LMS.
//
//              2) SATURA    : se o valor reescalado nao couber em WIDTH bits,
//                             gruda no maximo/minimo representavel em vez de
//                             dar wrap-around (que viraria +max em -max e
//                             destruiria a classificacao).
//
//              3) ReLU      : aplica f(x) = max(0, x).
//
// Por que ReLU e praticamente de graca em hardware:
//   Em complemento de dois, "x < 0" e simplesmente "o bit mais significativo
//   (bit de sinal) e 1". Entao ReLU e literalmente:
//        saida = bit_de_sinal ? 0 : entrada
//   Ou seja, um unico multiplexador de 1 bit de selecao. Nenhum multiplicador,
//   nenhuma LUT de funcao, nenhuma memoria, zero ciclos de latencia.
//   E por isso que ReLU e a ativacao padrao em CNNs embarcadas, e nao
//   sigmoide/tanh (que exigiriam divisao e exponencial, ou LUTs grandes).
//
// Parametro ENABLE_RELU:
//   1 -> aplica ReLU (usado na saida da camada convolucional)
//   0 -> so reescala e satura (usado nos SCORES da camada densa, que precisam
//        poder ser negativos para o argmax funcionar corretamente)
//
// Bloco puramente COMBINACIONAL (latencia zero). Quem registra a saida e o
// modulo que o instancia.
// ============================================================================

`timescale 1ns / 1ps

module CNN_ReLU #(
    parameter ACC_W       = 40,  // Largura do acumulador de entrada
    parameter WIDTH       = 16,  // Largura da saida (Q1.15)
    parameter SHIFT       = 15,  // Bits fracionarios a descartar (FRAC)
    parameter ENABLE_RELU = 1    // 1: aplica max(0,x); 0: apenas satura
)(
    input  wire signed [ACC_W-1:0] in_acc,  // Acumulador bruto Q?.30
    output wire signed [WIDTH-1:0] out_y    // Ativacao Q1.15
);

    // ------------------------------------------------------------------------
    // 1) Reescala com arredondamento simetrico
    //    Soma metade do peso do LSB que sera descartado antes do shift.
    // ------------------------------------------------------------------------
    localparam signed [ACC_W-1:0] ROUND_VAL = (SHIFT > 0) ?
                                              (1 <<< (SHIFT - 1)) : 0;

    wire signed [ACC_W-1:0] scaled = (in_acc + ROUND_VAL) >>> SHIFT;

    // ------------------------------------------------------------------------
    // 2) Saturacao simetrica para WIDTH bits
    // ------------------------------------------------------------------------
    localparam signed [ACC_W-1:0] MAX_VAL =  (1 <<< (WIDTH - 1)) - 1; //  32767
    localparam signed [ACC_W-1:0] MIN_VAL = -(1 <<< (WIDTH - 1));     // -32768

    wire signed [WIDTH-1:0] sat =
        (scaled > MAX_VAL) ? MAX_VAL[WIDTH-1:0] :
        (scaled < MIN_VAL) ? MIN_VAL[WIDTH-1:0] :
                             scaled[WIDTH-1:0];

    // ------------------------------------------------------------------------
    // 3) ReLU: um unico MUX controlado pelo bit de sinal
    // ------------------------------------------------------------------------
    assign out_y = (ENABLE_RELU != 0) ?
                   (sat[WIDTH-1] ? {WIDTH{1'b0}} : sat) :
                   sat;

endmodule
