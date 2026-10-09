// ============================================================================
// Module: Feature_Spectral
// Description: Extrai as 8 caracteristicas ESPECTRAIS do classificador
//              numerico (enunciado 3.5) a partir do ESPECTRO MEDIO da janela,
//              entregue pelo Spectrum_Accumulator.
//
// ----------------------------------------------------------------------------
// AS 8 SAIDAS (todas em Q1.15, na ordem em que o classificador as espera)
// ----------------------------------------------------------------------------
//   0 r_1x      spec[1]  / E     1x da rotacao (50 Hz)  -> DESBALANCEAMENTO
//   1 r_2x      spec[2]  / E     2x (100 Hz)
//   2 r_3x      spec[3]  / E     3x (150 Hz)            -> DESALINHAMENTO
//   3 r_banda1  spec[4:7]  / E   200-400 Hz  (BPFO 179, BPFI 272 Hz)
//   4 r_banda2  spec[8:15] / E   400-800 Hz
//   5 r_banda3  spec[16:31]/ E   800-1600 Hz            -> ROLAMENTO
//   6 log2E     log2 da energia total (aproximacao de Mitchell)
//   7 centroide centro de massa espectral, normalizado
//
//   Seis delas sao RAZOES pela energia total: nao dependem do nivel absoluto
//   do sinal, e e por isso que a arvore aguenta a variacao de carga bem
//   melhor que a CNN.
//
// ----------------------------------------------------------------------------
// ARITMETICA -- precisa casar BIT A BIT com smma/features.py
// ----------------------------------------------------------------------------
//   Os limiares da arvore foram aprendidos sobre ESTES valores, entao
//   qualquer diferenca desloca as fronteiras de decisao. Por isso:
//     - a media dos 32 quadros e um DESLOCAMENTO (>>5), feito no
//       Spectrum_Accumulator;
//     - as razoes usam divisao INTEIRA truncada, (x << 15) / E;
//     - log2 e a aproximacao de MITCHELL (mesma de FFT_Log2_Compress.v).
//
// ----------------------------------------------------------------------------
// RECURSOS
// ----------------------------------------------------------------------------
//   1 divisor por restauracao (Divider_Q15, compartilhado nas 7 divisoes),
//   1 multiplicador pequeno 5x16 para o centroide. ZERO DSP.
//   Latencia: 32 bins + 7x16 de divisao ~= 150 ciclos.
// ============================================================================

