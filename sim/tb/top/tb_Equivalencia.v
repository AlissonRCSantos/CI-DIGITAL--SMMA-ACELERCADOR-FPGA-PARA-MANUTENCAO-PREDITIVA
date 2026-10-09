// ============================================================================
// Module: tb_Equivalencia
// Description: Prova de EQUIVALENCIA entre esta integracao modular e a
//              integracao anterior (top_level, commit 1971735), que ja havia
//              sido gravada e testada na DE0-CV.
//
// vetores/equiv_esperado.hex foi capturado SIMULANDO O PROJETO ANTERIOR,
// janela a janela (24 palavras por janela):
//
//     0..11  as 12 caracteristicas entregues a arvore (Q1.15)
//    12..15  os 4 scores da CNN
//    16      LEDR com SW[9] = 0        17  LEDR com SW[9] = 1
//    18..23  HEX0..HEX5
//
// Este testbench roda as mesmas 12 janelas no projeto ATUAL e exige
// igualdade BIT A BIT em tudo -- inclusive nas features, que nao aparecem no
// painel. Se ele passa, o comportamento na placa e o mesmo de antes; as
// 4 caracteristicas novas (f0 e a1..a3, posicoes 12..15 do vetor) nao
// participam da decisao da arvore treinada.
// ============================================================================

`timescale 1ns / 1ps

module tb_Equivalencia;

    localparam N_JAN = 12, PAL = 24;

    reg CLOCK_50 = 0; reg [1:0] KEY; reg [9:0] SW;
    wire [9:0] LEDR; wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    always #10 CLOCK_50 = ~CLOCK_50;

    SMMA_Top #(.MODO_RAPIDO(1)) uut (.CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5));

    reg [15:0] esp [0:N_JAN*PAL-1];

    // features que chegam a arvore (as 16 do vetor)
    reg signed [15:0] feat [0:15];
    integer nf;
    always @(posedge CLOCK_50)
        if (uut.u_tree.in_valid && uut.u_tree.in_ready) begin
            if (nf < 16) feat[nf] = uut.u_tree.in_feature;
            nf = nf + 1;
        end

    integer success_count = 0, fail_count = 0;
    integer j, k, c, e, base;

    task aperta;
        begin
            KEY[1] = 1; repeat (4) @(negedge CLOCK_50);
            KEY[1] = 0; repeat (4) @(negedge CLOCK_50);
            KEY[1] = 1; @(negedge CLOCK_50);
        end
    endtask

    task compara(input [8*12-1:0] nome, input [15:0] obtido, input [15:0] esperado);
        begin
            if (obtido !== esperado) begin
                e = e + 1;
                $display("[FAIL] janela %0d %0s: obtido %h, anterior %h", j, nome, obtido, esperado);
            end
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("  EQUIVALENCIA: integracao modular x integracao anterior (placa)      ");
        $display("======================================================================");
        $readmemh("vetores/equiv_esperado.hex", esp);

        SW = 0; KEY = 2'b00; repeat (8) @(negedge CLOCK_50);
        KEY = 2'b11; repeat (8) @(negedge CLOCK_50);

        for (j = 0; j < N_JAN; j = j + 1) begin
            base = j*PAL; e = 0; nf = 0;
            SW[3:0] = j; SW[9] = 0; @(negedge CLOCK_50);
            aperta;
            c = 0; while (LEDR[9] !== 1'b1 && c < 40000000) begin @(posedge CLOCK_50); c = c + 1; end
            repeat (3) @(negedge CLOCK_50);

            for (k = 0; k < 12; k = k + 1) compara("feature", feat[k], esp[base+k]);
            for (k = 0; k < 4; k = k + 1)  compara("score CNN", uut.cnn_scores[16*k +: 16], esp[base+12+k]);
            compara("LEDR",  {6'd0, LEDR}, esp[base+16]);
            compara("HEX0",  {9'd0, HEX0}, esp[base+18]);
            compara("HEX1",  {9'd0, HEX1}, esp[base+19]);
            compara("HEX2",  {9'd0, HEX2}, esp[base+20]);
            compara("HEX3",  {9'd0, HEX3}, esp[base+21]);
            compara("HEX4",  {9'd0, HEX4}, esp[base+22]);
            compara("HEX5",  {9'd0, HEX5}, esp[base+23]);
            SW[9] = 1; @(negedge CLOCK_50);
            compara("LEDR SW9", {6'd0, LEDR}, esp[base+17]);
            SW[9] = 0;

            if (e == 0) begin
                success_count = success_count + 1;
                $display("[PASS] janela %2d: 12 features, 4 scores da CNN e painel identicos  (f0=%0d Hz, a/2=[%0d %0d %0d])",
                         j, feat[12], feat[13], feat[14], feat[15]);
            end else
                fail_count = fail_count + 1;
            repeat (20) @(negedge CLOCK_50);
        end

        $display("\n RESUMO: %0d janela(s) identica(s), %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" COMPORTAMENTO IDENTICO AO DA INTEGRACAO ANTERIOR -- VALIDADO");
        $finish;
    end

    initial begin #40_000_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
