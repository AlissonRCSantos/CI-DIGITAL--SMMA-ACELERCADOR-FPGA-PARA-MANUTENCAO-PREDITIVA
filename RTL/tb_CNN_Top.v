// ============================================================================
// Testbench: tb_CNN_Top
// Teste de SISTEMA do acelerador CNN completo.
//
// Injeta quatro espectrogramas sinteticos 32x32, cada um representando a
// assinatura tipica de uma condicao do motor, e confere a classe predita, as
// 8 features do GAP e os 4 scores contra o modelo de referencia em ponto fixo.
//
//   PADRAO 0 - campo uniforme          -> energia distribuida, sem estrutura
//                                         => OPERACAO NORMAL         (classe 0)
//   PADRAO 1 - faixas HORIZONTAIS      -> harmonicas fixas em frequencia
//                                         => DESBALANCEAMENTO        (classe 1)
//   PADRAO 2 - faixas VERTICAIS        -> banda larga pulsando no tempo
//                                         => DESALINHAMENTO          (classe 2)
//   PADRAO 3 - impulsos isolados       -> transientes de impacto
//                                         => DESGASTE DE ROLAMENTO   (classe 3)
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

    reg                clk = 0, rst = 1;
    reg                start = 0, enable = 1, in_valid = 0;
    reg  signed [15:0] in_pixel = 0;
    wire               in_ready, busy, ready, done, valid_out;
    wire [1:0]         out_class;
    wire [63:0]        out_scores;
    wire [127:0]       out_features;

    integer errors = 0, checks = 0;
    integer i, j, k, pat, ch;
    integer t_start, t_end, ciclos;
    reg signed [15:0] img [0:NPIX-1];

    // Valores esperados (gerados pelo modelo de referencia em ponto fixo)
    reg signed [15:0] efe [0:7];
    reg signed [15:0] esc [0:3];
    reg [1:0]         ecl;

    reg [8*26-1:0] nome;

    always #(CLK_NS/2) clk = ~clk;

    CNN_Top dut (
        .clk(clk), .rst(rst), .start(start), .enable(enable),
        .in_valid(in_valid), .in_ready(in_ready),
        .busy(busy), .ready(ready), .done(done), .valid_out(valid_out),
        .in_pixel(in_pixel),
        .out_class(out_class), .out_scores(out_scores), .out_features(out_features)
    );

    // ------------------------------------------------------------------------
    // Gera o espectrograma sintetico de cada condicao
    // ------------------------------------------------------------------------
    task make_img(input integer p);
        begin
            for (i = 0; i < 32; i = i + 1)
                for (j = 0; j < 32; j = j + 1) begin
                    case (p)
                      0: img[i*32+j] = 16'sd8192;                                  // uniforme
                      1: img[i*32+j] = ((i%4) < 2)              ? 16'sd16384 : 16'sd0; // horizontal
                      2: img[i*32+j] = ((j%4) < 2)              ? 16'sd16384 : 16'sd0; // vertical
                      3: img[i*32+j] = ((i%4)==0 && (j%4)==0)   ? 16'sd32767 : 16'sd0; // impulsos
                    endcase
                end
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
                $display("  [ OK  ] classe predita = %0d  (%0s)", out_class, nome);

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
        $display("================================================================");
        $display(" TESTBENCH DE SISTEMA: CNN_Top");
        $display(" Espectrograma 32x32 -> conv 3x3 x8 + ReLU -> pool 2x2 ->");
        $display(" GAP -> densa 8x4 -> argmax");
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
        // PADRAO 0 - OPERACAO NORMAL
        // ==================================================================
        $display("-- PADRAO 0: campo uniforme (energia distribuida)");
        nome = "OPERACAO NORMAL";
        efe[0]=512;  efe[1]=768;  efe[2]=196;  efe[3]=8704;
        efe[4]=690;  efe[5]=1776; efe[6]=128;  efe[7]=6144;
        esc[0]=3550; esc[1]=-546; esc[2]=-802; esc[3]=-1502;
        ecl = 2'd0;
        make_img(0); run_frame; check_frame;

        // ==================================================================
        // PADRAO 1 - DESBALANCEAMENTO
        // ==================================================================
        $display("\n-- PADRAO 1: faixas HORIZONTAIS (harmonicas fixas)");
        nome = "DESBALANCEAMENTO";
        efe[0]=512;   efe[1]=15616; efe[2]=1024;  efe[3]=8705;
        efe[4]=11168; efe[5]=12672; efe[6]=192;   efe[7]=6144;
        esc[0]=-4319; esc[1]=6432;  esc[2]=-8672; esc[3]=-8480;
        ecl = 2'd1;
        make_img(1); run_frame; check_frame;

        // ==================================================================
        // PADRAO 2 - DESALINHAMENTO
        // ==================================================================
        $display("\n-- PADRAO 2: faixas VERTICAIS (banda larga pulsante)");
        nome = "DESALINHAMENTO";
        efe[0]=15360; efe[1]=768;   efe[2]=1024; efe[3]=8705;
        efe[4]=11168; efe[5]=13440; efe[6]=1536; efe[7]=6144;
        esc[0]=-4991; esc[1]=-9088; esc[2]=5504; esc[3]=-7808;
        ecl = 2'd2;
        make_img(2); run_frame; check_frame;

        // ==================================================================
        // PADRAO 3 - DESGASTE DE ROLAMENTO
        // ==================================================================
        $display("\n-- PADRAO 3: impulsos isolados (transientes de impacto)");
        nome = "DESGASTE ROLAMENTO";
        efe[0]=5152;  efe[1]=5408;  efe[2]=4032;  efe[3]=3712;
        efe[4]=6398;  efe[5]=6656;  efe[6]=3840;  efe[7]=6144;
        esc[0]=-7360; esc[1]=-4320; esc[2]=-4576; esc[3]=-2368;
        ecl = 2'd3;
        make_img(3); run_frame; check_frame;

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
            $display("  [ OK  ] 4 quadros consecutivos sem reset; ready=1 ao final");

        $display("\n================================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("================================================================");
        $finish;
    end

    initial begin #20000000; $display("TIMEOUT"); $finish; end

endmodule
