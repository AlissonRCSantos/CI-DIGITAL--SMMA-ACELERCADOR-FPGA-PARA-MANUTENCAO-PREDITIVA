// ============================================================================
// Testbench: tb_CNN_Top
// Teste de SISTEMA do acelerador CNN completo, com ESPECTROGRAMAS REAIS.
//
// As imagens vem do conjunto de TESTE do dataset de vibracao (Jung et al.,
// 2023): 2 espectrogramas 32x32 de cada classe, gerados pelo mesmo caminho
// FFT -> espectrograma especificado em python/smma/espectrograma.py.
// Arquivos (gerados por python/scripts/05_exportar_rtl.py):
//   vetores/top_imagens.hex  : N_IMG x 1024 pixels Q1.15 (ordem raster,
//                              linha = bin de frequencia, coluna = tempo)
//   vetores/top_esperado.hex : por imagem, 14 palavras =
//                              8 features, 4 scores, classe esperada
//                              (golden model bit-exato), classe REAL
//   vetores/top_origem.txt   : de qual arquivo/condicao veio cada imagem
//
// SAIDA: o que o HARDWARE respondeu para cada imagem e gravado em
//   sim_out/top_saida_hw.txt  (ou top_saida_hw.txt, se sim_out/ nao existir)
// e o script gerar_png_espectrogramas.py transforma isso em figuras PNG na
// pasta sim/golden/espectrogramas_teste/ (python sim/golden/gerar_png_espectrogramas.py).
//
// O teste PASSA quando o hardware reproduz o golden model bit a bit
// (features, scores e classe). A comparacao com a classe REAL e informativa:
// mostra se a rede treinada acertou o diagnostico.
//
// Alem da funcionalidade, o teste mede:
//   * o numero de ciclos por imagem  (requisito: 1 janela a cada 10 ms)
//   * o reuso do acelerador em quadros consecutivos, sem reset entre eles
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Top;

    localparam WIDTH  = 16;
    localparam CLK_NS = 20;         // 50 MHz
    localparam NPIX   = 1024;       // 32 x 32
    localparam N_IMG  = 8;          // 2 imagens por classe
    localparam NESP   = 14;         // palavras esperadas por imagem

    reg                clk = 0, rst = 1;
    reg                start = 0, enable = 1, in_valid = 0;
    reg  signed [15:0] in_pixel = 0;
    wire               in_ready, busy, ready, done, valid_out;
    wire [1:0]         out_class;
    wire [63:0]        out_scores;
    wire [127:0]       out_features;

    integer errors = 0, checks = 0;
    integer i, j, k, n, ch, acertos = 0;
    integer fd;                    // arquivo com a saida do hardware
    integer t_start, t_end, ciclos;
    reg signed [15:0] img [0:NPIX-1];
    reg signed [15:0] todas [0:N_IMG*NPIX-1];
    reg signed [15:0] esp   [0:N_IMG*NESP-1];

    // Valores esperados (gerados pelo modelo de referencia em ponto fixo)
    reg signed [15:0] efe [0:7];
    reg signed [15:0] esc [0:3];
    reg [1:0]         ecl, real_cl;

    reg [8*16-1:0] nome;

    function [8*16-1:0] nome_classe(input [1:0] c);
        case (c)
            2'd0: nome_classe = "NORMAL";
            2'd1: nome_classe = "DESBALANCEAMENTO";
            2'd2: nome_classe = "DESALINHAMENTO";
            default: nome_classe = "ROLAMENTO";
        endcase
    endfunction

    always #(CLK_NS/2) clk = ~clk;

    CNN_Top dut (
        .clk(clk), .rst(rst), .start(start), .enable(enable),
        .in_valid(in_valid), .in_ready(in_ready),
        .busy(busy), .ready(ready), .done(done), .valid_out(valid_out),
        .in_pixel(in_pixel),
        .out_class(out_class), .out_scores(out_scores), .out_features(out_features)
    );

    // ------------------------------------------------------------------------
    // Copia a imagem n e seus valores esperados
    // ------------------------------------------------------------------------
    task load_img(input integer p);
        begin
            for (i = 0; i < NPIX; i = i + 1) img[i] = todas[p*NPIX + i];
            for (ch = 0; ch < 8; ch = ch + 1) efe[ch] = esp[p*NESP + ch];
            for (ch = 0; ch < 4; ch = ch + 1) esc[ch] = esp[p*NESP + 8 + ch];
            ecl     = esp[p*NESP + 12];
            real_cl = esp[p*NESP + 13];
            nome    = nome_classe(ecl);
        end
    endtask

    // ------------------------------------------------------------------------
    // Entrega uma imagem completa respeitando o handshake in_valid / in_ready
    // ------------------------------------------------------------------------
    task run_frame;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            t_start  = $time;
            k        = 0;
            in_valid = 1'b1;
            in_pixel = img[0];
            while (k < NPIX) begin
                @(negedge clk);
                if (in_ready) begin
                    @(posedge clk); #1;              // pixel consumido nesta borda
                    k = k + 1;
                    in_pixel = (k < NPIX) ? img[k] : 16'sd0;
                end else begin
                    @(posedge clk);                  // backpressure: segura o pixel
                end
            end
            @(negedge clk); in_valid = 1'b0;
            wait (valid_out === 1'b1);
            t_end  = $time;
            ciclos = (t_end - t_start) / CLK_NS;
            @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------------
    // Confere features, scores e classe
    // ------------------------------------------------------------------------
    task check_frame;
        begin
            for (ch = 0; ch < 8; ch = ch + 1) begin
                checks = checks + 1;
                if ($signed(out_features[ch*16 +: 16]) !== efe[ch]) begin
                    errors = errors + 1;
                    $display("  [FALHA] feature%0d: obtido=%0d esperado=%0d", ch,
                             $signed(out_features[ch*16 +: 16]), efe[ch]);
                end
            end
            for (ch = 0; ch < 4; ch = ch + 1) begin
                checks = checks + 1;
                if ($signed(out_scores[ch*16 +: 16]) !== esc[ch]) begin
                    errors = errors + 1;
                    $display("  [FALHA] score%0d: obtido=%0d esperado=%0d", ch,
                             $signed(out_scores[ch*16 +: 16]), esc[ch]);
                end
            end
            checks = checks + 1;
            if (out_class !== ecl) begin
                errors = errors + 1;
                $display("  [FALHA] CLASSE: obtido=%0d esperado=%0d", out_class, ecl);
            end else
                $display("  [ OK  ] hardware = golden: classe %0d (%0s)", out_class, nome);
            if (out_class == real_cl) acertos = acertos + 1;
            // registra a resposta do HARDWARE: n classe score0..3 feature0..7 ciclos
            if (fd != 0)
                $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    n, out_class,
                    $signed(out_scores[0*16 +: 16]), $signed(out_scores[1*16 +: 16]),
                    $signed(out_scores[2*16 +: 16]), $signed(out_scores[3*16 +: 16]),
                    $signed(out_features[0*16 +: 16]), $signed(out_features[1*16 +: 16]),
                    $signed(out_features[2*16 +: 16]), $signed(out_features[3*16 +: 16]),
                    $signed(out_features[4*16 +: 16]), $signed(out_features[5*16 +: 16]),
                    $signed(out_features[6*16 +: 16]), $signed(out_features[7*16 +: 16]),
                    ciclos);
            $display("         diagnostico: classe real = %0s -> %0s", nome_classe(real_cl),
                     (out_class == real_cl) ? "ACERTOU" : "ERROU");

            $display("         features = [%0d %0d %0d %0d %0d %0d %0d %0d]",
                $signed(out_features[0*16 +: 16]), $signed(out_features[1*16 +: 16]),
                $signed(out_features[2*16 +: 16]), $signed(out_features[3*16 +: 16]),
                $signed(out_features[4*16 +: 16]), $signed(out_features[5*16 +: 16]),
                $signed(out_features[6*16 +: 16]), $signed(out_features[7*16 +: 16]));
            $display("         scores   = [%0d %0d %0d %0d]",
                $signed(out_scores[0*16 +: 16]), $signed(out_scores[1*16 +: 16]),
                $signed(out_scores[2*16 +: 16]), $signed(out_scores[3*16 +: 16]));
            $display("         ciclos   = %0d  (%0d us @ 50 MHz)", ciclos, (ciclos*20)/1000);
        end
    endtask

    initial begin
        $readmemh("vetores/top_imagens.hex", todas);
        $readmemh("vetores/top_esperado.hex", esp);
        fd = $fopen("sim_out/top_saida_hw.txt", "w");
        if (fd == 0) fd = $fopen("top_saida_hw.txt", "w");
        if (fd != 0)
            $fdisplay(fd, "# n classe_hw score0 score1 score2 score3 feat0 feat1 feat2 feat3 feat4 feat5 feat6 feat7 ciclos");
        $display("================================================================");
        $display(" TESTBENCH DE SISTEMA: CNN_Top (espectrogramas reais)");
        $display(" Espectrograma 32x32 -> conv 3x3 x8 + ReLU -> pool 2x2 ->");
        $display(" GAP -> densa 8x4 -> argmax   (pesos treinados)");
        $display("================================================================\n");

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
        checks = checks + 1;
        if (ready !== 1'b1) begin
            errors = errors + 1;
            $display("  [FALHA] ready deveria ser 1 apos o reset");
        end else
            $display("-- Apos reset: ready=1, aguardando imagem\n");

        // ==================================================================
        // N_IMG espectrogramas reais, processados em sequencia sem reset
        // ==================================================================
        for (n = 0; n < N_IMG; n = n + 1) begin
            load_img(n);
            $display("-- Imagem %0d  (ver vetores/top_origem.txt)", n);
            run_frame;
            check_frame;
            $display("");
        end
        $display("-- Diagnostico da rede treinada nestas %0d imagens: %0d acertos", N_IMG, acertos);

        // ==================================================================
        // Requisito temporal do enunciado
        // ==================================================================
        $display("\n-- Requisito temporal: 1 janela processada a cada 10 ms");
        checks = checks + 1;
        if (ciclos > 500000) begin
            errors = errors + 1;
            $display("  [FALHA] %0d ciclos = %0d us excede o limite de 10 ms", ciclos, (ciclos*20)/1000);
        end else
            $display("  [ OK  ] %0d ciclos = %0d us  (folga de %0dx sobre os 10 ms)",
                     ciclos, (ciclos*20)/1000, 10000/((ciclos*20)/1000));

        // ==================================================================
        // Reuso: quatro quadros processados em sequencia, sem reset
        // ==================================================================
        $display("\n-- Reuso do acelerador");
        checks = checks + 1;
        if (ready !== 1'b1) begin
            errors = errors + 1;
            $display("  [FALHA] acelerador nao voltou a ficar pronto");
        end else
            $display("  [ OK  ] %0d quadros consecutivos sem reset; ready=1 ao final", N_IMG);

        $display("\n================================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("================================================================");
        if (fd != 0) $fclose(fd);
        $finish;
    end

    initial begin #50000000; $display("TIMEOUT"); $finish; end

endmodule
