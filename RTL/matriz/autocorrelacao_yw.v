// ============================================================================
// autocorrelacao_yw -- COEFFICIENT ACC.: autocorrelacao rho[0..3] da janela
// ============================================================================

`timescale 1ns/1ps
module autocorrelacao_yw #(
    parameter WIDTH      = 16,     // Q1.15
    parameter FRAC       = 15,
    parameter N_AMOSTRAS = 1056,   // amostras por janela
    parameter N_LAGS     = 3,      // lags 1..N_LAGS (alem de r[0])
    parameter ACC_W      = 48      // 1056 x 2^30 cabe em 41 bits
)(
    input wire clk,
    input wire reset,

    // Controle
    input  wire start,             // pulso: inicia uma janela
    output wire ready,             // pronto para nova janela
    output reg  busy,

    // Entrada de amostras (handshake valid/ready)
    input  wire                    lms_valid,
    output wire                    lms_ready,
    input  wire signed [WIDTH-1:0] lms_data,

    // Saida: rho[0..N_LAGS], um por ciclo
    output reg                     r_valid,
    output reg  [2:0]              r_index,
    output reg  signed [WIDTH-1:0] r_data
);

    // Estados da FSM
    localparam S_IDLE       = 4'd0;
    localparam S_FILL       = 4'd1;   // espera a proxima amostra
    localparam S_CALC       = 4'd2;   // um par de lags por ciclo
    localparam S_NORM_START = 4'd5;   // dispara r[k]/r[0]
    localparam S_NORM_WAIT  = 4'd6;
    localparam S_NORM_NEXT  = 4'd7;
    localparam S_SEND_OUT   = 4'd8;

    localparam signed [WIDTH-1:0] SAT_MAX = (1 << (WIDTH-1)) - 1;

    reg [3:0] state;

    // x[n] corrente e historico x[n-1..n-N_LAGS] (zerado no inicio da
    // janela: os lags ainda sem amostra contribuem com produto nulo)
    reg signed [WIDTH-1:0] x_n;
    reg signed [WIDTH-1:0] hist [0:N_LAGS-1];
    reg [11:0]             sample_count;

    // Acumuladores das somas brutas r[0..N_LAGS]
    reg signed [ACC_W-1:0] raw_out [0:N_LAGS];

    // Resultado normalizado
    reg signed [WIDTH-1:0] r_out [0:N_LAGS];
    reg [2:0] norm_k;
    reg [2:0] send_count;

    // 2 multiplicadores combinacionais reaproveitados: k1 = 2p, k2 = 2p+1
    reg [2:0] k1_val, k2_val;

    wire signed [WIDTH-1:0] val_k1 = (k1_val == 3'd0) ? x_n : hist[k1_val - 1'b1];
    wire signed [WIDTH-1:0] val_k2 = (k2_val > N_LAGS) ? {WIDTH{1'b0}}
                                   : (k2_val == 3'd0) ? x_n : hist[k2_val - 1'b1];

    wire signed [2*WIDTH-1:0] mult1 = x_n * val_k1;
    wire signed [2*WIDTH-1:0] mult2 = x_n * val_k2;

    // Normalizacao: fixed_point_divider da branch, com WIDTH = ACC_W
    reg                        div_start;
    reg  signed [2*ACC_W-1:0]  div_numerator;
    reg  signed [ACC_W-1:0]    div_denominator;
    wire signed [ACC_W-1:0]    div_quotient;
    wire                       div_done;
    wire                       div_by_zero;

    fixed_point_divider #(
        .WIDTH(ACC_W),
        .FRAC (FRAC)
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

    // |quociente| saturado em Q1.15, sinal reaplicado
    wire                     q_neg = div_quotient[ACC_W-1];
    wire [ACC_W-1:0]         q_abs = q_neg ? (~div_quotient + 1'b1) : div_quotient;
    wire signed [WIDTH-1:0]  q_mag = (q_abs > SAT_MAX) ? SAT_MAX : q_abs[WIDTH-1:0];
    wire signed [WIDTH-1:0]  q_sat = q_neg ? -q_mag : q_mag;

    assign ready     = (state == S_IDLE);
    assign lms_ready = (state == S_FILL);

    integer i;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            r_valid      <= 1'b0;
            r_index      <= 3'd0;
            r_data       <= {WIDTH{1'b0}};
            sample_count <= 12'd0;
            div_start    <= 1'b0;
            norm_k       <= 3'd0;
            send_count   <= 3'd0;
            k1_val       <= 3'd0;
            k2_val       <= 3'd1;
            x_n          <= {WIDTH{1'b0}};
            div_numerator   <= {(2*ACC_W){1'b0}};
            div_denominator <= {ACC_W{1'b0}};
            for (i = 0; i < N_LAGS; i = i + 1)  hist[i]    <= {WIDTH{1'b0}};
            for (i = 0; i <= N_LAGS; i = i + 1) begin
                raw_out[i] <= {ACC_W{1'b0}};
                r_out[i]   <= {WIDTH{1'b0}};
            end
        end else begin
            r_valid   <= 1'b0;
            div_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        sample_count <= 12'd0;
                        for (i = 0; i < N_LAGS; i = i + 1)  hist[i]    <= {WIDTH{1'b0}};
                        for (i = 0; i <= N_LAGS; i = i + 1) raw_out[i] <= {ACC_W{1'b0}};
                        state <= S_FILL;
                    end
                end

                S_FILL: begin
                    if (lms_valid && lms_ready) begin
                        x_n    <= lms_data;
                        k1_val <= 3'd0;
                        k2_val <= 3'd1;
                        state  <= S_CALC;
                    end
                end

                S_CALC: begin
                    raw_out[k1_val] <= raw_out[k1_val] + mult1;
                    if (k2_val <= N_LAGS)
                        raw_out[k2_val] <= raw_out[k2_val] + mult2;

                    if (k2_val < N_LAGS) begin
                        k1_val <= k1_val + 3'd2;      // proximo par
                        k2_val <= k2_val + 3'd2;
                    end else begin
                        // desloca o historico e conta a amostra
                        for (i = N_LAGS - 1; i > 0; i = i - 1)
                            hist[i] <= hist[i-1];
                        hist[0]      <= x_n;
                        sample_count <= sample_count + 1'b1;

                        if (sample_count == N_AMOSTRAS - 1) begin
                            norm_k <= 3'd0;
                            state  <= S_NORM_START;
                        end else begin
                            state  <= S_FILL;
                        end
                    end
                end

                // Normalizacao: rho[k] = r[k] / r[0], k = 0..N_LAGS
                S_NORM_START: begin
                    div_numerator   <= {{ACC_W{raw_out[norm_k][ACC_W-1]}}, raw_out[norm_k]} <<< FRAC;
                    div_denominator <= raw_out[0];
                    div_start       <= 1'b1;
                    state           <= S_NORM_WAIT;
                end

                S_NORM_WAIT: begin
                    if (div_done) begin
                        // r[0] == 0 (janela toda nula): o divisor sinaliza
                        // div_by_zero e devolve 0 -- sem correlacao definida.
                        r_out[norm_k] <= div_by_zero ? {WIDTH{1'b0}} : q_sat;
                        state <= S_NORM_NEXT;
                    end
                end

                S_NORM_NEXT: begin
                    if (norm_k == N_LAGS) begin
                        send_count <= 3'd0;
                        state      <= S_SEND_OUT;
                    end else begin
                        norm_k <= norm_k + 1'b1;
                        state  <= S_NORM_START;
                    end
                end

                S_SEND_OUT: begin
                    r_valid    <= 1'b1;
                    r_index    <= send_count;
                    r_data     <= r_out[send_count];
                    send_count <= send_count + 1'b1;
                    if (send_count == N_LAGS) begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
