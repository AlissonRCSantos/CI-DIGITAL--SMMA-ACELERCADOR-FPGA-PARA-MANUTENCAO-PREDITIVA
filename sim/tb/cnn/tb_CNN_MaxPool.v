// ============================================================================
// Testbench: tb_CNN_MaxPool
// Verifica o max pooling 2x2 stride 2 em streaming.
//
// Usa um mapa 4x4 com DOIS canais em paralelo, com valores unicos:
//   canal 0: cresce  (100, 200, ... 1600)  -> o maximo cai no canto inferior-direito
//   canal 1: decresce(1600, 1500, ... 100) -> o maximo cai no canto superior-esquerdo
//
// Usar dois canais com ordenacoes OPOSTAS e proposital: se houvesse qualquer
// troca de canal (crosstalk) na logica de comparacao, os resultados sairiam
// invertidos e o teste falharia imediatamente.
//
// Mapeamento esperado (canal 0):
//    entrada 4x4          saida 2x2
//    1   2   3   4        max(1,2,5,6)=6    max(3,4,7,8)=8
//    5   6   7   8    ->  max(9,10,13,14)=14 max(11,12,15,16)=16
//    9  10  11  12
//   13  14  15  16
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_MaxPool;

    localparam WIDTH = 16;
    localparam NCH   = 2;
    localparam IN_W  = 4;
    localparam IN_H  = 4;
    localparam CNT_W = 4;
    localparam IDX_W = 1;   // log2(IN_W/2) = log2(2)

    reg                    clk = 0, rst = 1, start = 0;
    reg                    in_valid = 0;
    reg  [NCH*WIDTH-1:0]   in_data = 0;
    wire                   out_valid;
    wire [NCH*WIDTH-1:0]   out_data;

    integer errors = 0, checks = 0;
    integer r, c, idx, nout = 0;

    reg signed [WIDTH-1:0] exp0 [0:3];
    reg signed [WIDTH-1:0] exp1 [0:3];
    reg signed [WIDTH-1:0] got0, got1;

    always #10 clk = ~clk;

    CNN_MaxPool #(.WIDTH(WIDTH), .NUM_CH(NCH), .IN_W(IN_W), .IN_H(IN_H), .CNT_W(CNT_W), .IDX_W(IDX_W))
    dut (
        .clk(clk), .rst(rst), .start(start),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_data(out_data)
    );

    // Monitor: confere cada saida do pooling na ordem em que aparece
    always @(negedge clk) begin
        if (out_valid && !rst) begin
            got0 = out_data[0*WIDTH +: WIDTH];
            got1 = out_data[1*WIDTH +: WIDTH];
            checks = checks + 2;
            if (got0 !== exp0[nout]) begin
                errors = errors + 1;
                $display("  [FALHA] saida %0d canal0: obtido=%0d esperado=%0d",
                         nout, got0, exp0[nout]);
            end
            if (got1 !== exp1[nout]) begin
                errors = errors + 1;
                $display("  [FALHA] saida %0d canal1: obtido=%0d esperado=%0d",
                         nout, got1, exp1[nout]);
            end
            if (got0 === exp0[nout] && got1 === exp1[nout])
                $display("  [ OK  ] saida %0d -> canal0=%0d  canal1=%0d",
                         nout, got0, got1);
            nout = nout + 1;
        end
    end

    initial begin
        // Valores esperados (calculados a mao a partir do mapa 4x4)
        exp0[0] = 600;  exp0[1] = 800;  exp0[2] = 1400; exp0[3] = 1600;
        exp1[0] = 1600; exp1[1] = 1400; exp1[2] = 800;  exp1[3] = 600;

        $display("========================================================");
        $display(" TESTBENCH: CNN_MaxPool (2x2, stride 2, 2 canais)");
        $display(" Entrada 4x4 -> saida 2x2");
        $display("========================================================\n");

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;

        // Injeta o mapa 4x4 em ordem raster (a mesma ordem que a convolucao produz)
        for (r = 0; r < IN_H; r = r + 1) begin
            for (c = 0; c < IN_W; c = c + 1) begin
                idx = r*IN_W + c;
                @(negedge clk);
                in_valid = 1'b1;
                in_data[0*WIDTH +: WIDTH] = (idx + 1) * 100;        // canal 0: crescente
                in_data[1*WIDTH +: WIDTH] = (IN_W*IN_H - idx) * 100; // canal 1: decrescente
            end
        end
        @(negedge clk); in_valid = 1'b0;
        repeat (5) @(negedge clk);

        // ---- Verificacao global ----
        $display("");
        checks = checks + 1;
        if (nout !== (IN_W/2)*(IN_H/2)) begin
            errors = errors + 1;
            $display("  [FALHA] numero de saidas: obtido=%0d esperado=%0d",
                     nout, (IN_W/2)*(IN_H/2));
        end else
            $display("  [ OK  ] %0d saidas geradas (reducao de 4x: 16 -> 4)", nout);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
