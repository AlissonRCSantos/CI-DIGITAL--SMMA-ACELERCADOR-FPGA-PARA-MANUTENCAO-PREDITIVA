// ============================================================================
// Yule_Walker_Solver -- GAUSS_JORDAN: monta a Toeplitz, inverte e calcula a1..a3 (enunciado 3.3)
// ============================================================================

`timescale 1ns / 1ps

module Yule_Walker_Solver #(
    parameter WIDTH = 16,          // Q1.15 (entrada rho e saida a/2)
    parameter W_INV = 24,          // largura de dado do gauss_jordan_inv
    parameter F_INV = 16,          // bits fracionarios do gauss_jordan_inv
    parameter ORDEM = 3            // ordem AR (n da matriz, <= 4)
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- Entrada: autocorrelacao normalizada (protocolo do autocorrelacao_yw)
    input  wire                     r_valid,
    input  wire [2:0]               r_index,
    input  wire signed [WIDTH-1:0]  r_data,

    // ---- Interface com o gauss_jordan_inv ----
    output wire                     inv_valid_in,
    input  wire                     inv_ready,
    output wire [1:0]               inv_load_row,
    output wire [1:0]               inv_load_col,
    output wire signed [W_INV-1:0]  inv_load_data,
    output wire                     inv_start,
    output wire [2:0]               inv_n,
    input  wire                     inv_valid_out,
    input  wire                     inv_singular,
    output wire [1:0]               inv_read_row,
    output wire [2:0]               inv_read_col,
    input  wire signed [W_INV-1:0]  inv_read_data,

    // ---- Saida: a1/2 .. aORDEM/2 em Q1.15 ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_feature,
    output reg                      singular       // ultima matriz foi singular
);

    localparam signed [W_INV-1:0] UM = {{(W_INV-1){1'b0}}, 1'b1} << F_INV;
    localparam ACC_W = 48;
    localparam signed [ACC_W-1:0] A_MAX =  (1 <<< (WIDTH-1)) - 1;   //  32767
    localparam signed [ACC_W-1:0] A_MIN = -(1 <<< (WIDTH-1));       // -32768
    localparam signed [ACC_W-1:0] MEIO  =  (1 <<< F_INV);           // 0,5 LSB de saida

    // Registradores
    reg signed [WIDTH-1:0] rho  [1:ORDEM];
    reg signed [WIDTH-1:0] a_q  [0:ORDEM-1];
    reg [1:0]              i, j;
    reg [1:0]              oi;                      // indice de saida
    reg signed [W_INV-1:0] rinv_reg;
    reg signed [WIDTH-1:0] rho_reg;
    reg signed [ACC_W-1:0] acc;

    localparam [3:0] S_IDLE  = 4'd0,
                     S_RHO   = 4'd1,
                     S_LOAD  = 4'd2,
                     S_START = 4'd3,
                     S_WAIT  = 4'd4,
                     S_RD    = 4'd5,
                     S_MAC   = 4'd6,
                     S_OUT   = 4'd7;
    reg [3:0] state;

    // Elemento R[i][j] da Toeplitz, no formato do inversor
    wire [1:0] dist_ij = (i > j) ? (i - j) : (j - i);
    wire signed [WIDTH-1:0] rho_dist = rho[dist_ij == 2'd0 ? 1 : dist_ij];
    // Q1.15 -> Q(W_INV-F_INV-1).F_INV : extensao de sinal + deslocamento
    wire signed [W_INV-1:0] rho_inv = $signed({{(W_INV-WIDTH){rho_dist[WIDTH-1]}}, rho_dist})
                                      <<< (F_INV - (WIDTH-1));

    assign inv_valid_in  = (state == S_LOAD);
    assign inv_load_row  = i;
    assign inv_load_col  = j;
    assign inv_load_data = (dist_ij == 2'd0) ? UM : rho_inv;
    assign inv_start     = (state == S_START);
    assign inv_n         = ORDEM;
    assign inv_read_row  = i;
    assign inv_read_col  = ORDEM + j;          // R^-1 ocupa as colunas n..2n-1

    // MAC: Rinv (Q.F_INV) x rho (Q1.15)
    wire signed [W_INV+WIDTH-1:0] prod = rinv_reg * rho_reg;
    wire signed [ACC_W-1:0]       acc_prox = acc + {{(ACC_W-W_INV-WIDTH){prod[W_INV+WIDTH-1]}}, prod};

    // a/2 em Q1.15 = round(acc / 2^(F_INV+1)), saturado
    wire signed [ACC_W-1:0] a_rnd = (acc_prox + MEIO) >>> (F_INV + 1);
    wire signed [WIDTH-1:0] a_sat = (a_rnd > A_MAX) ? A_MAX[WIDTH-1:0] :
                                    (a_rnd < A_MIN) ? A_MIN[WIDTH-1:0] :
                                                      a_rnd[WIDTH-1:0];

    assign ready       = (state == S_IDLE);
    assign out_valid   = (state == S_OUT);
    assign out_feature = a_q[oi];

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            singular <= 1'b0;
            i <= 2'd0; j <= 2'd0; oi <= 2'd0;
            acc      <= {ACC_W{1'b0}};
            rinv_reg <= {W_INV{1'b0}};
            rho_reg  <= {WIDTH{1'b0}};
            for (k = 1; k <= ORDEM; k = k + 1) rho[k]   <= {WIDTH{1'b0}};
            for (k = 0; k <  ORDEM; k = k + 1) a_q[k]   <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy  <= 1'b1;
                        state <= S_RHO;
                    end
                end

                // ---- captura rho[1..ORDEM]; rho[0] = 1 por definicao ----
                S_RHO: begin
                    if (r_valid && (r_index != 3'd0) && (r_index <= ORDEM)) begin
                        rho[r_index] <= r_data;
                        if (r_index == ORDEM) begin
                            i <= 2'd0; j <= 2'd0;
                            state <= S_LOAD;
                        end
                    end
                end

                // ---- carrega R, linha a linha ----
                S_LOAD: begin
                    if (inv_ready) begin
                        if (j == ORDEM - 1) begin
                            j <= 2'd0;
                            if (i == ORDEM - 1) begin
                                i     <= 2'd0;
                                state <= S_START;
                            end else begin
                                i <= i + 1'b1;
                            end
                        end else begin
                            j <= j + 1'b1;
                        end
                    end
                end

                S_START: state <= S_WAIT;

                S_WAIT: begin
                    if (inv_valid_out) begin
                        singular <= inv_singular;
                        i <= 2'd0; j <= 2'd0;
                        acc <= {ACC_W{1'b0}};
                        if (inv_singular) begin
                            for (k = 0; k < ORDEM; k = k + 1) a_q[k] <= {WIDTH{1'b0}};
                            oi    <= 2'd0;
                            state <= S_OUT;
                        end else begin
                            state <= S_RD;
                        end
                    end
                end

                // ---- a_i = sum_j Rinv[i][j] * rho[j+1] ----
                S_RD: begin
                    rinv_reg <= inv_read_data;
                    rho_reg  <= rho[j + 1'b1];
                    state    <= S_MAC;
                end

                S_MAC: begin
                    if (j == ORDEM - 1) begin
                        a_q[i] <= a_sat;
                        acc    <= {ACC_W{1'b0}};
                        j      <= 2'd0;
                        if (i == ORDEM - 1) begin
                            oi    <= 2'd0;
                            state <= S_OUT;
                        end else begin
                            i     <= i + 1'b1;
                            state <= S_RD;
                        end
                    end else begin
                        acc   <= acc_prox;
                        j     <= j + 1'b1;
                        state <= S_RD;
                    end
                end

                // ---- entrega a1/2 .. aORDEM/2 ----
                S_OUT: begin
                    if (out_ready) begin
                        if (oi == ORDEM - 1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            oi <= oi + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
