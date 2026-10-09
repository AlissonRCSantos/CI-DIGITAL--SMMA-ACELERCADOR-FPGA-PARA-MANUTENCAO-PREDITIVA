// ============================================================================
// Module: Feature_Collector
// Description: Monta o VETOR DE CARACTERISTICAS do classificador de Machine
//              Learning (enunciado 3.5) a partir das quatro etapas de
//              extracao, e o entrega a arvore em ordem fixa.
//
// ----------------------------------------------------------------------------
// O VETOR (16 posicoes, Q1.15 salvo indicacao)
// ----------------------------------------------------------------------------
//   idx  origem                      conteudo
//   0-7  FFT (Feature_Spectral)      r_1x r_2x r_3x r_banda1..3 log2E centroide
//   8    LMS (LMS_Residual_Feature)  r_lms
//   9-11 estimacao matricial         rho1 rho2 rho3   (autocorrelacao_yw)
//   12   MDC (f0_estimator)          f0 em Hz (inteiro); 0 se o MDC falhou
//   13-15 estimacao matricial        a1/2 a2/2 a3/2   (Yule_Walker_Solver +
//                                                      gauss_jordan_inv)
//
//   As posicoes 0..11 sao exatamente as 12 caracteristicas com que a arvore
//   em vetores/arvore.hex foi treinada. As posicoes 12..15 levam ao
//   classificador o resultado do MDC (como pede o 3.1: "a frequencia
//   fundamental estimada devera ser encaminhada ao classificador") e o da
//   inversao de matriz (3.5: "caracteristicas ... da etapa de estimacao
//   matricial"). A ROM da arvore atual nao possui nos que as consultem --
//   ela continua decidindo sobre 0..11, e por isso a classificacao em placa
//   e identica a do modelo. Retreinar a arvore com as 16 entradas passa a
//   ser apenas uma questao de gerar outra ROM (nenhum fio muda).
//
// ----------------------------------------------------------------------------
// PROTOCOLO
// ----------------------------------------------------------------------------
//   Cada origem tem seu proprio handshake e termina em momentos diferentes
//   (o MDC e o LMS acabam muito antes da inversao). O coletor aceita cada
//   palavra uma unica vez, em qualquer ordem entre origens, e so comeca a
//   entregar quando as 16 posicoes estao preenchidas. Assim a arvore SEMPRE
//   recebe um vetor coerente, de uma unica janela.
//
//   rho chega pelo protocolo do autocorrelacao_yw (r_valid/r_index, sem
//   ready): por isso o coletor o captura em qualquer estado apos o start.
// ============================================================================

`timescale 1ns / 1ps

module Feature_Collector #(
    parameter WIDTH = 16
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- FFT: 8 features espectrais ----
    input  wire                     esp_valid,
    output wire                     esp_ready,
    input  wire signed [WIDTH-1:0]  esp_data,

    // ---- LMS: r_lms ----
    input  wire                     lms_valid,
    output wire                     lms_ready,
    input  wire signed [WIDTH-1:0]  lms_data,

    // ---- Autocorrelacao: rho[0..3] (usa 1..3) ----
    input  wire                     r_valid,
    input  wire [2:0]               r_index,
    input  wire signed [WIDTH-1:0]  r_data,

    // ---- MDC / frequencia fundamental ----
    input  wire                     f0_valid,
    output wire                     f0_ready,
    input  wire signed [WIDTH-1:0]  f0_data,

    // ---- Inversao de matriz: a1/2..a3/2 ----
    input  wire                     ar_valid,
    output wire                     ar_ready,
    input  wire signed [WIDTH-1:0]  ar_data,

    // ---- Saida para o classificador ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_feature
);

    localparam N_FEAT = 16;
    localparam I_LMS  = 8,  I_RHO = 9,  I_F0 = 12, I_AR = 13;

    reg signed [WIDTH-1:0] feat [0:N_FEAT-1];
    reg [N_FEAT-1:0]       cheio;          // posicao ja preenchida
    reg [2:0]              esp_cnt;
    reg [1:0]              ar_cnt;
    reg [3:0]              oi;

    localparam [1:0] S_IDLE = 2'd0, S_COLETA = 2'd1, S_OUT = 2'd2;
    reg [1:0] state;

    wire coletando = (state == S_COLETA);

    assign ready       = (state == S_IDLE);
    assign esp_ready   = coletando && !(&cheio[7:0]);
    assign lms_ready   = coletando && !cheio[I_LMS];
    assign f0_ready    = coletando && !cheio[I_F0];
    assign ar_ready    = coletando && !(&cheio[I_AR+2:I_AR]);
    assign out_valid   = (state == S_OUT);
    assign out_feature = feat[oi];

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            cheio   <= {N_FEAT{1'b0}};
            esp_cnt <= 3'd0;
            ar_cnt  <= 2'd0;
            oi      <= 4'd0;
            for (k = 0; k < N_FEAT; k = k + 1) feat[k] <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cheio   <= {N_FEAT{1'b0}};
                        esp_cnt <= 3'd0;
                        ar_cnt  <= 2'd0;
                        busy    <= 1'b1;
                        state   <= S_COLETA;
                    end
                end

                S_COLETA: begin
                    if (esp_valid && esp_ready) begin
                        feat[esp_cnt]  <= esp_data;
                        cheio[esp_cnt] <= 1'b1;
                        esp_cnt        <= esp_cnt + 1'b1;
                    end
                    if (lms_valid && lms_ready) begin
                        feat[I_LMS]  <= lms_data;
                        cheio[I_LMS] <= 1'b1;
                    end
                    if (r_valid && (r_index >= 3'd1) && (r_index <= 3'd3)) begin
                        feat[I_RHO + r_index - 1]  <= r_data;
                        cheio[I_RHO + r_index - 1] <= 1'b1;
                    end
                    if (f0_valid && f0_ready) begin
                        feat[I_F0]  <= f0_data;
                        cheio[I_F0] <= 1'b1;
                    end
                    if (ar_valid && ar_ready) begin
                        feat[I_AR + ar_cnt]  <= ar_data;
                        cheio[I_AR + ar_cnt] <= 1'b1;
                        ar_cnt               <= ar_cnt + 1'b1;
                    end
                    if (&cheio) begin
                        oi    <= 4'd0;
                        state <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (out_ready) begin
                        if (oi == N_FEAT - 1) begin
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
