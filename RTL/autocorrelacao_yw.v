`timescale 1ns/1ps

// =====================================================================
// autocorrelacao_yw.v 
//
// Mudanca em relacao a versao original: a saida agora e normalizada
// (r_data = r[k] / r[0]), em vez da soma bruta. Motivo: a soma bruta de
// 64 termos estoura os 16 bits Q4.12 (so representa -8..+7.9997), mas
// a correlacao normalizada fica sempre entre -1 e +1, cabendo com
// folga no mesmo formato. Isso tambem eh o formato certo pra alimentar
// o gauss_jordan_inv (equacoes de Yule-Walker usam correlacao
// normalizada, nao a soma bruta).
//
// Reaproveita o fixed_point_divider.v ja existente no projeto (mesmo
// modulo usado pelo gauss_jordan_inv), so que instanciado com WIDTH=32
// aqui dentro, porque a soma bruta de 64 termos pode passar de 16 bits.
// O modulo continua separado/reutilizavel, so usado em mais um lugar.
//
// Tambem corrige um off-by-one: a versao original perdia o ultimo termo
// da soma (n=63) ao capturar r_out usando o valor do acumulador ANTES
// da ultima soma ser somada. Esse termo so afeta r[0] na pratica (pra
// k>=1 o ultimo termo ja era zero por causa do zero-padding), mas a
// correcao e imediata: usar (acc+mult) em vez de so "acc" no instante
// da captura.
// =====================================================================

module autocorrelacao_yw #(
    parameter WIDTH = 16,
    parameter FRAC = 12
)(
    input wire clk,
    input wire reset,

    // Interface com o filtro LMS
    input wire lms_valid,
    input wire signed [WIDTH-1:0] lms_data,

    // Sinais de Controle e Saída
    output reg busy,
    output reg r_valid,
    output reg [2:0] r_index,
    output reg signed [WIDTH-1:0] r_data
);

    // Estados da FSM
    localparam S_IDLE       = 4'd0;
    localparam S_FILL       = 4'd1;
    localparam S_CALC_0_1   = 4'd2;
    localparam S_CALC_2_3   = 4'd3;
    localparam S_CALC_4     = 4'd4;
    localparam S_NORM_START = 4'd5; // dispara a divisao r[k]/r[0]
    localparam S_NORM_WAIT  = 4'd6; // espera o divisor terminar
    localparam S_NORM_NEXT  = 4'd7; // avanca para o proximo k
    localparam S_SEND_OUT   = 4'd8;

    reg [3:0] state;

    // Shift Register para as 64 amostras
    reg signed [WIDTH-1:0] shift_reg [0:63];
    reg [6:0] sample_count;

    // Controle do laço de cálculo
    reg [6:0] n;
    reg [2:0] send_count;

    // Acumuladores largos o suficiente para a soma bruta (nao normalizada)
    // de ate 64 termos. Pior caso: amostras no limite da faixa (+-8 em
    // Q4.12), termo individual ~2^30, somado 64x (2^6) = ~2^36; 48 bits
    reg signed [47:0] acc1, acc2;

    // Soma bruta (NAO normalizada, NAO cortada) dos 5 lags.
    reg signed [47:0] raw_out [0:4];

    // Resultado final, ja normalizado (r[k]/r[0]), pronto pra enviar.
    reg signed [WIDTH-1:0] r_out [0:4];

    // Indice do lag sendo normalizado no momento (0 a 4)
    reg [2:0] norm_k;

    // -------------------------------------------------------------------------
    // Instanciação de APENAS 2 Multiplicadores Combinacionais (Reutilizados)
    // -------------------------------------------------------------------------
    reg [2:0] k1_val, k2_val;

    wire [6:0] idx_k1 = n + k1_val;
    wire [6:0] idx_k2 = n + k2_val;

    wire signed [WIDTH-1:0] val_n  = shift_reg[n];
    wire signed [WIDTH-1:0] val_k1 = (idx_k1 < 64) ? shift_reg[idx_k1] : 16'd0;
    wire signed [WIDTH-1:0] val_k2 = (idx_k2 < 64) ? shift_reg[idx_k2] : 16'd0;

    wire signed [2*WIDTH-1:0] mult1 = val_n * val_k1;
    wire signed [2*WIDTH-1:0] mult2 = val_n * val_k2;

    // -------------------------------------------------------------------------
    // Divisor para normalizacao: r_out[k] = raw_out[k] / raw_out[0], em Q4.12.
    // Reaproveita o fixed_point_divider.v generico, com WIDTH=32 porque
    // raw_out[k] e raw_out[0] sao somas brutas de 32 bits.
    //   numerador (pre-deslocado) = raw_out[norm_k] <<< FRAC   (64 bits)
    //   denominador               = raw_out[0]                (32 bits)
    //   quociente                 = (raw_out[norm_k]/raw_out[0]) * 2^FRAC
    // O quociente real sempre cabe em -1..+1 (*4096), entao os 16 bits
    // baixos do quociente de 32 bits ja sao o r_data final.
    // -------------------------------------------------------------------------
    reg                      div_start;
    reg  signed [95:0]       div_numerator;
    reg  signed [47:0]       div_denominator;
    wire signed [47:0]       div_quotient;
    wire                     div_done;
    wire                     div_by_zero;

    fixed_point_divider #(
        .WIDTH(48),
        .FRAC(FRAC)
    ) u_norm_div (
        .clk          (clk),
        .rst          (reset),
        .enable       (1'b1),
        .start        (div_start),
        .numerator    (div_numerator),
        .denominator  (div_denominator),
        .quotient     (div_quotient),
        .done         (div_done),
        .div_by_zero  (div_by_zero)
    );

    // -------------------------------------------------------------------------
    // Máquina de Estados (FSM) Principal
    // -------------------------------------------------------------------------
    integer i;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            busy <= 1'b0;
            r_valid <= 1'b0;
            sample_count <= 7'd0;
            n <= 7'd0;
            div_start <= 1'b0;
            norm_k <= 3'd0;
            for (i = 0; i < 64; i = i + 1) shift_reg[i] <= 16'd0;
        end else begin
            r_valid <= 1'b0;   // Default: dado de saída inválido
            div_start <= 1'b0; // Default: nao dispara divisao

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (lms_valid) begin
                        busy <= 1'b1;
                        shift_reg[0] <= lms_data;
                        sample_count <= 7'd1;
                        state <= S_FILL;
                    end
                end

                S_FILL: begin
                    if (lms_valid) begin
                        for (i = 63; i > 0; i = i - 1) begin
                            shift_reg[i] <= shift_reg[i-1];
                        end
                        shift_reg[0] <= lms_data;
                        sample_count <= sample_count + 1'b1;

                        if (sample_count == 7'd63) begin
                            state <= S_CALC_0_1;
                            n <= 7'd0;
                            acc1 <= 32'd0;
                            acc2 <= 32'd0;
                            k1_val <= 3'd0;
                            k2_val <= 3'd1;
                        end
                    end
                end

                S_CALC_0_1: begin
                    acc1 <= acc1 + mult1;
                    acc2 <= acc2 + mult2;
                    n <= n + 1'b1;

                    if (n == 7'd63) begin
                        // (acc + mult) inclui o termo n=63, que "acc" sozinho nao inclui
                        raw_out[0] <= acc1 + mult1;
                        raw_out[1] <= acc2 + mult2;
                        state <= S_CALC_2_3;
                        n <= 7'd0;
                        acc1 <= 32'd0;
                        acc2 <= 32'd0;
                        k1_val <= 3'd2;
                        k2_val <= 3'd3;
                    end
                end

                S_CALC_2_3: begin
                    acc1 <= acc1 + mult1;
                    acc2 <= acc2 + mult2;
                    n <= n + 1'b1;

                    if (n == 7'd63) begin
                        raw_out[2] <= acc1 + mult1;
                        raw_out[3] <= acc2 + mult2;
                        state <= S_CALC_4;
                        n <= 7'd0;
                        acc1 <= 32'd0;
                        k1_val <= 3'd4;
                        k2_val <= 3'd0; // Dummy
                    end
                end

                S_CALC_4: begin
                    acc1 <= acc1 + mult1;
                    n <= n + 1'b1;

                    if (n == 7'd63) begin
                        raw_out[4] <= acc1 + mult1;
                        state <= S_NORM_START;
                        norm_k <= 3'd0;
                    end
                end

                // -------------------------------------------------------
                // Normalizacao: para k = 0..4, r_out[k] = raw_out[k]/raw_out[0]
                // -------------------------------------------------------
                S_NORM_START: begin
                    div_numerator   <= raw_out[norm_k] <<< FRAC;
                    div_denominator <= raw_out[0];
                    div_start       <= 1'b1;
                    state           <= S_NORM_WAIT;
                end

                S_NORM_WAIT: begin
                    if (div_done) begin
                        // se raw_out[0]==0 (janela toda zero), div_by_zero=1
                        // e o divisor ja devolve quotient=0; aceitamos isso
                        // como resultado (nao ha correlacao definida mesmo).
                        r_out[norm_k] <= div_quotient[WIDTH-1:0];
                        state <= S_NORM_NEXT;
                    end
                end

                S_NORM_NEXT: begin
                    if (norm_k == 3'd4) begin
                        state <= S_SEND_OUT;
                        send_count <= 3'd0;
                    end else begin
                        norm_k <= norm_k + 1'b1;
                        state  <= S_NORM_START;
                    end
                end

                S_SEND_OUT: begin
                    r_valid <= 1'b1;
                    r_index <= send_count;
                    r_data <= r_out[send_count];
                    send_count <= send_count + 1'b1;

                    if (send_count == 3'd4) begin
                        state <= S_IDLE;
                        busy <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
