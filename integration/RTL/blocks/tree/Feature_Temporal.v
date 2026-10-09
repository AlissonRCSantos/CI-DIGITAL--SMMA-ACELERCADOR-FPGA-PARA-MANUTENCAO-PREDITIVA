// ============================================================================
// Module: Feature_Temporal
// Description: Extrai as 4 caracteristicas TEMPORAIS do classificador
//              (enunciado 3.5): o residuo do preditor LMS e as tres
//              autocorrelacoes normalizadas da etapa de estimacao matricial.
//
// ----------------------------------------------------------------------------
// AS 4 SAIDAS (Q1.15, na ordem em que o classificador as espera)
// ----------------------------------------------------------------------------
//   8  r_lms   E[e^2] / E[x^2], residuo de um preditor LMS de 8 taps que
//              estima x[n] a partir de x[n-1..n-8], com mu = 2^-3.
//
//              Medido no dataset: falha de ROLAMENTO da residuo BAIXO
//              (~19500) e estado NORMAL da residuo ALTO (~32100). O sentido
//              e esse mesmo: depois do filtro de 1,4 kHz e da decimacao, o
//              toque de ressonancia do rolamento vira um sinal oscilatorio,
//              bem previsivel por um preditor linear, enquanto o estado
//              normal e ruido de banda larga de baixa amplitude, que o
//              preditor nao acompanha.
//
//   9  rho1
//   10 rho2    autocorrelacoes normalizadas r[k]/r[0], k = 1..3. Sao a saida
//   11 rho3    direta do autocorrelacao_yw.v -- a matriz que a etapa de
//              estimacao matricial monta.
//
//              Medido: usar rho1..rho3 no lugar dos coeficientes AR(3) da
//              acuracia MAIOR (0,9331 contra 0,9269), arvore menor (141
//              contra 149 nos) e dispensa resolver o sistema 3x3 no
//              hardware. O que saiu foi o solver, nao a origem do dado: as
//              tres origens exigidas pelo 3.5 continuam presentes.
//
// ----------------------------------------------------------------------------
// ARQUITETURA: 1 multiplicador para as 20 multiplicacoes de cada amostra
// ----------------------------------------------------------------------------
//   Por amostra sao necessarias 8 multiplicacoes para a saida do filtro, 8
//   para atualizar os pesos e 4 para a autocorrelacao -- 20 no total. Como
//   as amostras chegam a 3,2 kHz, ha 15.625 ciclos de 50 MHz entre elas e um
//   unico multiplicador resolve tudo com 0,13% de ocupacao. Os DSPs
//   economizados ficam para a CNN (8) e a FFT (4).
//
//   A aritmetica e a mesma do LMS_Filter_Top: produto Q1.15 com
//   arredondamento meio-para-cima e saturacao a cada passo. O modelo Python
//   (smma/features.py) implementa exatamente estas operacoes, porque os
//   limiares da arvore foram aprendidos sobre estes numeros.
//
//   Divisoes (4) usam o Divider_Q15 compartilhado. O divisor e sem sinal; o
//   sinal de rho e tratado fora dele, como no modelo.
// ============================================================================

