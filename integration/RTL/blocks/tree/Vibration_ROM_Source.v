`timescale 1ns / 1ps

// Fonte de uma janela gravada em ROM síncrona para inferência em M10K.
// Cada palavra guarda {sample_d[15:0], sample_x[15:0]} em Q1.15.
module Vibration_ROM_Source #(
    parameter WIDTH = 32,
    parameter N_SAMPLES = 8503,
    parameter DIV_RATE = 1953,
    parameter FAST = 0,
    parameter ROM_FILE = "vetores/vibration_input.hex"
)(
    input wire clk,
    input wire rst,
    input wire start,
    output reg busy,
    output reg done,
    input wire out_ready,
    output reg out_valid,
    output reg [WIDTH-1:0] out_sample
);
    localparam ADDR_W = (N_SAMPLES <= 2) ? 1 : $clog2(N_SAMPLES + 1);
    localparam CNT_W = (DIV_RATE <= 2) ? 1 : $clog2(DIV_RATE);
    (* ramstyle = "M10K" *) reg [WIDTH-1:0] rom [0:N_SAMPLES-1];
    reg [WIDTH-1:0] rom_q;
    reg [ADDR_W-1:0] addr;
    reg [ADDR_W:0] remaining;
    reg [CNT_W-1:0] divider;

    initial $readmemh(ROM_FILE, rom);

    wire tick = FAST ? 1'b1 : (divider == DIV_RATE - 1);
    wire emit_sample = busy && tick && !(out_valid && !out_ready);
    wire [ADDR_W-1:0] addr_next =
        rst ? {ADDR_W{1'b0}} :
        (!busy && start) ? {ADDR_W{1'b0}} :
        (emit_sample && (remaining > 1)) ? addr + 1'b1 : addr;

    // Sem reset nem enable no port de leitura: formato inferivel como M10K.
    always @(posedge clk)
        rom_q <= rom[addr_next];

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            out_valid <= 1'b0;
            out_sample <= {WIDTH{1'b0}};
            addr <= {ADDR_W{1'b0}};
            remaining <= {(ADDR_W+1){1'b0}};
            divider <= {CNT_W{1'b0}};
        end else begin
            done <= 1'b0;
            if (out_valid && out_ready) out_valid <= 1'b0;

            if (!busy) begin
                if (start) begin
                    addr <= {ADDR_W{1'b0}};
                    remaining <= N_SAMPLES;
                    divider <= {CNT_W{1'b0}};
                    busy <= 1'b1;
                end
            end else begin
                divider <= tick ? {CNT_W{1'b0}} : divider + 1'b1;
                if (emit_sample) begin
                    out_sample <= rom_q;
                    out_valid <= 1'b1;
                    addr <= (remaining == 1) ? {ADDR_W{1'b0}} : addr + 1'b1;
                    remaining <= remaining - 1'b1;
                    if (remaining == 1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
