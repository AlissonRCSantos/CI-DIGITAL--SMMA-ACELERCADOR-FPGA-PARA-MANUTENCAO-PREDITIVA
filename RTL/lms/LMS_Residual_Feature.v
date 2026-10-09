// ============================================================================
// Module: LMS_Residual_Feature
// Description: Controlador de janela do filtro adaptativo LMS (enunciado 3.4)
//              e extrator da caracteristica r_lms entregue ao classificador.
//
//              Este bloco NAO implementa o LMS: ele CONDUZ a instancia de
//              LMS_Filter_Top (8 coeficientes, mu = 2^-3) que fica no top
//              level, amostra a amostra, pela interface de handshake original
//              do filtro (start / valid_in / valid_out).
//
// ----------------------------------------------------------------------------
// O LMS COMO PREDITOR LINEAR
// ----------------------------------------------------------------------------
//   Para cada amostra decimada x[n] da janela (n = 1..1055):
//
//       in_x = x[n-1]           o filtro ve o passado ...
//       in_d = x[n]             ... e tenta prever o presente
//
//       y(n)   = sum_{i=0..7} w_i(n) x(n-1-i)        (dentro do LMS_Filter_Top)
//       e(n)   = d(n) - y(n)
//       w_i(n+1) = w_i(n) + mu e(n) x(n-1-i)
//
//   e acumula aqui as energias do erro e do sinal:
//
//       r_lms = sum e(n)^2 / sum d(n)^2          (Q1.15, Divider_Q15)
//
//   Sinal previsivel (tons, ressonancia de rolamento) -> residuo baixo;
//   ruido de banda larga (estado normal) -> residuo alto.
//
// ----------------------------------------------------------------------------
// ALINHAMENTO COM O MODELO TREINADO (smma/features.py, feature_lms_int)
// ----------------------------------------------------------------------------
//   - Cada janela comeca com pesos e linha de atraso ZERADOS: 'lms_clear'
//     pulsa o reset do LMS_Filter_Top no inicio da janela.
//   - x[0] NUNCA entra no preditor: a amostra 0 apenas inicializa o
//     historico com zero, e a amostra 1 e predita com historico nulo.
//   - e(n) usado nas energias e o erro SATURADO (out_error do filtro).
//
// ----------------------------------------------------------------------------
// RECURSOS E TEMPO
// ----------------------------------------------------------------------------
//   1 multiplicador 16x16 (energias e^2 e d^2, em sequencia) + 1 Divider_Q15.
//   Por amostra: 26 ciclos do LMS_Filter_Top + 3 de energia ~= 30 ciclos,
//   contra 15.625 ciclos entre amostras decimadas (3,2 kHz @ 50 MHz).
// ============================================================================

