// ============================================================================
// CNN_ReLU -- requantizacao, saturacao e ReLU na saida dos acumuladores
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

    // 1) Reescala com arredondamento simetrico
    //    Soma metade do peso do LSB que sera descartado antes do shift.
    localparam signed [ACC_W-1:0] ROUND_VAL = (SHIFT > 0) ?
                                              (1 <<< (SHIFT - 1)) : 0;

    wire signed [ACC_W-1:0] scaled = (in_acc + ROUND_VAL) >>> SHIFT;

    // 2) Saturacao simetrica para WIDTH bits
    localparam signed [ACC_W-1:0] MAX_VAL =  (1 <<< (WIDTH - 1)) - 1; //  32767
    localparam signed [ACC_W-1:0] MIN_VAL = -(1 <<< (WIDTH - 1));     // -32768

    wire signed [WIDTH-1:0] sat =
        (scaled > MAX_VAL) ? MAX_VAL[WIDTH-1:0] :
        (scaled < MIN_VAL) ? MIN_VAL[WIDTH-1:0] :
                             scaled[WIDTH-1:0];

    // 3) ReLU: um unico MUX controlado pelo bit de sinal
    assign out_y = (ENABLE_RELU != 0) ?
                   (sat[WIDTH-1] ? {WIDTH{1'b0}} : sat) :
                   sat;

endmodule
