// ============================================================================
// Testbench: tb_CNN_Weight_ROM
// Verifica se os pesos gravados na ROM correspondem aos kernels projetados.
//
// Alem de conferir valores individuais, o teste valida duas PROPRIEDADES
// MATEMATICAS que devem valer para os filtros escolhidos:
//
//   * Filtros de borda (Sobel X, Sobel Y, Laplaciano, passa-alta) tem SOMA
//     DOS COEFICIENTES = 0. Isso garante que uma regiao de brilho constante
//     produza saida zero -- ou seja, eles respondem a VARIACAO, nao a nivel.
//   * O filtro de media (F3) tem soma = 1 (aprox. 9 * 1/9), preservando o
//     nivel medio do sinal.
//
// Essas propriedades sao a prova de que os filtros fazem o que prometem.
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Weight_ROM;

    localparam WIDTH = 16;
    localparam NF    = 8;

    reg  [3:0]  tap_addr = 0;
    reg  [4:0]  dense_addr = 0;
    reg  [1:0]  dense_bias_addr = 0;
    wire [NF*WIDTH-1:0] conv_w, conv_bias;
    wire signed [WIDTH-1:0] dense_w, dense_bias;

    integer errors = 0, checks = 0;
    integer f, t;
    integer soma;
    reg signed [WIDTH-1:0] got;

    // Kernels de referencia (mesma tabela usada no projeto)
    reg signed [WIDTH-1:0] ref_k [0:NF-1][0:8];

    CNN_Weight_ROM #(.WIDTH(WIDTH), .NUM_FILTERS(NF)) dut (
        .tap_addr(tap_addr), .conv_w(conv_w), .conv_bias(conv_bias),
        .dense_addr(dense_addr), .dense_w(dense_w),
        .dense_bias_addr(dense_bias_addr), .dense_bias(dense_bias)
    );

    initial begin
        // F0 Sobel X (/4)
        ref_k[0][0]=-8192; ref_k[0][1]=0;      ref_k[0][2]=8192;
        ref_k[0][3]=-16384;ref_k[0][4]=0;      ref_k[0][5]=16384;
        ref_k[0][6]=-8192; ref_k[0][7]=0;      ref_k[0][8]=8192;
        // F1 Sobel Y (/4)
        ref_k[1][0]=-8192; ref_k[1][1]=-16384; ref_k[1][2]=-8192;
        ref_k[1][3]=0;     ref_k[1][4]=0;      ref_k[1][5]=0;
        ref_k[1][6]=8192;  ref_k[1][7]=16384;  ref_k[1][8]=8192;
        // F2 Laplaciano (/8)
        ref_k[2][0]=0;     ref_k[2][1]=-4096;  ref_k[2][2]=0;
        ref_k[2][3]=-4096; ref_k[2][4]=16384;  ref_k[2][5]=-4096;
        ref_k[2][6]=0;     ref_k[2][7]=-4096;  ref_k[2][8]=0;
        // F3 Media 1/9
        for (t=0;t<9;t=t+1) ref_k[3][t]=3641;
        // F4 Diagonal decrescente
        ref_k[4][0]=-16384;ref_k[4][1]=-8192;  ref_k[4][2]=0;
        ref_k[4][3]=-8192; ref_k[4][4]=0;      ref_k[4][5]=8192;
        ref_k[4][6]=0;     ref_k[4][7]=8192;   ref_k[4][8]=16384;
        // F5 Diagonal crescente
        ref_k[5][0]=0;     ref_k[5][1]=-8192;  ref_k[5][2]=-16384;
        ref_k[5][3]=8192;  ref_k[5][4]=0;      ref_k[5][5]=-8192;
        ref_k[5][6]=16384; ref_k[5][7]=8192;   ref_k[5][8]=0;
        // F6 Passa-alta horizontal
        ref_k[6][0]=0;     ref_k[6][1]=0;      ref_k[6][2]=0;
        ref_k[6][3]=-8192; ref_k[6][4]=16384;  ref_k[6][5]=-8192;
        ref_k[6][6]=0;     ref_k[6][7]=0;      ref_k[6][8]=0;
        // F7 Passa-tudo central
        ref_k[7][0]=0;     ref_k[7][1]=0;      ref_k[7][2]=0;
        ref_k[7][3]=0;     ref_k[7][4]=16384;  ref_k[7][5]=0;
        ref_k[7][6]=0;     ref_k[7][7]=0;      ref_k[7][8]=0;
    end

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_Weight_ROM");
        $display("========================================================\n");

        // ------------------------------------------------------------------
        // 1) Conferencia exaustiva dos 8 x 9 = 72 pesos convolucionais
        // ------------------------------------------------------------------
        $display("-- Conferencia dos 72 coeficientes dos kernels");
        for (t = 0; t < 9; t = t + 1) begin
            tap_addr = t[3:0];
            #1;
            for (f = 0; f < NF; f = f + 1) begin
                got = conv_w[f*WIDTH +: WIDTH];
                checks = checks + 1;
                if (got !== ref_k[f][t]) begin
                    errors = errors + 1;
                    $display("  [FALHA] F%0d tap%0d: obtido=%0d esperado=%0d",
                             f, t, got, ref_k[f][t]);
                end
            end
        end
        if (errors == 0) $display("  [ OK  ] todos os 72 coeficientes conferem");

        // ------------------------------------------------------------------
        // 2) Propriedade: filtros de borda tem soma zero
        // ------------------------------------------------------------------
        $display("\n-- Propriedade: detectores de borda somam ZERO");
        $display("   (respondem a variacao, nao a nivel constante)");
        for (f = 0; f < NF; f = f + 1) begin
            soma = 0;
            for (t = 0; t < 9; t = t + 1) begin
                tap_addr = t[3:0];
                #1;
                soma = soma + $signed(conv_w[f*WIDTH +: WIDTH]);
            end
            if (f == 3) begin
                // Filtro de media: soma deve ser ~32768 (1.0 em Q1.15)
                checks = checks + 1;
                if (soma < 32760 || soma > 32776) begin
                    errors = errors + 1;
                    $display("  [FALHA] F3 (media): soma=%0d, esperado ~32768", soma);
                end else
                    $display("  [ OK  ] F3 (media 1/9)      soma = %6d  (~1.0: preserva nivel)", soma);
            end else if (f == 7) begin
                checks = checks + 1;
                if (soma !== 16384) begin
                    errors = errors + 1;
                    $display("  [FALHA] F7 (centro): soma=%0d esperado=16384", soma);
                end else
                    $display("  [ OK  ] F7 (passa-tudo)     soma = %6d  (ganho 0.5)", soma);
            end else begin
                checks = checks + 1;
                if (soma !== 0) begin
                    errors = errors + 1;
                    $display("  [FALHA] F%0d: soma=%0d, esperado 0", f, soma);
                end else
                    $display("  [ OK  ] F%0d (detector borda) soma = %6d", f, soma);
            end
        end

        // ------------------------------------------------------------------
        // 3) Camada densa: pesos discriminantes de cada classe
        // ------------------------------------------------------------------
        $display("\n-- Camada densa: peso positivo na feature discriminante");
        // classe 1 (desbalanceamento) deve premiar F1 (Sobel Y)
        dense_addr = 5'd9;  #1;
        checks = checks + 1;
        if (dense_w !== 16'sd16384) begin
            errors = errors + 1;
            $display("  [FALHA] classe1/F1: obtido=%0d esperado=16384", dense_w);
        end else $display("  [ OK  ] classe 1 (desbalanceamento) premia F1 Sobel Y = %0d", dense_w);

        // classe 2 (desalinhamento) deve premiar F0 (Sobel X)
        dense_addr = 5'd16; #1;
        checks = checks + 1;
        if (dense_w !== 16'sd16384) begin
            errors = errors + 1;
            $display("  [FALHA] classe2/F0: obtido=%0d esperado=16384", dense_w);
        end else $display("  [ OK  ] classe 2 (desalinhamento)   premia F0 Sobel X = %0d", dense_w);

        // classe 3 (rolamento) deve premiar F2 (Laplaciano)
        dense_addr = 5'd26; #1;
        checks = checks + 1;
        if (dense_w !== 16'sd16384) begin
            errors = errors + 1;
            $display("  [FALHA] classe3/F2: obtido=%0d esperado=16384", dense_w);
        end else $display("  [ OK  ] classe 3 (rolamento)        premia F2 Laplaciano = %0d", dense_w);

        // classe 0 (normal) deve premiar F3 (media)
        dense_addr = 5'd3;  #1;
        checks = checks + 1;
        if (dense_w !== 16'sd16384) begin
            errors = errors + 1;
            $display("  [FALHA] classe0/F3: obtido=%0d esperado=16384", dense_w);
        end else $display("  [ OK  ] classe 0 (normal)           premia F3 media    = %0d", dense_w);

        // Bias das classes
        $display("\n-- Bias da camada densa");
        for (f = 0; f < 4; f = f + 1) begin
            dense_bias_addr = f[1:0]; #1;
            $display("         bias[classe %0d] = %0d", f, dense_bias);
        end

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

endmodule
