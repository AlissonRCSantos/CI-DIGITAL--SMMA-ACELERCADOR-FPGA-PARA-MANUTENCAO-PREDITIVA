// ============================================================================
// Module: Frame_Builder
// Description: Monta os quadros de 64 amostras que alimentam a FFT, com salto
//              de 32 -- a sobreposicao de 50% que o enunciado 5 pede (uma
//              decisao a cada 10 ms).
//
// ----------------------------------------------------------------------------
// POR QUE ESTE BLOCO EXISTE
// ----------------------------------------------------------------------------
//   A FFT_Top consome 64 amostras por transformada, mas os quadros avancam de
//   32 em 32. Cada amostra decimada participa portanto de DOIS quadros, e o
//   fluxo que sai do FIR_Decimator nao pode ser ligado direto na FFT: alguem
//   tem de reapresentar as 32 amostras antigas antes das 32 novas.
//
//   Para uma janela de 32 quadros sao 64 + 31*32 = 1056 amostras decimadas --
//   exatamente a janela que o Feature_Temporal tambem consome.
//
// ----------------------------------------------------------------------------
// POR QUE E SEGURO PARAR DE ACEITAR DURANTE O DESPEJO
// ----------------------------------------------------------------------------
//   Enquanto reapresenta um quadro, o modulo baixa in_ready. Isso NAO perde
//   amostra porque a fonte respeita a contrapressao: o Sample_Source le de uma
//   ROM e segura a amostra ate ser aceita.
//
//   E o orcamento e folgado: a 3,2 kHz chega uma amostra a cada 15.625 ciclos
//   de 50 MHz, e o despejo de um quadro custa 64. A pausa e tres ordens de
//   grandeza menor que o intervalo entre amostras.
//
//   Num sistema com sensor real (sem contrapressao possivel) este bloco teria
//   de ser de duplo buffer. Com fonte em ROM, parar e correto e muito menor.
//
// ----------------------------------------------------------------------------
// MEMORIA
// ----------------------------------------------------------------------------
//   Buffer circular de 64 x 16 bits com leitura COMBINACIONAL. Sao 1024 bits,
//   que o Cyclone V acomoda em LUT-RAM sem gastar um M10K. A leitura sem
//   registro e deliberada: a FFT_Memory, que tem leitura registrada, custou
//   dois bugs de alinhamento (indice x dado sob contrapressao) -- aqui o
//   endereco e o dado andam juntos.
// ============================================================================

`timescale 1ns / 1ps

module Frame_Builder #(
    parameter WIDTH     = 16,    // Q1.15
    parameter NFFT      = 64,    // amostras por quadro
    parameter HOP       = 32,    // avanco entre quadros
    parameter N_QUADROS = 32     // quadros por janela
)(
    input  wire                     clk,
    input  wire                     rst,

    // ---- Controle ----
    input  wire                     start,     // Pulso: inicia uma janela
    output wire                     ready,     // Pronto para nova janela
    output reg                      busy,
    output reg                      done,      // Pulso: 32 quadros entregues

    // ---- Entrada: amostras decimadas (3,2 kHz) ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,

    // ---- Saida: quadros de 64 amostras para a FFT ----
    input  wire                     out_ready,
    output wire                     out_valid,
    output wire signed [WIDTH-1:0]  out_sample,
    output wire                     out_frame_ini,   // 1 na 1a amostra do quadro
    output wire                     out_frame_fim    // 1 na 64a amostra do quadro
);

    localparam PTR_W = 6;        // log2(64)
    localparam CNT_W = 7;

    reg signed [WIDTH-1:0] buf_mem [0:NFFT-1];
    reg [PTR_W-1:0]        wr_ptr;      // proxima posicao de escrita
    reg [CNT_W-1:0]        novas;       // amostras novas desde o ultimo quadro
    reg [PTR_W-1:0]        rd_cnt;      // 0..63 dentro do despejo
    reg [CNT_W-1:0]        quadro;      // 0..N_QUADROS-1

    // No primeiro quadro o buffer precisa estar CHEIO (64 amostras); depois
    // bastam HOP novas, porque as outras 32 ja estao no circular.
    wire [CNT_W-1:0] preciso = (quadro == {CNT_W{1'b0}}) ? NFFT[CNT_W-1:0]
                                                         : HOP[CNT_W-1:0];

    localparam [1:0] S_IDLE = 2'd0,
                     S_ENCHE = 2'd1,
                     S_DESPEJA = 2'd2;
    reg [1:0] state;

    assign ready    = (state == S_IDLE);
    assign in_ready = (state == S_ENCHE);

    assign out_valid     = (state == S_DESPEJA);
    assign out_frame_ini = out_valid && (rd_cnt == {PTR_W{1'b0}});
    assign out_frame_fim = out_valid && (rd_cnt == NFFT - 1);

    // wr_ptr aponta para a amostra MAIS ANTIGA do buffer cheio, entao o
    // despejo em ordem cronologica comeca nele.
    wire [PTR_W-1:0] rd_addr = wr_ptr + rd_cnt;   // soma de 6 bits = mod 64
    assign out_sample = buf_mem[rd_addr];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            wr_ptr <= {PTR_W{1'b0}};
            novas  <= {CNT_W{1'b0}};
            rd_cnt <= {PTR_W{1'b0}};
            quadro <= {CNT_W{1'b0}};
            for (i = 0; i < NFFT; i = i + 1) buf_mem[i] <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        wr_ptr <= {PTR_W{1'b0}};
                        novas  <= {CNT_W{1'b0}};
                        rd_cnt <= {PTR_W{1'b0}};
                        quadro <= {CNT_W{1'b0}};
                        busy   <= 1'b1;
                        state  <= S_ENCHE;
                    end
                end

                S_ENCHE: begin
                    if (in_valid && in_ready) begin
                        buf_mem[wr_ptr] <= in_sample;
                        wr_ptr <= wr_ptr + 1'b1;
                        if (novas + 1'b1 >= preciso) begin
                            novas  <= {CNT_W{1'b0}};
                            rd_cnt <= {PTR_W{1'b0}};
                            state  <= S_DESPEJA;
                        end else begin
                            novas <= novas + 1'b1;
                        end
                    end
                end

                S_DESPEJA: begin
                    if (out_ready) begin
                        if (rd_cnt == NFFT - 1) begin
                            rd_cnt <= {PTR_W{1'b0}};
                            if (quadro == N_QUADROS - 1) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                quadro <= quadro + 1'b1;
                                state  <= S_ENCHE;
                            end
                        end else begin
                            rd_cnt <= rd_cnt + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
