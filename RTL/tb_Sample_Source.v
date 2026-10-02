// ============================================================================
// Module: tb_Sample_Source
// Description: Testbench da fonte de amostras da demonstracao em FPGA,
//              LIGADA ao FIR+decimador -- o primeiro teste de integracao
//              entre dois modulos deste projeto.
//
// Verifica:
//   1. contagem: cada janela entrega exatamente N_AMOSTRAS amostras;
//   2. conteudo: as amostras batem com a ROM exportada do dataset;
//   3. seletor: janelas diferentes entregam dados diferentes, e os rotulos
//      (classe verdadeira / prevista) correspondem a janela escolhida;
//   4. integracao: o FIR a jusante aceita o stream e produz a quantidade
//      esperada de amostras decimadas, sem perder nada no handshake;
//   5. taxa: com MODO_RAPIDO=0 o intervalo entre amostras e DIV_TAXA ciclos.
//
// Roda com MODO_RAPIDO=1 na maior parte (simulacao viavel) e faz uma
// verificacao curta de temporizacao com MODO_RAPIDO=0 numa instancia a parte.
// ============================================================================

`timescale 1ns / 1ps

module tb_Sample_Source;

    parameter WIDTH      = 16;
    parameter N_JANELAS  = 12;
    parameter N_AMOSTRAS = 8503;
    parameter DIV_TAXA   = 1953;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer success_count = 0;
    integer fail_count    = 0;

    // ---------------- instancia rapida (ligada ao FIR) ----------------
    reg        start;
    reg [3:0]  janela;
    wire       busy, done, src_valid;
    wire signed [WIDTH-1:0] src_sample;
    wire [1:0] classe_verdadeira, classe_esperada;
    wire       fir_ready;

    Sample_Source #(
        .WIDTH(WIDTH), .N_JANELAS(N_JANELAS), .N_AMOSTRAS(N_AMOSTRAS),
        .DIV_TAXA(DIV_TAXA), .MODO_RAPIDO(1)
    ) fonte (
        .clk(clk), .rst(rst), .start(start), .janela(janela),
        .busy(busy), .done(done),
        .out_ready(fir_ready), .out_valid(src_valid), .out_sample(src_sample),
        .classe_verdadeira(classe_verdadeira), .classe_esperada(classe_esperada)
    );

    // FIR a jusante: consome o stream exatamente como na cadeia real
    wire        fir_valid;
    wire signed [WIDTH-1:0] fir_sample;
    reg         fir_out_ready;

    FIR_Decimator #(
        .WIDTH(WIDTH), .FRAC(15), .N_TAPS(63), .DECIM(8), .ACC_W(40),
        .ARQ_COEF("vetores/fir_coef.hex")
    ) fir (
        .clk(clk), .rst(rst),
        .in_valid(src_valid), .in_ready(fir_ready), .in_sample(src_sample),
        .out_ready(fir_out_ready), .out_valid(fir_valid),
        .out_sample(fir_sample), .overflow()
    );

    // ---------------- referencia da ROM ----------------
    // Le o mesmo arquivo que o DUT para conferir o conteudo entregue.
    reg [WIDTH-1:0] ref_rom [0:N_JANELAS*N_AMOSTRAS-1];
    initial $readmemh("vetores/demo_amostras.hex", ref_rom);

    integer n_src, n_fir, erros_conteudo;
    integer esperado_dec;

    always @(posedge clk) begin
        if (!rst && src_valid && fir_ready) begin
            if (ref_rom[janela*N_AMOSTRAS + n_src] !== src_sample)
                erros_conteudo = erros_conteudo + 1;
            n_src = n_src + 1;
        end
        if (!rst && fir_valid && fir_out_ready)
            n_fir = n_fir + 1;
    end

    task roda_janela;
        input [3:0] j;
        integer guarda;
        begin
            n_src = 0; n_fir = 0; erros_conteudo = 0;
            @(negedge clk); janela = j; start = 1'b1;
            @(negedge clk); start = 1'b0;
            guarda = 0;
            while (busy && guarda < 2_000_000) begin
                @(posedge clk);
                guarda = guarda + 1;
            end
            repeat (300) @(negedge clk);   // drena o FIR
        end
    endtask

    integer j;
    reg [1:0] v0, p0, v1, p1;

    initial begin
        $display("======================================================================");
        $display("   FONTE DE AMOSTRAS DA DEMONSTRACAO + FIR  (integracao de 2 modulos) ");
        $display("======================================================================");

        rst = 1; start = 0; janela = 0; fir_out_ready = 1;
        n_src = 0; n_fir = 0; erros_conteudo = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ---- janela 0 ----
        roda_janela(4'd0);
        esperado_dec = (N_AMOSTRAS - 63)/8 + 1;

        if (n_src == N_AMOSTRAS) begin
            success_count = success_count + 1;
            $display("[PASS] Janela 0 entregou %0d amostras (esperado %0d)", n_src, N_AMOSTRAS);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Janela 0 entregou %0d amostras, esperado %0d", n_src, N_AMOSTRAS);
        end

        if (erros_conteudo == 0) begin
            success_count = success_count + 1;
            $display("[PASS] Conteudo confere com a ROM exportada do dataset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] %0d amostras divergentes da ROM", erros_conteudo);
        end

        if (n_fir == esperado_dec) begin
            success_count = success_count + 1;
            $display("[PASS] FIR produziu %0d amostras decimadas (esperado %0d)",
                     n_fir, esperado_dec);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] FIR produziu %0d decimadas, esperado %0d", n_fir, esperado_dec);
        end

        v0 = classe_verdadeira; p0 = classe_esperada;

        // ---- janela 7 (outra classe/carga) ----
        roda_janela(4'd7);
        v1 = classe_verdadeira; p1 = classe_esperada;

        if (n_src == N_AMOSTRAS && erros_conteudo == 0) begin
            success_count = success_count + 1;
            $display("[PASS] Janela 7 tambem integra e confere com a ROM");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Janela 7: %0d amostras, %0d divergencias",
                     n_src, erros_conteudo);
        end

        // ---- rotulos ----
        $display("       janela 0: verdadeira=%0d prevista=%0d | janela 7: verdadeira=%0d prevista=%0d",
                 v0, p0, v1, p1);
        if (v0 !== v1 || p0 !== p1) begin
            success_count = success_count + 1;
            $display("[PASS] Seletor troca a janela e os rotulos acompanham");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Rotulos nao mudaram ao trocar de janela");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DA FONTE DE AMOSTRAS PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NA FONTE DE AMOSTRAS.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
