// ============================================================================
// FFT_Butterfly -- butterfly radix-2 DIT pipelinado, escala 1/2 por estagio
// ============================================================================

`timescale 1ns / 1ps

module FFT_Butterfly #(
    parameter WIDTH = 16,   // Largura da palavra (Q1.15)
    parameter FRAC  = 15    // Bits fracionarios
)(
    input  wire                     clk,        // Clock do sistema (50 MHz)
    input  wire                     rst,        // Reset sincrono ativo em alto

    input  wire                     in_valid,   // Operandos validos neste ciclo
    input  wire                     scale_en,   // 1: aplica escala de 1/2 neste butterfly
    input  wire signed [WIDTH-1:0]  a_real,     // A (operando superior) - real
    input  wire signed [WIDTH-1:0]  a_imag,     // A - imaginario
    input  wire signed [WIDTH-1:0]  b_real,     // B (operando inferior) - real
    input  wire signed [WIDTH-1:0]  b_imag,     // B - imaginario
    input  wire signed [WIDTH-1:0]  w_real,     // Fator de rotacao - real
    input  wire signed [WIDTH-1:0]  w_imag,     // Fator de rotacao - imaginario

    output wire                     out_valid,  // Resultados validos (6 ciclos depois)
    output reg  signed [WIDTH-1:0]  p_real,     // P = (A + W*B)*k - real   (k = 1/2 ou 1)
    output reg  signed [WIDTH-1:0]  p_imag,     // P - imaginario
    output reg  signed [WIDTH-1:0]  q_real,     // Q = (A - W*B)*k - real
    output reg  signed [WIDTH-1:0]  q_imag      // Q - imaginario
);

    localparam LATENCY = 6;            // Latencia do pipeline, em ciclos
    localparam W_T     = WIDTH + 1;    // 17 bits: t = W*B  (Q2.15)
    localparam W_S     = WIDTH + 2;    // 18 bits: A +/- t  (Q3.15)

    // Limites de saturacao no dominio estendido de 18 bits
    localparam signed [W_S-1:0] OUT_MAX =  (1 << (WIDTH-1)) - 1;  // +32767
    localparam signed [W_S-1:0] OUT_MIN = -(1 << (WIDTH-1));      // -32768

    // ESTAGIOS 1-3: MULTIPLICACAO COMPLEXA (4 DSPs em paralelo)
    wire signed [WIDTH-1:0] m_rr;  // B_real * W_real
    wire signed [WIDTH-1:0] m_ii;  // B_imag * W_imag
    wire signed [WIDTH-1:0] m_ri;  // B_real * W_imag
    wire signed [WIDTH-1:0] m_ir;  // B_imag * W_real

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_rr (
        .clk(clk), .rst(rst), .in_A(b_real), .in_B(w_real), .out_Y(m_rr)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ii (
        .clk(clk), .rst(rst), .in_A(b_imag), .in_B(w_imag), .out_Y(m_ii)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ri (
        .clk(clk), .rst(rst), .in_A(b_real), .in_B(w_imag), .out_Y(m_ri)
    );

    FP_Mult_Unit #(
        .WIDTH_A(WIDTH), .FRAC_A(FRAC),
        .WIDTH_B(WIDTH), .FRAC_B(FRAC),
        .WIDTH_Y(WIDTH), .FRAC_Y(FRAC),
        .ROUNDING(1)
    ) u_mult_ir (
        .clk(clk), .rst(rst), .in_A(b_imag), .in_B(w_real), .out_Y(m_ir)
    );

    // Linha de atraso do operando A: 3 ciclos para alinhar com os produtos
    reg signed [WIDTH-1:0] a_r_d1, a_r_d2, a_r_d3;
    reg signed [WIDTH-1:0] a_i_d1, a_i_d2, a_i_d3;

    always @(posedge clk) begin
        if (rst) begin
            a_r_d1 <= {WIDTH{1'b0}}; a_r_d2 <= {WIDTH{1'b0}}; a_r_d3 <= {WIDTH{1'b0}};
            a_i_d1 <= {WIDTH{1'b0}}; a_i_d2 <= {WIDTH{1'b0}}; a_i_d3 <= {WIDTH{1'b0}};
        end else begin
            a_r_d1 <= a_real;  a_r_d2 <= a_r_d1;  a_r_d3 <= a_r_d2;
            a_i_d1 <= a_imag;  a_i_d2 <= a_i_d1;  a_i_d3 <= a_i_d2;
        end
    end

    // ESTAGIO 4: COMBINACAO COMPLEXA  t = W*B   (Q2.15, 17 bits)
    reg signed [W_T-1:0]   t_real, t_imag;
    reg signed [WIDTH-1:0] a_r_d4, a_i_d4;

    always @(posedge clk) begin
        if (rst) begin
            t_real <= {W_T{1'b0}};
            t_imag <= {W_T{1'b0}};
            a_r_d4 <= {WIDTH{1'b0}};
            a_i_d4 <= {WIDTH{1'b0}};
        end else begin
            // Extensao de sinal implicita para 17 bits antes da soma/subtracao
            t_real <= {m_rr[WIDTH-1], m_rr} - {m_ii[WIDTH-1], m_ii};
            t_imag <= {m_ri[WIDTH-1], m_ri} + {m_ir[WIDTH-1], m_ir};
            a_r_d4 <= a_r_d3;
            a_i_d4 <= a_i_d3;
        end
    end

    // ESTAGIO 5: SOMAS E SUBTRACOES DO BUTTERFLY  (Q3.15, 18 bits)
    wire signed [W_S-1:0] a_r_ext = {{2{a_r_d4[WIDTH-1]}}, a_r_d4};
    wire signed [W_S-1:0] a_i_ext = {{2{a_i_d4[WIDTH-1]}}, a_i_d4};
    wire signed [W_S-1:0] t_r_ext = {t_real[W_T-1], t_real};
    wire signed [W_S-1:0] t_i_ext = {t_imag[W_T-1], t_imag};

    reg signed [W_S-1:0] sum_r, sum_i, dif_r, dif_i;

    always @(posedge clk) begin
        if (rst) begin
            sum_r <= {W_S{1'b0}};  sum_i <= {W_S{1'b0}};
            dif_r <= {W_S{1'b0}};  dif_i <= {W_S{1'b0}};
        end else begin
            sum_r <= a_r_ext + t_r_ext;   // A + t
            sum_i <= a_i_ext + t_i_ext;
            dif_r <= a_r_ext - t_r_ext;   // A - t
            dif_i <= a_i_ext - t_i_ext;
        end
    end

    // ESTAGIO 6: ESCALA CONDICIONAL 1/2 + ARREDONDAMENTO + SATURACAO -> Q1.15
    localparam signed [W_S-1:0] ROUND_HALF = {{(W_S-1){1'b0}}, 1'b1};

    // Atraso de 'scale_en' ate o estagio em que a escala e efetivamente
    // aplicada (5 registradores: 3 do multiplicador + estagio 4 + estagio 5).
    reg [LATENCY-2:0] scale_pipe;
    always @(posedge clk) begin
        if (rst)
            scale_pipe <= {(LATENCY-1){1'b0}};
        else
            scale_pipe <= {scale_pipe[LATENCY-3:0], scale_en};
    end
    wire scale_now = scale_pipe[LATENCY-2];

    function signed [WIDTH-1:0] scale_round_sat;
        input signed [W_S-1:0] value;
        input                  do_scale;
        reg   signed [W_S-1:0] scaled;
        begin
            scaled = do_scale ? ((value + ROUND_HALF) >>> 1) : value;
            if (scaled > OUT_MAX)
                scale_round_sat = OUT_MAX[WIDTH-1:0];
            else if (scaled < OUT_MIN)
                scale_round_sat = OUT_MIN[WIDTH-1:0];
            else
                scale_round_sat = scaled[WIDTH-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            p_real <= {WIDTH{1'b0}};  p_imag <= {WIDTH{1'b0}};
            q_real <= {WIDTH{1'b0}};  q_imag <= {WIDTH{1'b0}};
        end else begin
            p_real <= scale_round_sat(sum_r, scale_now);
            p_imag <= scale_round_sat(sum_i, scale_now);
            q_real <= scale_round_sat(dif_r, scale_now);
            q_imag <= scale_round_sat(dif_i, scale_now);
        end
    end

    // PIPELINE DE VALIDADE (acompanha os dados ao longo dos 6 estagios)
    reg [LATENCY-1:0] valid_pipe;

    always @(posedge clk) begin
        if (rst)
            valid_pipe <= {LATENCY{1'b0}};
        else
            valid_pipe <= {valid_pipe[LATENCY-2:0], in_valid};
    end

    assign out_valid = valid_pipe[LATENCY-1];

endmodule
