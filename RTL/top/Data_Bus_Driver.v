// ============================================================================
// Module: Data_Bus_Driver
// Description: BARRAMENTO DE DADOS FILTRADOS do SMMA -- o bloco "DATA BUS
//              DRIVER" do diagrama de arquitetura. Recebe o stream que sai do
//              estagio LMS e o distribui aos ramos de processamento:
//
//                destino 0 : MEM_A -> FFT        (Frame_Builder / FFT_Top)
//                destino 1 : acumulador de coeficientes -> Gauss-Jordan
//                            (autocorrelacao_yw / Yule_Walker_Solver)
//
//              E o "mecanismo de comunicacao entre os modulos" da secao 4 do
//              enunciado para o dado principal do sistema.
//
// ----------------------------------------------------------------------------
// PROTOCOLO (handshake valid/ready com semantica de JOIN)
// ----------------------------------------------------------------------------
//   Uma palavra so e retirada do produtor quando TODOS os destinos a aceitam
//   no mesmo ciclo (Stream_Fork). Assim:
//     - nenhum ramo perde amostra (o produtor segura o dado);
//     - nenhum ramo recebe amostra duplicada;
//     - os ramos processam SEMPRE a mesma janela, amostra a amostra.
//   O dado e um barramento comum (out_sample), lido por cada destino no
//   ciclo em que o seu out_valid sobe.
//
// ----------------------------------------------------------------------------
// CANAIS
// ----------------------------------------------------------------------------
//   O dataset tem 4 acelerometros (x/y nos mancais A e B), mas o sistema usa
//   um canal (x do mancal A): a ROM de demonstracao de 1 canal ja ocupa 52%
//   das M10K da DE0-CV, e os modelos (arvore e CNN) foram treinados com esse
//   canal. Por isso o barramento tem uma unica origem.
//
// Recursos: 1 porta AND. Latencia: zero (combinacional).
// ============================================================================

`timescale 1ns / 1ps

module Data_Bus_Driver #(
    parameter WIDTH  = 16,
    parameter N_DEST = 2                  // numero de ramos consumidores
)(
    // ---- Origem: estagio LMS ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,

    // ---- Destinos ----
    output wire [N_DEST-1:0]        out_valid,
    input  wire [N_DEST-1:0]        out_ready,
    output wire signed [WIDTH-1:0]  out_sample
);

    Stream_Fork #(.N(N_DEST)) u_join (
        .in_valid (in_valid),
        .in_ready (in_ready),
        .out_valid(out_valid),
        .out_ready(out_ready)
    );

    assign out_sample = in_sample;

endmodule
