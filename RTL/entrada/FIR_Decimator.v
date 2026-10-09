// ============================================================================
// FIR_Decimator -- FIR anti-alias de 63 taps + decimacao por 8 (25,6 -> 3,2 kHz)
// ============================================================================

`timescale 1ns / 1ps

module FIR_Decimator #(
    parameter WIDTH    = 16,                  // Q1.15
    parameter FRAC     = 15,
    parameter N_TAPS   = 63,
    parameter DECIM    = 8,
    parameter ACC_W    = 40,
    parameter ARQ_COEF = "vetores/fir_coef.hex"
)(
    input  wire                     clk,        // Clock do sistema (50 MHz)
    input  wire                     rst,        // Reset sincrono ativo em alto
    input  wire                     limpa,      // Pulso: zera a linha e a fase

    // ---- Entrada: amostras do acelerometro a 25,6 kHz ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,  // Q1.15 (fundo de escala +-32 g)

    // ---- Saida: sinal decimado a 3,2 kHz ----
    input  wire                     out_ready,
    output reg                      out_valid,
    output reg  signed [WIDTH-1:0]  out_sample  // Q1.15

    , output wire                   overflow    // 1 = uma saida saturou
);

    localparam signed [ACC_W-1:0] SAT_MAX =  (1 << (WIDTH-1)) - 1;   // +32767
    localparam signed [ACC_W-1:0] SAT_MIN = -(1 << (WIDTH-1));       // -32768
    localparam CNT_W = 7;                                            // ate 63
    localparam [3:0] FASE_DISPARO = (N_TAPS - 1) % DECIM;

    // ROM de coeficientes e linha de atraso
    reg signed [WIDTH-1:0] coef [0:N_TAPS-1];
    initial $readmemh(ARQ_COEF, coef);

    reg signed [WIDTH-1:0] linha [0:N_TAPS-1];   // linha[0] = amostra mais nova

    // Controle
    reg [CNT_W-1:0]        tap;          // indice do tap no MAC
    reg [3:0]              fase;         // conta amostras para a decimacao
    reg [CNT_W-1:0]        preench;      // amostras ja recebidas (satura)
    reg signed [ACC_W-1:0] acc;
    reg                    calculando;
    reg                    sat_flag;

    assign overflow = sat_flag;
    // Aceita nova amostra enquanto nao estiver no meio de um MAC e a saida
    // anterior ja tiver sido consumida -- e o que impede sobrescrita.
    assign in_ready = !calculando && !(out_valid && !out_ready);

    wire cheia      = (preench >= N_TAPS - 1);
    wire aceita     = in_valid && in_ready;
    // A convolucao 'valid' do modelo Python produz saida quando a linha esta
    // cheia; a partir dai, uma a cada DECIM amostras.
    wire dispara    = aceita && cheia && (fase == FASE_DISPARO);

    wire signed [ACC_W-1:0] prod = linha[tap] * coef[tap];

    wire signed [ACC_W-1:0] acc_next  = acc + prod;
    wire signed [ACC_W-1:0] acc_round = acc_next + (1 << (FRAC - 1));
    wire signed [ACC_W-1:0] acc_shift = acc_round >>> FRAC;

    integer i;

    // 'limpa' faz o mesmo que o reset, e e OBRIGATORIO entre janelas.
    always @(posedge clk) begin
        if (rst || limpa) begin
            tap        <= {CNT_W{1'b0}};
            fase       <= 4'd0;
            preench    <= {CNT_W{1'b0}};
            acc        <= {ACC_W{1'b0}};
            calculando <= 1'b0;
            out_valid  <= 1'b0;
            out_sample <= {WIDTH{1'b0}};
            sat_flag   <= 1'b0;
            for (i = 0; i < N_TAPS; i = i + 1)
                linha[i] <= {WIDTH{1'b0}};
        end else begin
            // saida consumida
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (!calculando) begin
                if (aceita) begin
                    // desloca a linha de atraso e insere a nova amostra
                    for (i = N_TAPS - 1; i > 0; i = i - 1)
                        linha[i] <= linha[i-1];
                    linha[0] <= in_sample;

                    if (!cheia)
                        preench <= preench + 1'b1;

                    fase <= (fase == DECIM - 1) ? 4'd0 : (fase + 1'b1);

                    if (dispara) begin
                        // inicia o MAC: tap 0 ja usa a amostra recem-inserida,
                        // por isso o produto do tap 0 e feito aqui.
                        acc        <= $signed(in_sample) * coef[0];
                        tap        <= 7'd1;
                        calculando <= 1'b1;
                    end
                end
            end else begin
                // um tap por ciclo
                acc <= acc + prod;
                if (tap == N_TAPS - 1) begin
                    calculando <= 1'b0;
                    // arredonda, satura e publica
                    if (acc_shift > SAT_MAX) begin
                        out_sample <= SAT_MAX[WIDTH-1:0];
                        sat_flag   <= 1'b1;
                    end else if (acc_shift < SAT_MIN) begin
                        out_sample <= SAT_MIN[WIDTH-1:0];
                        sat_flag   <= 1'b1;
                    end else begin
                        out_sample <= acc_shift[WIDTH-1:0];
                    end
                    out_valid <= 1'b1;
                end else begin
                    tap <= tap + 1'b1;
                end
            end
        end
    end

endmodule
