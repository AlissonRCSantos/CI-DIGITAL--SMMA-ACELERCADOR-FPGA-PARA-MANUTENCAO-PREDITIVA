// ============================================================================
// FFT_Twiddle_ROM -- fatores de rotacao W64^k em Q1.15
// ============================================================================

`timescale 1ns / 1ps

module FFT_Twiddle_ROM #(
    parameter WIDTH  = 16,  // Largura de cada componente (Q1.15)
    parameter ADDR_W = 5    // log2(N/2) -> 32 enderecos (k = 0..31)
)(
    input  wire                    clk,      // Clock do sistema (50 MHz)
    input  wire                    rst,      // Reset sincrono ativo em alto
    input  wire                    rd_en,    // Habilita a leitura (clock-enable)
    input  wire [ADDR_W-1:0]       rd_addr,  // Indice k do fator W_64^k
    output reg signed [WIDTH-1:0]  w_real,   // cos(2*pi*k/64)  em Q1.15
    output reg signed [WIDTH-1:0]  w_imag    // -sin(2*pi*k/64) em Q1.15
);

    localparam DEPTH = (1 << ADDR_W);   // 32 fatores

    // Tabela de constantes: {w_imag[15:0], w_real[15:0]}
    // Gerada offline para N = 64 e quantizada em Q1.15 (arredondamento).
    reg [2*WIDTH-1:0] ROM [0:DEPTH-1];

    initial begin
        ROM[ 0] = {16'h0000, 16'h7FFF}; // k= 0  W = +1.000000 -0.000000j
        ROM[ 1] = {16'hF374, 16'h7F62}; // k= 1  W = +0.995185 -0.098017j
        ROM[ 2] = {16'hE707, 16'h7D8A}; // k= 2  W = +0.980785 -0.195090j
        ROM[ 3] = {16'hDAD8, 16'h7A7D}; // k= 3  W = +0.956940 -0.290285j
        ROM[ 4] = {16'hCF04, 16'h7642}; // k= 4  W = +0.923880 -0.382683j
        ROM[ 5] = {16'hC3A9, 16'h70E3}; // k= 5  W = +0.881921 -0.471397j
        ROM[ 6] = {16'hB8E3, 16'h6A6E}; // k= 6  W = +0.831470 -0.555570j
        ROM[ 7] = {16'hAECC, 16'h62F2}; // k= 7  W = +0.773010 -0.634393j
        ROM[ 8] = {16'hA57E, 16'h5A82}; // k= 8  W = +0.707107 -0.707107j
        ROM[ 9] = {16'h9D0E, 16'h5134}; // k= 9  W = +0.634393 -0.773010j
        ROM[10] = {16'h9592, 16'h471D}; // k=10  W = +0.555570 -0.831470j
        ROM[11] = {16'h8F1D, 16'h3C57}; // k=11  W = +0.471397 -0.881921j
        ROM[12] = {16'h89BE, 16'h30FC}; // k=12  W = +0.382683 -0.923880j
        ROM[13] = {16'h8583, 16'h2528}; // k=13  W = +0.290285 -0.956940j
        ROM[14] = {16'h8276, 16'h18F9}; // k=14  W = +0.195090 -0.980785j
        ROM[15] = {16'h809E, 16'h0C8C}; // k=15  W = +0.098017 -0.995185j
        ROM[16] = {16'h8000, 16'h0000}; // k=16  W = +0.000000 -1.000000j
        ROM[17] = {16'h809E, 16'hF374}; // k=17  W = -0.098017 -0.995185j
        ROM[18] = {16'h8276, 16'hE707}; // k=18  W = -0.195090 -0.980785j
        ROM[19] = {16'h8583, 16'hDAD8}; // k=19  W = -0.290285 -0.956940j
        ROM[20] = {16'h89BE, 16'hCF04}; // k=20  W = -0.382683 -0.923880j
        ROM[21] = {16'h8F1D, 16'hC3A9}; // k=21  W = -0.471397 -0.881921j
        ROM[22] = {16'h9592, 16'hB8E3}; // k=22  W = -0.555570 -0.831470j
        ROM[23] = {16'h9D0E, 16'hAECC}; // k=23  W = -0.634393 -0.773010j
        ROM[24] = {16'hA57E, 16'hA57E}; // k=24  W = -0.707107 -0.707107j
        ROM[25] = {16'hAECC, 16'h9D0E}; // k=25  W = -0.773010 -0.634393j
        ROM[26] = {16'hB8E3, 16'h9592}; // k=26  W = -0.831470 -0.555570j
        ROM[27] = {16'hC3A9, 16'h8F1D}; // k=27  W = -0.881921 -0.471397j
        ROM[28] = {16'hCF04, 16'h89BE}; // k=28  W = -0.923880 -0.382683j
        ROM[29] = {16'hDAD8, 16'h8583}; // k=29  W = -0.956940 -0.290285j
        ROM[30] = {16'hE707, 16'h8276}; // k=30  W = -0.980785 -0.195090j
        ROM[31] = {16'hF374, 16'h809E}; // k=31  W = -0.995185 -0.098017j
    end

    // Leitura sincrona (1 ciclo de latencia)
    always @(posedge clk) begin
        if (rst) begin
            w_real <= {WIDTH{1'b0}};
            w_imag <= {WIDTH{1'b0}};
        end else if (rd_en) begin
            w_real <= ROM[rd_addr][WIDTH-1:0];
            w_imag <= ROM[rd_addr][2*WIDTH-1:WIDTH];
        end
    end

endmodule
