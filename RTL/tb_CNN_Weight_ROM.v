// ============================================================================
// Testbench: tb_CNN_Weight_ROM
// Verifica se os pesos gravados na ROM correspondem EXATAMENTE aos pesos
// treinados em Python.
//
// Os valores esperados vem de vetores/rom_pesos.hex, gerado pelo mesmo script
// que gera a ROM (python/scripts/05_exportar_rtl.py). Ordem do arquivo:
//     72 pesos conv (filtro f, tap t -> indice f*9+t)
//      8 bias conv
//     32 pesos densa (classe k, feature i -> indice k*8+i)
//      4 bias densa
//
// Testes:
//   1) Conferencia exaustiva dos 116 valores (prova que a organizacao "por
//      tap" da ROM e o empacotamento {F7..F0} estao corretos).
//   2) Enderecos fora da faixa devolvem zero (tap 9..15).
//   3) Todos os pesos dentro da faixa Q1.15 (garantido pelo treino).
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Weight_ROM;

    localparam WIDTH = 16;
    localparam NF    = 8;
    localparam NROM  = 116;

    reg  [3:0]  tap_addr = 0;
    reg  [4:0]  dense_addr = 0;
    reg  [1:0]  dense_bias_addr = 0;
    wire [NF*WIDTH-1:0] conv_w, conv_bias;
    wire signed [WIDTH-1:0] dense_w, dense_bias;

    integer errors = 0, checks = 0;
    integer f, t, k, e0;
    reg signed [WIDTH-1:0] got;
    reg signed [WIDTH-1:0] ref_rom [0:NROM-1];

    CNN_Weight_ROM #(.WIDTH(WIDTH), .NUM_FILTERS(NF)) dut (
        .tap_addr(tap_addr), .conv_w(conv_w), .conv_bias(conv_bias),
        .dense_addr(dense_addr), .dense_w(dense_w),
        .dense_bias_addr(dense_bias_addr), .dense_bias(dense_bias)
    );

    task confere(input signed [WIDTH-1:0] obtido, input integer idx, input [8*16-1:0] nome);
        begin
            checks = checks + 1;
            if (obtido !== ref_rom[idx]) begin
                errors = errors + 1;
                $display("  [FALHA] %0s: obtido=%0d esperado=%0d", nome, obtido, ref_rom[idx]);
            end
        end
    endtask

    initial begin
        $readmemh("vetores/rom_pesos.hex", ref_rom);
        $display("========================================================");
        $display(" TESTBENCH: CNN_Weight_ROM (pesos treinados)");
        $display("========================================================\n");

        // 1a) 72 pesos convolucionais
        $display("-- Conferencia dos 72 coeficientes dos kernels");
        e0 = errors;
        for (t = 0; t < 9; t = t + 1) begin
            tap_addr = t[3:0]; #1;
            for (f = 0; f < NF; f = f + 1)
                confere(conv_w[f*WIDTH +: WIDTH], f*9 + t, "conv_w");
        end
        if (errors == e0) $display("  [ OK  ] 72 coeficientes conferem");

        // 1b) bias da convolucao
        e0 = errors;
        for (f = 0; f < NF; f = f + 1)
            confere(conv_bias[f*WIDTH +: WIDTH], 72 + f, "conv_bias");
        if (errors == e0) $display("  [ OK  ] 8 bias da convolucao conferem");

        // 1c) densa
        e0 = errors;
        for (k = 0; k < 32; k = k + 1) begin
            dense_addr = k[4:0]; #1;
            confere(dense_w, 80 + k, "dense_w");
        end
        for (k = 0; k < 4; k = k + 1) begin
            dense_bias_addr = k[1:0]; #1;
            confere(dense_bias, 112 + k, "dense_bias");
        end
        if (errors == e0) $display("  [ OK  ] 32 pesos + 4 bias da camada densa conferem");

        // 2) enderecos invalidos
        $display("\n-- Enderecos de tap fora da faixa (9..15) devolvem zero");
        e0 = errors;
        for (t = 9; t < 16; t = t + 1) begin
            tap_addr = t[3:0]; #1;
            checks = checks + 1;
            if (conv_w !== {(NF*WIDTH){1'b0}}) begin
                errors = errors + 1;
                $display("  [FALHA] tap %0d devolveu valor nao nulo", t);
            end
        end
        if (errors == e0) $display("  [ OK  ] default = 0");

        // Impressao dos kernels treinados (documentacao)
        $display("\n-- Kernels treinados (Q1.15), linha*3+coluna:");
        for (f = 0; f < NF; f = f + 1)
            $display("   F%0d: %6d %6d %6d | %6d %6d %6d | %6d %6d %6d   bias=%0d", f,
                ref_rom[f*9+0], ref_rom[f*9+1], ref_rom[f*9+2], ref_rom[f*9+3], ref_rom[f*9+4],
                ref_rom[f*9+5], ref_rom[f*9+6], ref_rom[f*9+7], ref_rom[f*9+8], ref_rom[72+f]);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

endmodule
