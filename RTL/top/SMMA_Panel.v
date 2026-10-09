// ============================================================================
// SMMA_Panel -- saida: classes nos displays HEX e LEDs da DE0-CV
// ============================================================================

`timescale 1ns / 1ps

module SMMA_Panel (
    input  wire [9:0]  SW,

    // ---- Veredito ----
    input  wire        r_valido,
    input  wire [1:0]  r_tree_class,
    input  wire [1:0]  r_cnn_class,
    input  wire [1:0]  r_verdadeira,
    input  wire        r_tree_err,
    input  wire        fir_overflow,
    input  wire [1:0]  classe_modelo,      // previsao do modelo Python (ROM)
    input  wire [3:0]  cnn_scores_lsb,     // 4 LSB dos scores da CNN
    input  wire        ocupado,

    // ---- MDC ----
    input  wire [13:0] f0_hz,              // frequencia fundamental (Hz)
    input  wire        f0_erro,            // MDC invalido

    // ---- Placa ----
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);

    function [6:0] seg7;                // ativo em BAIXO na DE0-CV
        input [3:0] v;
        begin
            case (v)
                4'h0: seg7 = 7'b1000000;  4'h1: seg7 = 7'b1111001;
                4'h2: seg7 = 7'b0100100;  4'h3: seg7 = 7'b0110000;
                4'h4: seg7 = 7'b0011001;  4'h5: seg7 = 7'b0010010;
                4'h6: seg7 = 7'b0000010;  4'h7: seg7 = 7'b1111000;
                4'h8: seg7 = 7'b0000000;  4'h9: seg7 = 7'b0010000;
                4'hE: seg7 = 7'b0000110;  // 'E' de erro
                default: seg7 = 7'b1111111;   // apagado
            endcase
        end
    endfunction

    localparam [6:0] APAGADO = 7'b1111111;

    // ---- janela selecionada ----
    wire [3:0] jan_dez = SW[3:0] / 4'd10;
    wire [3:0] jan_uni = SW[3:0] % 4'd10;

    // ---- modo padrao ----
    wire [6:0] hex0_cls = r_valido ? seg7({2'b00, r_tree_class}) : APAGADO;
    wire [6:0] hex1_cls = r_valido ? seg7({2'b00, r_cnn_class})  : APAGADO;
    wire [6:0] hex2_cls = r_valido ? seg7({2'b00, r_verdadeira}) : APAGADO;
    wire [6:0] hex3_cls = (r_valido && (r_tree_err || fir_overflow)) ? seg7(4'hE)
                                                                     : APAGADO;

    // ---- modo MDC: f0 em decimal, zeros a esquerda apagados ----
    wire [13:0] f0_sat = (f0_hz > 14'd9999) ? 14'd9999 : f0_hz;
    wire [3:0]  d_mil  = f0_sat / 14'd1000;
    wire [3:0]  d_cen  = (f0_sat / 14'd100) % 14'd10;
    wire [3:0]  d_dez  = (f0_sat / 14'd10)  % 14'd10;
    wire [3:0]  d_uni  = f0_sat % 14'd10;

    wire [6:0] hex0_f0 = r_valido ? seg7(d_uni) : APAGADO;
    wire [6:0] hex1_f0 = (r_valido && f0_sat >= 14'd10)   ? seg7(d_dez) : APAGADO;
    wire [6:0] hex2_f0 = (r_valido && f0_sat >= 14'd100)  ? seg7(d_cen) : APAGADO;
    wire [6:0] hex3_f0 = !r_valido ? APAGADO
                       : f0_erro   ? seg7(4'hE)
                       : (f0_sat >= 14'd1000) ? seg7(d_mil) : APAGADO;

    wire modo_mdc = SW[8];

    assign HEX0 = modo_mdc ? hex0_f0 : hex0_cls;
    assign HEX1 = modo_mdc ? hex1_f0 : hex1_cls;
    assign HEX2 = modo_mdc ? hex2_f0 : hex2_cls;
    assign HEX3 = modo_mdc ? hex3_f0 : hex3_cls;
    assign HEX4 = seg7(jan_uni);
    assign HEX5 = seg7(jan_dez);

    // ---- LEDs ----
    wire [3:0] arv_onehot = r_valido ? (4'b0001 << r_tree_class) : 4'b0000;

    assign LEDR[3:0] = SW[9] ? cnn_scores_lsb : arv_onehot;
    assign LEDR[4]   = r_valido && (r_tree_class == r_verdadeira);
    assign LEDR[5]   = r_valido && (r_cnn_class  == r_verdadeira);
    assign LEDR[6]   = r_valido && (r_tree_class == r_cnn_class);
    assign LEDR[7]   = (classe_modelo == r_verdadeira) && r_valido;
    assign LEDR[8]   = ocupado;
    assign LEDR[9]   = r_valido;

endmodule
