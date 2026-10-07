// ============================================================================
// Module: CNN_Control_FSM
// Description: Unidade de controle GLOBAL do acelerador CNN.
//              Segue o mesmo padrao adotado no LMS_Control_FSM: uma maquina de
//              estados enxuta coordenando um datapath auto-temporizado por
//              sinais 'valid', com interface de handshake industrial completa
//              (start / enable / valid / ready / busy / done).
//
// DIAGRAMA DE ESTADOS
// -------------------
//
//   +--------+  start & enable   +----------+  ultimo push   +---------+
//   |  IDLE  |------------------>|  STREAM  |--------------->|  DRAIN  |
//   +--------+                   +----------+                +---------+
//       ^                         (1089 passos)                   |
//       |                                                         | 256 saidas
//       |                                                         | do pooling
//   +--------+   dense_done      +----------+                     v
//   | FINISH |<------------------|  DENSE   |<--------------------+
//   +--------+                   +----------+     dense_run
//       |
//       +--> volta para IDLE (done + valid_out pulsados)
//
// PAPEL DE CADA ESTADO
// --------------------
//   IDLE   : ready=1. Espera 'start'. Ao sair, pulsa 'frame_start', que zera
//            line buffers, contadores do pooling e acumuladores do GAP.
//   STREAM : avanca a varredura do line buffer. Cada passo so acontece se
//            (a) a convolucao pode aceitar dado (conv_ready) e
//            (b) ha pixel valido, QUANDO o passo consome pixel real.
//            Nos 65 passos de padding nao e preciso pixel (need_pixel=0).
//            => e este AND que impede perda ou sobrescrita de dados.
//   DRAIN  : nao entra mais pixel; espera o pipeline (conv -> ReLU -> pooling)
//            esvaziar e o pooling completar suas 256 saidas.
//   DENSE  : dispara a camada densa (GAP ja esta pronto) e espera 'dense_done'.
//   FINISH : pulsa done/valid_out por 1 ciclo e volta a ficar 'ready'.
//
// CONTAGEM DE CICLOS (por imagem 32x32)
//   STREAM ~ 1024 janelas x 9 ciclos + 65 passos de padding ~= 9.281
//   DRAIN  ~ 15
//   DENSE  ~ 36
//   TOTAL  ~ 9.332 ciclos ~= 187 us @ 50 MHz  (limite do enunciado: 10 ms)
// ============================================================================

`timescale 1ns / 1ps

module CNN_Control_FSM #(
    parameter NUM_POOL = 256   // (IMG_W/2) * (IMG_H/2) saidas do max pooling
)(
    input  wire        clk,
    input  wire        rst,

    // ---- Interface de handshake com o mundo externo ----
    input  wire        start,        // Pulso: inicia o processamento da imagem
    input  wire        enable,       // Habilitacao global (clock-enable)
    input  wire        in_valid,     // Pixel de entrada valido
    output wire        in_ready,     // Aceito consumir um pixel neste ciclo

    output reg         busy,         // Processando
    output reg         ready,        // Pronto para uma nova imagem
    output reg         done,         // Nivel alto ao terminar (ate novo start)
    output reg         valid_out,    // Pulso de 1 ciclo: classificacao valida

    // ---- Sinais vindos do datapath ----
    input  wire        need_pixel,     // O passo atual consome pixel real
    input  wire        last_push,      // Ultimo passo da varredura
    input  wire        conv_ready,     // Convolucao pode aceitar nova janela
    input  wire        pool_out_valid, // Pooling entregou um resultado
    input  wire        dense_done,     // Classificador terminou

    // ---- Sinais de controle para o datapath ----
    output reg         frame_start,  // Pulso: zera line buffer / pooling / GAP
    output wire        push_en,      // Avanca a varredura do line buffer
    output reg         dense_run     // Pulso: dispara a camada densa
);

    // ------------------------------------------------------------------------
    // Codificacao dos estados
    // ------------------------------------------------------------------------
    localparam ST_IDLE   = 3'd0;
    localparam ST_STREAM = 3'd1;
    localparam ST_DRAIN  = 3'd2;
    localparam ST_DENSE  = 3'd3;
    localparam ST_FINISH = 3'd4;

    reg [2:0]  state;
    reg [15:0] pool_cnt;   // conta as saidas do max pooling deste quadro

    // ------------------------------------------------------------------------
    // Logica de fluxo de entrada (combinacional)
    //
    //   push_en  = posso avancar a varredura?
    //   in_ready = vou consumir um pixel do host neste ciclo?
    //
    // Note o AND com conv_ready: se a convolucao ainda esta mastigando os 9
    // taps da janela anterior, a varredura CONGELA e o host segura o pixel.
    // Nenhum dado e perdido nem sobrescrito.
    // ------------------------------------------------------------------------
    assign push_en  = enable && (state == ST_STREAM) && conv_ready &&
                      (need_pixel ? in_valid : 1'b1);

    assign in_ready = enable && (state == ST_STREAM) && conv_ready && need_pixel;

    // ------------------------------------------------------------------------
    // Maquina de estados
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= ST_IDLE;
            pool_cnt    <= 16'd0;
            busy        <= 1'b0;
            ready       <= 1'b1;
            done        <= 1'b0;
            valid_out   <= 1'b0;
            frame_start <= 1'b0;
            dense_run   <= 1'b0;
        end else if (enable) begin
            // Pulsos de 1 ciclo voltam a zero por padrao
            frame_start <= 1'b0;
            dense_run   <= 1'b0;
            valid_out   <= 1'b0;

            // Contador de saidas do pooling (ativo do STREAM ao DRAIN)
            if ((state == ST_STREAM || state == ST_DRAIN) && pool_out_valid)
                pool_cnt <= pool_cnt + 16'd1;

            case (state)
                // ------------------------------------------------------------
                ST_IDLE: begin
                    busy  <= 1'b0;
                    ready <= 1'b1;
                    if (start) begin
                        state       <= ST_STREAM;
                        frame_start <= 1'b1;   // limpa todo o datapath
                        pool_cnt    <= 16'd0;
                        busy        <= 1'b1;
                        ready       <= 1'b0;
                        done        <= 1'b0;
                    end
                end

                // ------------------------------------------------------------
                ST_STREAM: begin
                    // A varredura terminou quando o ultimo passo foi efetivado
                    if (push_en && last_push)
                        state <= ST_DRAIN;
                end

                // ------------------------------------------------------------
                ST_DRAIN: begin
                    // Espera o pipeline esvaziar e o pooling fechar as 256 saidas
                    if (pool_cnt == NUM_POOL) begin
                        state     <= ST_DENSE;
                        dense_run <= 1'b1;     // dispara GAP -> densa -> argmax
                    end
                end

                // ------------------------------------------------------------
                ST_DENSE: begin
                    if (dense_done)
                        state <= ST_FINISH;
                end

                // ------------------------------------------------------------
                ST_FINISH: begin
                    state     <= ST_IDLE;
                    busy      <= 1'b0;
                    ready     <= 1'b1;
                    done      <= 1'b1;
                    valid_out <= 1'b1;         // strobe de resultado valido
                end

                // ------------------------------------------------------------
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
