// ============================================================================
// Data_Bus_Driver -- DATA BUS DRIVER: entrega as amostras filtradas aos dois ramos
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
