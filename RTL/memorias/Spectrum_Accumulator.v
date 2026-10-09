// ============================================================================
// Spectrum_Accumulator -- MEM_B: acumula |X[k]| dos 32 quadros e entrega o espectro medio
// ============================================================================

`timescale 1ns / 1ps

module Spectrum_Accumulator #(
    parameter WIDTH     = 16,    // largura de |X[k]|
    parameter N_BINS    = 32,    // bins uteis por quadro
    parameter N_QUADROS = 32,    // quadros por janela (potencia de 2)
    parameter LOG2_Q    = 5,     // log2(N_QUADROS): media por deslocamento
    parameter ACC_W     = 24     // 32 quadros x 65535 cabe em 21 bits
)(
    input  wire              clk,
    input  wire              rst,

    // ---- Controle ----
    input  wire              start,     // Pulso: inicia uma janela
    output wire              ready,     // Pronto para nova janela
    output reg               busy,
    output reg               done,      // Pulso: espectro medio entregue

    // ---- Entrada: |X[k]| bin a bin, quadro a quadro ----
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [WIDTH-1:0]  in_mag,

    // ---- Saida: espectro medio, bins 0..N_BINS-1 ----
    input  wire              out_ready,
    output wire              out_valid,
    output wire [5:0]        out_bin,   // indice do bin entregue
    output wire [WIDTH-1:0]  out_mag
);

    reg [ACC_W-1:0] acc [0:N_BINS-1];
    reg [5:0]       bin_cnt;
    reg [5:0]       quadro_cnt;

    localparam [1:0] S_IDLE = 2'd0,
                     S_ACC  = 2'd1,
                     S_OUT  = 2'd2;
    reg [1:0] state;

    wire [ACC_W-1:0] media = acc[bin_cnt] >> LOG2_Q;

    assign ready     = (state == S_IDLE);
    assign in_ready  = (state == S_ACC);
    assign out_valid = (state == S_OUT);
    assign out_bin   = bin_cnt;
    assign out_mag   = media[WIDTH-1:0];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            bin_cnt    <= 6'd0;
            quadro_cnt <= 6'd0;
            for (i = 0; i < N_BINS; i = i + 1) acc[i] <= {ACC_W{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        for (i = 0; i < N_BINS; i = i + 1) acc[i] <= {ACC_W{1'b0}};
                        bin_cnt    <= 6'd0;
                        quadro_cnt <= 6'd0;
                        busy       <= 1'b1;
                        state      <= S_ACC;
                    end
                end

                // ---- acumula N_QUADROS x N_BINS magnitudes ----
                S_ACC: begin
                    if (in_valid && in_ready) begin
                        acc[bin_cnt] <= acc[bin_cnt] + {{(ACC_W-WIDTH){1'b0}}, in_mag};
                        if (bin_cnt == N_BINS - 1) begin
                            bin_cnt <= 6'd0;
                            if (quadro_cnt == N_QUADROS - 1)
                                state <= S_OUT;
                            else
                                quadro_cnt <= quadro_cnt + 1'b1;
                        end else begin
                            bin_cnt <= bin_cnt + 1'b1;
                        end
                    end
                end

                // ---- entrega o espectro medio, um bin por handshake ----
                S_OUT: begin
                    if (out_ready) begin
                        if (bin_cnt == N_BINS - 1) begin
                            bin_cnt <= 6'd0;
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            state   <= S_IDLE;
                        end else begin
                            bin_cnt <= bin_cnt + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