`timescale 1ns / 1ps

module Feature_Temporal #(
    parameter WIDTH    = 16,    // Q1.15
    parameter FRAC     = 15,
    parameter N_TAPS   = 8,     // taps do preditor LMS
    parameter MU_SHIFT = 3,     // mu = 2^-3, igual ao LMS_Filter_Top
    parameter N_LAGS   = 3,     // rho1..rho3
    parameter ACC_W    = 48     // 1056 x 32768^2 cabe em 41 bits
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- Entrada: amostras decimadas da janela (Q1.15) ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,
    input  wire                     in_last,     // marca a ultima amostra

    // ---- Saida: 4 features em Q1.15 ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_feature
);

    localparam N_FEAT = 1 + N_LAGS;                  // r_lms + rho1..3
    localparam signed [WIDTH-1:0] SAT_MAX =  (1 << (WIDTH-1)) - 1;
    localparam signed [WIDTH-1:0] SAT_MIN = -(1 << (WIDTH-1));

    // ------------------------------------------------------------------------
    // Estado do preditor e da autocorrelacao
    // ------------------------------------------------------------------------
    // Duas historias, porque as duas features alinham o atraso de forma
    // diferente:
    //
    //   hist[0:7]  preditor LMS. Comeca VAZIA e so recebe x[n] depois de ser
    //              usada, de modo que a amostra 1 e predita com historico
    //              todo zero -- x[0] nunca entra no preditor. E assim que o
    //              modelo Python inicializa o filtro, e os limiares da arvore
    //              foram aprendidos sobre esses numeros.
    //
    //   hac[0:2]   autocorrelacao. Recebe TODAS as amostras, inclusive x[0],
    //              porque r[1] = soma x[n]*x[n-1] a partir de n = 1 e precisa
    //              de x[0]. Sao 3 registradores a mais; tentar reaproveitar
    //              hist aqui foi exatamente o que fez r_lms divergir.
    reg signed [WIDTH-1:0] hist [0:N_TAPS-1];        // hist[i] = x[n-1-i]
    reg signed [WIDTH-1:0] hac  [0:N_LAGS-1];        // hac[i]  = x[n-1-i]
    reg signed [WIDTH-1:0] w    [0:N_TAPS-1];
    reg signed [ACC_W-1:0] se2, sd2;                 // energia do erro e do sinal
    reg signed [ACC_W-1:0] r [0:N_LAGS];             // r[0..3]
    reg [15:0]             n_amostra;                // indice da amostra

    reg signed [WIDTH-1:0] d_reg;                    // x[n] corrente
    reg signed [WIDTH-1:0] y_acc;                    // saida parcial do filtro
    reg signed [WIDTH-1:0] es_reg;
    reg [3:0]              t;                        // indice do tap / lag

    // ------------------------------------------------------------------------
    // Multiplicador unico, com arredondamento e saturacao Q1.15
    // ------------------------------------------------------------------------
    reg  signed [WIDTH-1:0] ma, mb;
    wire signed [2*WIDTH-1:0] prod_raw = ma * mb;
    wire signed [2*WIDTH-1:0] prod_rnd = prod_raw + (1 <<< (FRAC-1));
    wire signed [2*WIDTH-1:0] prod_sh  = prod_rnd >>> FRAC;
    wire signed [WIDTH-1:0]   prod_q15 = (prod_sh > SAT_MAX) ? SAT_MAX :
                                         (prod_sh < SAT_MIN) ? SAT_MIN :
                                                               prod_sh[WIDTH-1:0];

    function signed [WIDTH-1:0] sat16;
        input signed [WIDTH:0] v;
        begin
            sat16 = (v > SAT_MAX) ? SAT_MAX : (v < SAT_MIN) ? SAT_MIN : v[WIDTH-1:0];
        end
    endfunction

    // ------------------------------------------------------------------------
    // Divisor compartilhado
    // ------------------------------------------------------------------------
    reg              div_start;
    reg  [ACC_W-1:0] div_num, div_den;
    wire             div_ready, div_done, div_zero;
    wire [15:0]      div_q;

    Divider_Q15 #(.NUM_W(ACC_W), .DEN_W(ACC_W), .FRAC(FRAC)) u_div (
        .clk(clk), .rst(rst), .start(div_start), .ready(div_ready),
        .done(div_done), .num(div_num), .den(div_den),
        .quociente(div_q), .div_zero(div_zero)
    );

    // ------------------------------------------------------------------------
    // Resultados
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] feat [0:N_FEAT-1];
    reg [2:0]              fi;          // indice da feature
    reg                    sinal_rho;   // sinal do r[k] corrente

    localparam [3:0] S_IDLE = 4'd0,
                     S_ESP  = 4'd1,   // espera amostra
                     S_Y    = 4'd2,   // 8 taps: y = sum w_i * hist_i
                     S_ERR  = 4'd3,   // e = d - y
                     S_SE2  = 4'd4,   // se2 += e*e
                     S_SD2  = 4'd5,   // sd2 += d*d
                     S_W    = 4'd6,   // 8 taps: w_i += mu*e*hist_i
                     S_AC   = 4'd7,   // 4 lags: r[k] += x[n]*x[n-k]
                     S_DESL = 4'd8,   // desloca a historia
                     S_DIV  = 4'd9,
                     S_OUT  = 4'd10;
    reg [3:0] state;

    // erro do preditor no ciclo corrente (combinacional, usado em S_ERR)
    wire signed [WIDTH-1:0] e_novo =
        sat16({d_reg[WIDTH-1], d_reg} - {y_acc[WIDTH-1], y_acc});

    assign ready       = (state == S_IDLE);
    assign in_ready    = (state == S_ESP);
    assign out_valid   = (state == S_OUT);
    assign out_feature = feat[fi];

    reg ultima;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            se2 <= 0; sd2 <= 0; n_amostra <= 16'd0;
            t <= 4'd0; fi <= 3'd0; div_start <= 1'b0; ultima <= 1'b0;
            y_acc <= 0; es_reg <= 0; d_reg <= 0; sinal_rho <= 1'b0;
            for (i = 0; i < N_TAPS; i = i + 1) begin
                hist[i] <= {WIDTH{1'b0}};
                w[i]    <= {WIDTH{1'b0}};
            end
            for (i = 0; i < N_LAGS; i = i + 1) hac[i] <= {WIDTH{1'b0}};
            for (i = 0; i <= N_LAGS; i = i + 1) r[i] <= 0;
            for (i = 0; i < N_FEAT; i = i + 1) feat[i] <= {WIDTH{1'b0}};
        end else begin
            done      <= 1'b0;
            div_start <= 1'b0;

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        se2 <= 0; sd2 <= 0; n_amostra <= 16'd0; ultima <= 1'b0;
                        for (i = 0; i < N_TAPS; i = i + 1) begin
                            hist[i] <= {WIDTH{1'b0}};
                            w[i]    <= {WIDTH{1'b0}};
                        end
                        for (i = 0; i < N_LAGS; i = i + 1) hac[i] <= {WIDTH{1'b0}};
                        for (i = 0; i <= N_LAGS; i = i + 1) r[i] <= 0;
                        busy  <= 1'b1;
                        state <= S_ESP;
                    end
                end

                // ------------------------------------------------------
                S_ESP: begin
                    if (in_valid && in_ready) begin
                        d_reg  <= in_sample;
                        ultima <= in_last;
                        y_acc  <= {WIDTH{1'b0}};
                        t      <= 4'd0;
                        // A amostra 0 nao tem historia: pula o filtro e vai
                        // direto para a autocorrelacao, como o modelo Python
                        // (que comeca o laco do LMS em n = 1).
                        if (n_amostra == 16'd0) begin
                            // amostra 0: o primeiro passo da autocorrelacao e
                            // r[0] += x[0]^2, logo os operandos sao a propria
                            // amostra -- nao os do filtro.
                            state <= S_AC;
                            ma <= in_sample; mb <= in_sample;
                        end else begin
                            state <= S_Y;
                            ma <= w[0]; mb <= hist[0];
                        end
                    end
                end

                // ------------------------------------------------------
                // y = sat(y + mult(w_i, hist_i)), um tap por ciclo
                // ------------------------------------------------------
                S_Y: begin
                    y_acc <= sat16({y_acc[WIDTH-1], y_acc} + {prod_q15[WIDTH-1], prod_q15});
                    if (t == N_TAPS - 1) begin
                        state <= S_ERR;
                    end else begin
                        t  <= t + 1'b1;
                        ma <= w[t + 1];
                        mb <= hist[t + 1];
                    end
                end

                // ------------------------------------------------------
                // e = sat(d - y). O erro vai para os dois acumuladores de
                // energia nos dois estados seguintes, reusando o MESMO
                // multiplicador -- nada de instanciar um 16x16 extra so para
                // elevar ao quadrado.
                S_ERR: begin
                    es_reg <= e_novo >>> MU_SHIFT;
                    ma     <= e_novo;      // se2 += e*e
                    mb     <= e_novo;
                    state  <= S_SE2;
                end

                S_SE2: begin
                    se2 <= se2 + {{(ACC_W-2*WIDTH){prod_raw[2*WIDTH-1]}}, prod_raw};
                    ma  <= d_reg;          // sd2 += d*d
                    mb  <= d_reg;
                    state <= S_SD2;
                end

                S_SD2: begin
                    sd2 <= sd2 + {{(ACC_W-2*WIDTH){prod_raw[2*WIDTH-1]}}, prod_raw};
                    t   <= 4'd0;
                    ma  <= es_reg;         // comeca a atualizacao dos pesos
                    mb  <= hist[0];
                    state <= S_W;
                end

                // ------------------------------------------------------
                // w_i = sat(w_i + mult(mu*e, hist_i))
                // ------------------------------------------------------
                S_W: begin
                    w[t] <= sat16({w[t][WIDTH-1], w[t]} + {prod_q15[WIDTH-1], prod_q15});
                    if (t == N_TAPS - 1) begin
                        t     <= 4'd0;
                        ma    <= d_reg;
                        mb    <= d_reg;
                        state <= S_AC;
                    end else begin
                        t  <= t + 1'b1;
                        ma <= es_reg;
                        mb <= hist[t + 1];
                    end
                end

                // ------------------------------------------------------
                // r[k] += x[n] * x[n-k], k = 0..3 (produto PLENO, sem Q1.15)
                // ------------------------------------------------------
                S_AC: begin
                    // so acumula o lag k quando ja existe x[n-k]
                    if (t == 4'd0 || n_amostra >= {12'd0, t})
                        r[t] <= r[t] + {{(ACC_W-2*WIDTH){prod_raw[2*WIDTH-1]}}, prod_raw};
                    if (t == N_LAGS) begin
                        state <= S_DESL;
                    end else begin
                        t  <= t + 1'b1;
                        ma <= d_reg;
                        mb <= hac[t];         // hac[t] = x[n-1-t] -> lag t+1
                    end
                end

                // ------------------------------------------------------
                S_DESL: begin
                    // A autocorrelacao guarda toda amostra, inclusive x[0].
                    for (i = N_LAGS - 1; i > 0; i = i - 1)
                        hac[i] <= hac[i-1];
                    hac[0] <= d_reg;
                    // O preditor NAO guarda x[0]: a amostra 1 e predita com
                    // historico zerado, como no modelo Python.
                    if (n_amostra != 16'd0) begin
                        for (i = N_TAPS - 1; i > 0; i = i - 1)
                            hist[i] <= hist[i-1];
                        hist[0] <= d_reg;
                    end
                    n_amostra <= n_amostra + 1'b1;
                    if (ultima) begin
                        fi    <= 3'd0;
                        state <= S_DIV;
                    end else begin
                        state <= S_ESP;
                    end
                end

                // ------------------------------------------------------
                // 4 divisoes: r_lms = se2/sd2 ; rho_k = |r[k]|/r[0]
                // ------------------------------------------------------
                S_DIV: begin
                    if (div_done) begin
                        // Casos de borda do modelo: com energia nula r_lms vale
                        // o maximo (sinal totalmente imprevisivel) e rho vale 0
                        // (sem correlacao definida). O divisor sinaliza isso em
                        // div_zero; o resto vem dele saturado em 32767.
                        feat[fi] <= (fi == 3'd0)
                                      ? (div_zero ? SAT_MAX : $signed(div_q))
                                      : (div_zero ? {WIDTH{1'b0}}
                                                  : (sinal_rho ? -$signed(div_q)
                                                               :  $signed(div_q)));
                        if (fi == N_FEAT - 1) begin
                            fi    <= 3'd0;
                            state <= S_OUT;
                        end else begin
                            fi <= fi + 1'b1;
                        end
                    end else if (div_ready && !div_start) begin
                        div_start <= 1'b1;
                        if (fi == 3'd0) begin
                            div_num   <= se2;
                            div_den   <= sd2;
                            sinal_rho <= 1'b0;
                        end else begin
                            div_num   <= r[fi][ACC_W-1] ? (-r[fi]) : r[fi];
                            div_den   <= r[0];
                            sinal_rho <= r[fi][ACC_W-1];
                        end
                    end
                end

                // ------------------------------------------------------
                S_OUT: begin
                    if (out_ready) begin
                        if (fi == N_FEAT - 1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            fi <= fi + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
