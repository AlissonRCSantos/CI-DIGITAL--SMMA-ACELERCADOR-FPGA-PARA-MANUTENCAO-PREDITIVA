// ============================================================================
// CNN_Control_FSM -- controle do acelerador CNN (convolucao, pooling, densa)
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

    // Codificacao dos estados
    localparam ST_IDLE   = 3'd0;
    localparam ST_STREAM = 3'd1;
    localparam ST_DRAIN  = 3'd2;
    localparam ST_DENSE  = 3'd3;
    localparam ST_FINISH = 3'd4;

    reg [2:0]  state;
    reg [15:0] pool_cnt;   // conta as saidas do max pooling deste quadro

    // Logica de fluxo de entrada (combinacional)
    assign push_en  = enable && (state == ST_STREAM) && conv_ready &&
                      (need_pixel ? in_valid : 1'b1);

    assign in_ready = enable && (state == ST_STREAM) && conv_ready && need_pixel;

    // Maquina de estados
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

                ST_STREAM: begin
                    // A varredura terminou quando o ultimo passo foi efetivado
                    if (push_en && last_push)
                        state <= ST_DRAIN;
                end

                ST_DRAIN: begin
                    // Espera o pipeline esvaziar e o pooling fechar as 256 saidas
                    if (pool_cnt == NUM_POOL) begin
                        state     <= ST_DENSE;
                        dense_run <= 1'b1;     // dispara GAP -> densa -> argmax
                    end
                end

                ST_DENSE: begin
                    if (dense_done)
                        state <= ST_FINISH;
                end

                ST_FINISH: begin
                    state     <= ST_IDLE;
                    busy      <= 1'b0;
                    ready     <= 1'b1;
                    done      <= 1'b1;
                    valid_out <= 1'b1;         // strobe de resultado valido
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