`timescale 1ns / 1ps

module Feature_Spectral #(
    parameter WIDTH  = 16,
    parameter N_BINS = 32,
    parameter ACC_W  = 24,
    parameter N_FEAT = 8
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,
    output wire                     ready,
    output reg                      busy,
    output reg                      done,

    // ---- Entrada: espectro medio, bins 0..31 (bin 0 = DC, descartado) ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire [WIDTH-1:0]         in_mag,

    // ---- Saida: 8 features em Q1.15, uma por ciclo aceito ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_feature
);

    // ------------------------------------------------------------------------
    // Somas derivadas do espectro medio
    // ------------------------------------------------------------------------
    localparam EW = ACC_W + 5;
    reg [EW-1:0]    E;        // energia total (bins 1..31)
    reg [EW-1:0]    s_pond;   // sum(i * spec[i]) para o centroide
    reg [EW-1:0]    b1, b2, b3;
    reg [ACC_W-1:0] s1, s2, s3;
    reg [5:0]       bin_cnt;

    wire [ACC_W-1:0] spec_i = {{(ACC_W-WIDTH){1'b0}}, in_mag};

    // ------------------------------------------------------------------------
    // Divisor compartilhado
    // ------------------------------------------------------------------------
    reg          div_start;
    reg  [31:0]  div_num, div_den;
    wire         div_ready, div_done;
    wire [15:0]  div_q;
    wire         div_zero;

    Divider_Q15 #(.NUM_W(32), .DEN_W(32), .FRAC(15)) u_div (
        .clk(clk), .rst(rst), .start(div_start), .ready(div_ready),
        .done(div_done), .num(div_num), .den(div_den),
        .quociente(div_q), .div_zero(div_zero)
    );

    // ------------------------------------------------------------------------
    // log2 de Mitchell para E -- combinacional. Opera sobre E+1, igual ao
    // FFT_Log2_Compress e ao modelo Python.
    // ------------------------------------------------------------------------
    wire [EW-1:0] E1 = E + 1'b1;
    integer k;
    reg [4:0] e_exp;
    always @(*) begin
        e_exp = 5'd0;
        for (k = 0; k < EW; k = k + 1)
            if (E1[k]) e_exp = k[4:0];
    end
    wire [EW-1:0] e_frac = E1 - ({{(EW-1){1'b0}}, 1'b1} << e_exp);
    wire [EW-1:0] e_mant = (e_exp <= 5'd11) ? (e_frac << (5'd11 - e_exp))
                                            : (e_frac >> (e_exp - 5'd11));
    wire [EW+4:0] log2_full = ({{(EW+5-5){1'b0}}, e_exp} << 11)
                            + {{5{1'b0}}, e_mant};
    wire [15:0]   log2_sat  = (log2_full > 32767) ? 16'd32767 : log2_full[15:0];

    // ------------------------------------------------------------------------
    // Resultados
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] feat [0:N_FEAT-1];
    reg [2:0]              idx;

    localparam [1:0] S_IDLE = 2'd0,
                     S_SOMA = 2'd1,
                     S_DIV  = 2'd2,
                     S_OUT  = 2'd3;
    reg [1:0] state;

    assign ready       = (state == S_IDLE);
    assign in_ready    = (state == S_SOMA);
    assign out_valid   = (state == S_OUT);
    assign out_feature = feat[idx];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            bin_cnt   <= 6'd0;
            idx       <= 3'd0;
            div_start <= 1'b0;
            div_num   <= 32'd0;
            div_den   <= 32'd0;
            E <= 0; s_pond <= 0; b1 <= 0; b2 <= 0; b3 <= 0;
            s1 <= 0; s2 <= 0; s3 <= 0;
            for (i = 0; i < N_FEAT; i = i + 1) feat[i] <= {WIDTH{1'b0}};
        end else begin
            done      <= 1'b0;
            div_start <= 1'b0;

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        bin_cnt <= 6'd0;
                        E <= 0; s_pond <= 0; b1 <= 0; b2 <= 0; b3 <= 0;
                        busy    <= 1'b1;
                        state   <= S_SOMA;
                    end
                end

                // ------------------------------------------------------
                // Recebe os 32 bins do espectro medio. O bin 0 (DC) entra
                // no handshake mas nao em nenhuma soma.
                // ------------------------------------------------------
                S_SOMA: begin
                    if (in_valid && in_ready) begin
                        if (bin_cnt != 6'd0) begin
                            E      <= E + spec_i;
                            s_pond <= s_pond + (bin_cnt * spec_i);  // 5x16, LUTs
                        end
                        if (bin_cnt == 6'd1) s1 <= spec_i;
                        if (bin_cnt == 6'd2) s2 <= spec_i;
                        if (bin_cnt == 6'd3) s3 <= spec_i;
                        if (bin_cnt >= 6'd4  && bin_cnt <= 6'd7)  b1 <= b1 + spec_i;
                        if (bin_cnt >= 6'd8  && bin_cnt <= 6'd15) b2 <= b2 + spec_i;
                        if (bin_cnt >= 6'd16)                     b3 <= b3 + spec_i;

                        if (bin_cnt == N_BINS - 1) begin
                            idx   <= 3'd0;
                            state <= S_DIV;
                        end else begin
                            bin_cnt <= bin_cnt + 1'b1;
                        end
                    end
                end

                // ------------------------------------------------------
                // 7 divisoes sequenciais + log2, uma feature por vez.
                // 'div_done' e testado ANTES de 'div_ready': no ciclo em que
                // o divisor termina ele levanta os DOIS sinais.
                // ------------------------------------------------------
                S_DIV: begin
                    if (div_done) begin
                        feat[idx] <= div_q;
                        if (idx == 3'd7) begin
                            idx   <= 3'd0;
                            state <= S_OUT;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end else if (idx == 3'd6) begin
                        feat[6] <= log2_sat;           // combinacional
                        idx     <= 3'd7;
                    end else if (div_ready && !div_start) begin
                        div_start <= 1'b1;
                        case (idx)
                            3'd0: begin div_num <= s1; div_den <= E;      end
                            3'd1: begin div_num <= s2; div_den <= E;      end
                            3'd2: begin div_num <= s3; div_den <= E;      end
                            3'd3: begin div_num <= b1; div_den <= E;      end
                            3'd4: begin div_num <= b2; div_den <= E;      end
                            3'd5: begin div_num <= b3; div_den <= E;      end
                            // centroide = (s_pond << 10)/E = (x<<15)/(E<<5)
                            default: begin div_num <= s_pond; div_den <= E << 5; end
                        endcase
                    end
                end

                // ------------------------------------------------------
                S_OUT: begin
                    if (out_ready) begin
                        if (idx == N_FEAT - 1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
