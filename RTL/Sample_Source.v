// ============================================================================
// Module: Sample_Source
// Description: Fonte de amostras para a DEMONSTRACAO EM FPGA (enunciado 6.7).
//              ROM com janelas reais do dataset, entregues na taxa do
//              acelerometro (25,6 kHz) atraves de handshake valid/ready.
//
// ----------------------------------------------------------------------------
// PARA QUE SERVE
// ----------------------------------------------------------------------------
//   O enunciado exige demonstrar o projeto gravado na placa "utilizando sinais
//   de entrada e saida que permitam verificar o processamento". Nao ha
//   acelerometro ligado a FPGA, entao este modulo substitui o sensor: guarda
//   trechos REAIS de vibracao do dataset (Jung et al., KAIST) e os reproduz
//   com a mesma temporizacao que o sensor teria.
//
//   Do ponto de vista do resto do sistema ele e INDISTINGUIVEL de um ADC: a
//   mesma interface valid/ready, a mesma taxa. Trocar por um conversor real
//   depois nao exige mudar mais nada a jusante.
//
// ----------------------------------------------------------------------------
// CONTEUDO DA ROM
// ----------------------------------------------------------------------------
//   N_JANELAS janelas x N_AMOSTRAS amostras, em Q1.15 (fundo de escala
//   +-32 g). As janelas cobrem 4 classes x 3 cargas e vem TODAS da particao
//   de TESTE -- nunca vistas no treino. Demonstrar com dados de treino nao
//   provaria nada, porque o modelo os memorizou.
//
//   'rotulo' entrega, para a janela selecionada:
//       bits [3:2] classe verdadeira    bits [1:0] classe prevista no modelo
//   Isso permite a placa mostrar lado a lado o esperado e o obtido. Uma das
//   12 janelas (normal a 4 Nm) e classificada ERRADA pelo modelo -- isso e
//   proposital: o sistema acerta ~93%, nao 100%, e a demonstracao mostra a
//   realidade.
//
// ----------------------------------------------------------------------------
// TEMPORIZACAO
// ----------------------------------------------------------------------------
//   50 MHz / 25,6 kHz = 1953,125 ciclos por amostra. Usamos 1953, o que da
//   25.601,6 Hz -- erro de 0,006%, tres ordens de grandeza abaixo da
//   resolucao de 50 Hz por bin da FFT, portanto irrelevante.
//
//   Com MODO_RAPIDO=1 a fonte entrega as amostras o mais rapido que o
//   consumidor aceitar, o que encurta a simulacao; em 0 respeita a taxa real
//   (uma janela leva 332 ms, bom para uma demonstracao ao vivo).
// ============================================================================

`timescale 1ns / 1ps

module Sample_Source #(
    parameter WIDTH       = 16,
    parameter N_JANELAS   = 12,
    parameter N_AMOSTRAS  = 8503,          // amostras cruas por janela
    parameter DIV_TAXA    = 1953,          // 50 MHz / 25,6 kHz
    parameter MODO_RAPIDO = 0,             // 1 = ignora a taxa (simulacao)
    parameter ARQ_AMOSTRAS = "vetores/demo_amostras.hex",
    parameter ARQ_ROTULOS  = "vetores/demo_rotulos.hex"
)(
    input  wire                     clk,       // 50 MHz
    input  wire                     rst,       // Reset sincrono ativo em alto

    // ---- Controle ----
    input  wire                     start,     // Pulso: inicia uma janela
    input  wire [3:0]               janela,    // Seletor (ex.: SW[3:0])
    output reg                      busy,      // Reproduzindo
    output reg                      done,      // Pulso: janela terminou

    // ---- Saida: stream de amostras (interface identica a de um ADC) ----
    input  wire                     out_ready,
    output reg                      out_valid,
    output reg  signed [WIDTH-1:0]  out_sample,

    // ---- Metadados da janela selecionada ----
    output wire [1:0]               classe_verdadeira,
    output wire [1:0]               classe_esperada    // previsao do modelo
);

    localparam TOTAL = N_JANELAS * N_AMOSTRAS;
    localparam ADDR_W = 20;                  // 12 * 8503 = 102.036 < 2^20
    localparam CNT_W  = 11;                  // conta ate DIV_TAXA

    // ------------------------------------------------------------------------
    // Memorias
    // ------------------------------------------------------------------------
    reg [WIDTH-1:0] rom     [0:TOTAL-1];
    reg [3:0]       rotulos [0:N_JANELAS-1];
    initial begin
        $readmemh(ARQ_AMOSTRAS, rom);
        $readmemh(ARQ_ROTULOS,  rotulos);
    end

    wire [3:0] rot = rotulos[janela];
    assign classe_verdadeira = rot[3:2];
    assign classe_esperada   = rot[1:0];

    // ------------------------------------------------------------------------
    // Reproducao
    // ------------------------------------------------------------------------
    reg [ADDR_W-1:0] addr;        // posicao absoluta na ROM
    reg [ADDR_W-1:0] restantes;   // amostras que faltam na janela
    reg [CNT_W-1:0]  divisor;     // gerador da taxa de 25,6 kHz

    wire tick = MODO_RAPIDO ? 1'b1 : (divisor == DIV_TAXA - 1);
    // Nao avanca enquanto a amostra anterior nao tiver sido consumida: e o
    // que impede sobrescrever uma amostra que o FIR ainda nao leu.
    wire pode_emitir = busy && tick && !(out_valid && !out_ready);

    always @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            out_valid  <= 1'b0;
            out_sample <= {WIDTH{1'b0}};
            addr       <= {ADDR_W{1'b0}};
            restantes  <= {ADDR_W{1'b0}};
            divisor    <= {CNT_W{1'b0}};
        end else begin
            done <= 1'b0;                       // pulso de 1 ciclo

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (!busy) begin
                if (start) begin
                    addr      <= janela * N_AMOSTRAS;
                    restantes <= N_AMOSTRAS;
                    divisor   <= {CNT_W{1'b0}};
                    busy      <= 1'b1;
                end
            end else begin
                divisor <= (divisor == DIV_TAXA - 1) ? {CNT_W{1'b0}}
                                                     : (divisor + 1'b1);
                if (pode_emitir) begin
                    out_sample <= rom[addr];
                    out_valid  <= 1'b1;
                    addr       <= addr + 1'b1;
                    if (restantes == 1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    restantes <= restantes - 1'b1;
                end
            end
        end
    end

endmodule
