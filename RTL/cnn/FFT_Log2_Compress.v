// ============================================================================
// FFT_Log2_Compress -- LOG2: log2 (Mitchell) da magnitude -> pixel do espectrograma
// ============================================================================

`timescale 1ns / 1ps

module FFT_Log2_Compress #(
    parameter WIDTH = 16    // Largura da magnitude e do pixel
)(
    input  wire              clk,        // Clock do sistema (50 MHz)
    input  wire              rst,        // Reset sincrono ativo em alto
    input  wire              en,         // Clock-enable (contrapressao)

    input  wire              in_valid,   // Magnitude valida neste ciclo
    input  wire [WIDTH-1:0]  in_mag,     // |X[k]| (Q1.15 sem sinal)

    output reg               out_valid,  // Pixel valido (1 ciclo depois)
    output reg  [WIDTH-1:0]  out_pixel   // Pixel do espectrograma (0..32767)
);

    localparam W_M     = WIDTH + 1;              // 17 bits: m = |X| + 1
    localparam E_W     = 5;                      // expoente 0..16
    localparam PIX_MAX = (1 << (WIDTH-1)) - 1;   // 32767

    // m = |X| + 1   (o +1 garante m >= 1, logo log2 sempre definido)
    wire [W_M-1:0] m = {1'b0, in_mag} + 1'b1;

    // Priority encoder: e = indice do bit mais significativo em 1 = floor(log2 m)
    // O laco tem limite constante (W_M), portanto e desenrolado em sintese.
    integer i;
    reg [E_W-1:0] e;
    always @(*) begin
        e = {E_W{1'b0}};
        for (i = 0; i < W_M; i = i + 1)
            if (m[i]) e = i[E_W-1:0];
    end

    // Mantissa normalizada: ((m - 2^e) << 11) >> e
    wire [W_M-1:0] frac   = m - ({{(W_M-1){1'b0}}, 1'b1} << e);
    wire [W_M-1:0] mant   = (e <= 5'd11) ? (frac << (5'd11 - e))
                                         : (frac >> (e - 5'd11));

    // pixel = e*2048 + mantissa  (e*2048 == e << 11, sem multiplicador)
    wire [W_M+4:0] pix_full = ({{(W_M+5-E_W){1'b0}}, e} << 11)
                            + {{5{1'b0}}, mant};

    // Saida registrada com saturacao em 32767
    always @(posedge clk) begin
        if (rst) begin
            out_pixel <= {WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else if (en) begin
            out_pixel <= (pix_full > PIX_MAX) ? PIX_MAX[WIDTH-1:0]
                                              : pix_full[WIDTH-1:0];
            out_valid <= in_valid;
        end
    end

endmodule
