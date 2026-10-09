// ============================================================================
// LMS_Stage -- LMS em serie na entrada: repassa as amostras e calcula r_lms
// ============================================================================

`timescale 1ns / 1ps

module LMS_Stage #(
    parameter WIDTH      = 16,     // Q1.15
    parameter FRAC       = 15,
    parameter N_AMOSTRAS = 1056,   // amostras decimadas por janela
    parameter ACC_W      = 48,     // 1056 x 32768^2 cabe em 41 bits
    parameter SAIDA_LMS  = 0       // 0: repassa x(n)  1: repassa y(n)
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- Entrada: amostras decimadas (vindas do FIR_Decimator) ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,

    // ---- Saida: stream que segue para o Data_Bus_Driver ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_sample,

    // ---- Interface com o LMS_Filter_Top ----
    output reg                      lms_clear,    // reset dos pesos/historico
    output reg                      lms_start,    // start + valid_in do filtro
    output reg  signed [WIDTH-1:0]  lms_x,        // x(n-1)
    output reg  signed [WIDTH-1:0]  lms_d,        // d(n) = x(n)
    input  wire                     lms_busy,
    input  wire                     lms_valid_out,
    input  wire signed [WIDTH-1:0]  lms_y,        // y(n) saturado
    input  wire signed [WIDTH-1:0]  lms_error,    // e(n) saturado

    // ---- Caracteristica r_lms (Q1.15) para o banco de parametros ----
    input  wire                     feat_ready,
    output wire                     feat_valid,
    output reg  signed [WIDTH-1:0]  feat_lms
);

    localparam signed [WIDTH-1:0] SAT_MAX = (1 << (WIDTH-1)) - 1;

    // Estado
    reg [ACC_W-1:0]        se2, sd2;          // energias do erro e do sinal
    reg [11:0]             n_amostra;
    reg signed [WIDTH-1:0] e_reg, y_reg;

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
                     S_RUN    = 4'd3,   // espera valid_out (y(n), e(n) prontos)
                     S_DRAIN  = 4'd4,   // espera a escrita dos pesos (busy=0)
                     S_SE2    = 4'd5,   // se2 += e^2
                     S_SD2    = 4'd6,   // sd2 += d^2
                     S_EMITE  = 4'd7,   // entrega a amostra ao barramento
                     S_PROX   = 4'd8,
                     S_DIV    = 4'd9,
                     S_FEAT   = 4'd10;
    reg [3:0] state;

    assign ready      = (state == S_IDLE);
    assign in_ready   = (state == S_ESP);
    assign out_valid  = (state == S_EMITE);
    assign out_sample = (SAIDA_LMS != 0) ? y_reg : lms_d;
    assign feat_valid = (state == S_FEAT);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            lms_clear <= 1'b0;
            lms_start <= 1'b0;
            lms_x     <= {WIDTH{1'b0}};
            lms_d     <= {WIDTH{1'b0}};
            se2       <= {ACC_W{1'b0}};
            sd2       <= {ACC_W{1'b0}};
            n_amostra <= 12'd0;
            e_reg     <= {WIDTH{1'b0}};
            y_reg     <= {WIDTH{1'b0}};
            ma        <= {WIDTH{1'b0}};
            div_start <= 1'b0;
            feat_lms  <= {WIDTH{1'b0}};
        end else begin
            done      <= 1'b0;
            lms_clear <= 1'b0;
            lms_start <= 1'b0;
            div_start <= 1'b0;

            case (state)
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

                S_ESP: begin
                    if (in_valid && in_ready) begin
                        lms_d <= in_sample;
                        if (n_amostra == 12'd0) begin
                            // x[0] nao entra no preditor: e repassada direto
                            y_reg <= {WIDTH{1'b0}};
                            state <= S_EMITE;
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
                        y_reg <= lms_y;
                        state <= S_DRAIN;
                    end
                end

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
                    state <= S_EMITE;
                end

                // A amostra so segue para o barramento depois de passar
                // pelo LMS; o produtor (FIR) fica retido enquanto isso.
                S_EMITE: begin
                    if (out_ready)
                        state <= S_PROX;
                end

                S_PROX: begin
                    if (n_amostra != 12'd0)
                        lms_x <= lms_d;                 // x(n) vira x(n-1)
                    n_amostra <= n_amostra + 1'b1;
                    state     <= (n_amostra == N_AMOSTRAS - 1) ? S_DIV : S_ESP;
                end

                // r_lms = se2 / sd2. Energia nula -> sinal imprevisivel,
                // r_lms = maximo (mesma convencao do modelo).
                S_DIV: begin
                    if (div_done) begin
                        feat_lms <= div_zero ? SAT_MAX : $signed(div_q);
                        state    <= S_FEAT;
                    end else if (div_ready && !div_start) begin
                        div_start <= 1'b1;
                    end
                end

                S_FEAT: begin
                    if (feat_ready) begin
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
