// ============================================================================
// Sample_Source -- SENSOR Xa: ROM com 12 janelas do dataset, entregues a 25,6 kHz
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

    // Memorias
    (* ramstyle = "M10K" *) reg [WIDTH-1:0] rom [0:TOTAL-1];
    reg [3:0]       rotulos [0:N_JANELAS-1];
    initial begin
        $readmemh(ARQ_AMOSTRAS, rom);
        $readmemh(ARQ_ROTULOS,  rotulos);
    end

    wire [3:0] rot = rotulos[janela];
    assign classe_verdadeira = rot[3:2];
    assign classe_esperada   = rot[1:0];

    // Reproducao
    reg [ADDR_W-1:0] addr;        // posicao absoluta na ROM
    reg [ADDR_W-1:0] restantes;   // amostras que faltam na janela
    reg [CNT_W-1:0]  divisor;     // gerador da taxa de 25,6 kHz

    wire tick = MODO_RAPIDO ? 1'b1 : (divisor == DIV_TAXA - 1);
    // Nao avanca enquanto a amostra anterior nao tiver sido consumida: e o
    // que impede sobrescrever uma amostra que o FIR ainda nao leu.
    wire pode_emitir = busy && tick && !(out_valid && !out_ready);

    // Leitura da ROM num always SEPARADO, sem reset e sem enable.
    wire [ADDR_W-1:0] addr_prox =
          rst                ? {ADDR_W{1'b0}}
        : (!busy && start)   ? janela * N_AMOSTRAS
        : (busy && pode_emitir) ? addr + 1'b1
        :                      addr;

    reg [WIDTH-1:0] rom_q;
    always @(posedge clk)
        rom_q <= rom[addr_prox];

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
                    out_sample <= rom_q;        // == rom[addr]
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
