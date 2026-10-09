// ============================================================================
// Module: Stream_Fork
// Description: Mecanismo de comunicacao entre modulos (enunciado, secao 4):
//              replica UM stream valid/ready para N consumidores com
//              semantica de "join" -- o dado so avanca quando TODOS aceitam.
//
// ----------------------------------------------------------------------------
// POR QUE "JOIN" E NAO UMA SIMPLES DERIVACAO DO FIO
// ----------------------------------------------------------------------------
//   Se o produtor considerasse a palavra entregue quando apenas UM consumidor
//   a aceitou, os outros a perderiam e passariam a processar janelas
//   DIFERENTES, sem nenhum erro visivel -- os classificadores decidiriam
//   sobre dados dessincronizados. Com o join:
//
//       in_ready     = AND de todos os out_ready
//       out_valid[i] = in_valid AND in_ready      (todos veem o MESMO ciclo)
//
//   Nenhuma palavra e perdida (o produtor segura o dado enquanto in_ready=0)
//   e nenhuma e duplicada (cada consumidor ve valid&&ready exatamente uma vez
//   por palavra). E o protocolo de handshaking pedido na secao 4.
//
//   Nao ha impasse: nenhum consumidor espera pelo outro para levantar o seu
//   ready, e todos terminam em tempo finito.
//
//   O barramento de DADOS nao passa por aqui: e um fio comum, lido por todos
//   os consumidores no ciclo em que out_valid[i] sobe.
//
// Recursos: 1 porta AND de N entradas. Latencia: zero (combinacional).
// ============================================================================

`timescale 1ns / 1ps

module Stream_Fork #(
    parameter N = 2                       // numero de consumidores
)(
    // ---- Lado do produtor ----
    input  wire          in_valid,
    output wire          in_ready,

    // ---- Lado dos consumidores ----
    output wire [N-1:0]  out_valid,
    input  wire [N-1:0]  out_ready
);

    assign in_ready  = &out_ready;
    assign out_valid = {N{in_valid & in_ready}};

endmodule