`timescale 1ns / 1ps

module LMS_Residual_Feature #(
    parameter WIDTH      = 16,     // Q1.15
    parameter FRAC       = 15,
    parameter N_AMOSTRAS = 1056,   // amostras decimadas por janela
    parameter ACC_W      = 48      // 1056 x 32768^2 cabe em 41 bits
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- Entrada: amostras decimadas da janela ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,

    // ---- Interface com o LMS_Filter_Top ----
    output reg                      lms_clear,    // reset dos pesos/historico
    output reg                      lms_start,    // start + valid_in do filtro
    output reg  signed [WIDTH-1:0]  lms_x,        // x(n-1)
    output reg  signed [WIDTH-1:0]  lms_d,        // d(n) = x(n)
    input  wire                     lms_busy,
    input  wire                     lms_valid_out,
    input  wire signed [WIDTH-1:0]  lms_error,    // e(n) saturado

    // ---- Saida: r_lms em Q1.15 ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output reg  signed [WIDTH-1:0]  out_feature
);

    localparam signed [WIDTH-1:0] SAT_MAX = (1 << (WIDTH-1)) - 1;

    // ------------------------------------------------------------------------
    // Estado
    // ------------------------------------------------------------------------
    reg [ACC_W-1:0]        se2, sd2;          // energias do erro e do sinal
    reg [11:0]             n_amostra;
    reg signed [WIDTH-1:0] e_reg;

    // multiplicador unico para os quadrados
    reg  signed [WIDTH-1:0]   ma;
    wire signed [2*WIDTH-1:0] quad = ma * ma;
    wire [ACC_W-1:0]          quad_ext = {{(ACC_W-2*WIDTH){1'b0}}, quad};  // >= 0

    // divisor
    reg              div_start;
    wire             div_ready, div_done, div_zero;
    wire [FRAC:0]    div_q;

    Divider_Q15 #(.NUM_W(ACC_W), .DEN_W(ACC_W), .FRAC(FRAC)) u_div (
        .clk(clk), .rst(rst), .start(div_start), .ready(div_ready),
        .done(div_done), .num(se2), .den(sd2),
        .quociente(div_q), .div_zero(div_zero)
    );

    localparam [3:0] S_IDLE   = 4'd0,
                     S_ESP    = 4'd1,   // espera amostra
                     S_GO     = 4'd2,   // pulso start/valid_in no LMS
                     S_RUN    = 4'd3,   // espera valid_out (e(n) pronto)
                     S_DRAIN  = 4'd4,   // espera a escrita dos pesos (busy=0)
                     S_SE2    = 4'd5,   // se2 += e^2
                     S_SD2    = 4'd6,   // sd2 += d^2
                     S_PROX   = 4'd7,
                     S_DIV    = 4'd8,
                     S_OUT    = 4'd9;
    reg [3:0] state;

    assign ready     = (state == S_IDLE);
    assign in_ready  = (state == S_ESP);
    assign out_valid = (state == S_OUT);

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            lms_clear   <= 1'b0;
            lms_start   <= 1'b0;
            lms_x       <= {WIDTH{1'b0}};
            lms_d       <= {WIDTH{1'b0}};
            se2         <= {ACC_W{1'b0}};
            sd2         <= {ACC_W{1'b0}};
            n_amostra   <= 12'd0;
            e_reg       <= {WIDTH{1'b0}};
            ma          <= {WIDTH{1'b0}};
            div_start   <= 1'b0;
            out_feature <= {WIDTH{1'b0}};
        end else begin
            done      <= 1'b0;
            lms_clear <= 1'b0;
            lms_start <= 1'b0;
            div_start <= 1'b0;

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        se2       <= {ACC_W{1'b0}};
                        sd2       <= {ACC_W{1'b0}};
                        n_amostra <= 12'd0;
                        lms_x     <= {WIDTH{1'b0}};   // historico vazio
                        lms_clear <= 1'b1;            // zera pesos e atrasos
                        busy      <= 1'b1;
                        state     <= S_ESP;
                    end
                end

                // ------------------------------------------------------
                S_ESP: begin
                    if (in_valid && in_ready) begin
                        lms_d <= in_sample;
                        if (n_amostra == 12'd0) begin
                            // x[0] so define que o historico comeca vazio:
                            // lms_x continua 0 e nada e predito.
                            n_amostra <= 12'd1;
                        end else begin
                            state <= S_GO;
                        end
                    end
                end

                // in_x / in_d ficam ESTAVEIS (registrados) ate o filtro os
                // capturar no ciclo de carga (ciclo 0 do seu escalonador).
                S_GO: begin
                    lms_start <= 1'b1;
                    state     <= S_RUN;
                end

                S_RUN: begin
                    if (lms_valid_out) begin
                        e_reg <= lms_error;
                        state <= S_DRAIN;
                    end
                end

                // Os pesos so terminam de ser gravados ~13 ciclos depois de
                // valid_out; a proxima amostra so pode entrar com o filtro
                // livre (busy = 0), senao leria pesos antigos.
                S_DRAIN: begin
                    if (!lms_busy) begin
                        ma    <= e_reg;
                        state <= S_SE2;
                    end
                end

                S_SE2: begin
                    se2   <= se2 + quad_ext;
                    ma    <= lms_d;
                    state <= S_SD2;
                end

                S_SD2: begin
                    sd2   <= sd2 + quad_ext;
                    state <= S_PROX;
                end

                S_PROX: begin
                    lms_x     <= lms_d;                 // x(n) vira x(n-1)
                    n_amostra <= n_amostra + 1'b1;
                    state     <= (n_amostra == N_AMOSTRAS - 1) ? S_DIV : S_ESP;
                end

                // ------------------------------------------------------
                // r_lms = se2 / sd2. Energia nula -> sinal imprevisivel,
                // r_lms = maximo (mesma convencao do modelo).
                // ------------------------------------------------------
                S_DIV: begin
                    if (div_done) begin
                        out_feature <= div_zero ? SAT_MAX : $signed(div_q);
                        state       <= S_OUT;
                    end else if (div_ready && !div_start) begin
                        div_start <= 1'b1;
                    end
                end

                S_OUT: begin
                    if (out_ready) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
