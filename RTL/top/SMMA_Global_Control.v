// ============================================================================
// Module: SMMA_Global_Control
// Description: UNIDADE DE CONTROLE GLOBAL do SMMA (enunciado, secao 4).
//
//   Uma janela completa, do dataset ao veredito, em cinco estados:
//
//     E_PARADO  --disparo && todos prontos-->  E_ARRANCA
//     E_ARRANCA --1 ciclo------------------->  E_ADQUIRE
//     E_ADQUIRE --fb_done (32 quadros)------>  E_DECIDE
//     E_DECIDE  --arvore e CNN validas------>  E_PRONTO
//     E_PRONTO  --1 ciclo------------------->  E_PARADO
//
//   Modo de operacao dos blocos (decisao de projeto, secao 4):
//     - PIPELINE por stream dentro da janela: FIR -> quadros -> FFT ->
//       espectro -> features avancam amostra a amostra pelo handshake;
//     - PARALELO entre ramos: FFT/MDC, LMS, autocorrelacao/inversao e CNN
//       consomem a MESMA janela ao mesmo tempo;
//     - SEQUENCIAL entre janelas: uma nova janela so e aceita quando todos
//       os blocos voltaram ao repouso (sinal 'todos_prontos').
//
//   Os pulsos de start de TODOS os blocos de aquisicao saem de um unico
//   registrador ('arranca'), para que comecem no mesmo ciclo -- comecar um
//   ramo um ciclo depois do outro desalinharia o vetor de caracteristicas.
//
//   A CNN tambem arranca aqui, e nao quando o espectrograma fecha: o 'done'
//   do Spectrogram_Buffer so sobe DEPOIS de a imagem ter sido drenada.
//   Arrancando junto, a CNN espera no handshake de carga, o que lhe e
//   indiferente.
// ============================================================================

`timescale 1ns / 1ps

module SMMA_Global_Control (
    input  wire        clk,
    input  wire        rst,

    // ---- Comando do operador ----
    input  wire        disparo,          // pulso de 1 ciclo (KEY[1])
    input  wire        todos_prontos,    // AND dos 'ready' de todos os blocos

    // ---- Andamento da janela ----
    input  wire        fb_done,          // Frame_Builder entregou os 32 quadros

    // ---- Resultados dos classificadores ----
    input  wire        tree_out_valid,
    input  wire [1:0]  tree_class,
    input  wire        tree_out_error,
    input  wire        cnn_valid,
    input  wire [1:0]  cnn_class,
    input  wire [1:0]  classe_verdadeira,

    // ---- Comandos aos blocos ----
    output reg         arranca,          // start de todos os blocos da janela
    output wire        tree_start,       // start do classificador

    // ---- Veredito registrado (para o painel) ----
    output reg  [1:0]  r_tree_class,
    output reg  [1:0]  r_cnn_class,
    output reg  [1:0]  r_verdadeira,
    output reg         r_tree_err,
    output reg         r_valido,
    output wire        ocupado
);

    localparam [2:0] E_PARADO  = 3'd0,
                     E_ARRANCA = 3'd1,   // pulso de start em todos os blocos
                     E_ADQUIRE = 3'd2,   // 1056 amostras -> 32 quadros
                     E_DECIDE  = 3'd3,   // features -> arvore; CNN em paralelo
                     E_PRONTO  = 3'd4;
    reg [2:0] est;

    reg tree_ok, cnn_ok;

    // O classificador comeca a receber features ja aqui: fica retido no
    // handshake ate o vetor de caracteristicas estar completo.
    assign tree_start = (est == E_ARRANCA);
    assign ocupado    = (est != E_PARADO) && (est != E_PRONTO);

    always @(posedge clk) begin
        if (rst) begin
            est          <= E_PARADO;
            arranca      <= 1'b0;
            r_valido     <= 1'b0;
            r_tree_class <= 2'd0;
            r_cnn_class  <= 2'd0;
            r_verdadeira <= 2'd0;
            r_tree_err   <= 1'b0;
            tree_ok      <= 1'b0;
            cnn_ok       <= 1'b0;
        end else begin
            arranca <= 1'b0;

            case (est)
                E_PARADO: begin
                    if (disparo && todos_prontos) begin
                        arranca  <= 1'b1;
                        r_valido <= 1'b0;
                        tree_ok  <= 1'b0;
                        cnn_ok   <= 1'b0;
                        est      <= E_ARRANCA;
                    end
                end

                E_ARRANCA: est <= E_ADQUIRE;

                E_ADQUIRE: if (fb_done) est <= E_DECIDE;

                E_DECIDE: begin
                    if (tree_out_valid && !tree_ok) begin
                        r_tree_class <= tree_class;
                        r_tree_err   <= tree_out_error;
                        tree_ok      <= 1'b1;
                    end
                    if (cnn_valid && !cnn_ok) begin
                        r_cnn_class <= cnn_class;
                        cnn_ok      <= 1'b1;
                    end
                    if ((tree_ok || tree_out_valid) && (cnn_ok || cnn_valid)) begin
                        r_verdadeira <= classe_verdadeira;
                        r_valido     <= 1'b1;
                        est          <= E_PRONTO;
                    end
                end

                // Volta sozinho: uma tecla por medida. O painel nao apaga,
                // porque r_valido e o veredito so sao limpos no proximo
                // arranque.
                E_PRONTO: est <= E_PARADO;

                default: est <= E_PARADO;
            endcase
        end
    end

endmodule
