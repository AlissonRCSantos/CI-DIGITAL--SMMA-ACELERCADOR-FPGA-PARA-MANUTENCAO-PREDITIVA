// ============================================================================
// Stream_Fork -- replica um stream valid/ready para N consumidores (join)
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
