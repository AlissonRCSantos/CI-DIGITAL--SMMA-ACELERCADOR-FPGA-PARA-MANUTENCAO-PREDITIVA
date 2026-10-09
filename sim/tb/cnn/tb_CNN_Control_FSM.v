// ============================================================================
// Testbench: tb_CNN_Control_FSM
// Verifica a unidade de controle global ISOLADA, com um datapath falso
// (modelo comportamental simples) conectado no lugar dos modulos reais.
//
// O que e verificado:
//   1) Estado de repouso: ready=1, busy=0 antes de qualquer start
//   2) start -> busy=1, ready=0
//   3) BACKPRESSURE: com conv_ready=0 a varredura CONGELA (push_en=0),
//      mesmo com pixel valido -> e isso que impede sobrescrita de dados
//   4) FALTA DE DADO: com in_valid=0 em um passo que precisa de pixel,
//      push_en=0 -> e isso que impede perda de dado
//   5) Nos passos de PADDING (need_pixel=0) a varredura avanca sozinha,
//      sem exigir pixel do host
//   6) Transicao para DRAIN no ultimo passo, e para DENSE apos NUM_POOL
//      resultados do pooling
//   7) dense_run e valid_out sao pulsos de EXATAMENTE 1 ciclo
//   8) Ao final: done=1, ready=1 e retorno ao repouso
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Control_FSM;

    localparam NUM_POOL = 4;   // reduzido para manter o teste curto

    reg  clk = 0, rst = 1;
    reg  start = 0, enable = 1, in_valid = 0;
    wire in_ready, busy, ready, done, valid_out;

    reg  need_pixel = 1, last_push = 0, conv_ready = 1;
    reg  pool_out_valid = 0, dense_done = 0;
    wire frame_start, push_en, dense_run;

    integer errors = 0, checks = 0;
    integer n_frame_start = 0, n_dense_run = 0, n_valid_out = 0;
    integer i;

    always #10 clk = ~clk;

    CNN_Control_FSM #(.NUM_POOL(NUM_POOL)) dut (
        .clk(clk), .rst(rst),
        .start(start), .enable(enable), .in_valid(in_valid), .in_ready(in_ready),
        .busy(busy), .ready(ready), .done(done), .valid_out(valid_out),
        .need_pixel(need_pixel), .last_push(last_push), .conv_ready(conv_ready),
        .pool_out_valid(pool_out_valid), .dense_done(dense_done),
        .frame_start(frame_start), .push_en(push_en), .dense_run(dense_run)
    );

    // Conta a largura dos pulsos (devem ser de exatamente 1 ciclo)
    always @(negedge clk) begin
        if (frame_start) n_frame_start = n_frame_start + 1;
        if (dense_run)   n_dense_run   = n_dense_run   + 1;
        if (valid_out)   n_valid_out   = n_valid_out   + 1;
    end

    task chk(input [8*52-1:0] nome, input cond);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FALHA] %0s", nome);
            end else
                $display("  [ OK  ] %0s", nome);
        end
    endtask

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_Control_FSM (handshake e sequenciamento)");
        $display("========================================================\n");

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ------------------------------------------------------------------
        $display("-- 1. Repouso");
        chk("ready=1 e busy=0 antes do start", (ready === 1'b1) && (busy === 1'b0));
        chk("push_en=0 em repouso",            (push_en === 1'b0));

        // ------------------------------------------------------------------
        $display("\n-- 2. Disparo (start)");
        in_valid = 1'b1;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        chk("busy=1 e ready=0 apos start", (busy === 1'b1) && (ready === 1'b0));
        chk("frame_start pulsou 1 vez",    (n_frame_start === 1));

        // ------------------------------------------------------------------
        $display("\n-- 3. Fluxo normal: pixel valido e convolucao livre");
        chk("push_en=1 (avanca a varredura)", (push_en === 1'b1));
        chk("in_ready=1 (consome pixel)",     (in_ready === 1'b1));

        // ------------------------------------------------------------------
        $display("\n-- 4. BACKPRESSURE: convolucao ocupada (conv_ready=0)");
        conv_ready = 1'b0;
        #1;
        chk("push_en=0 com conv_ready=0 (nao sobrescreve)", (push_en === 1'b0));
        chk("in_ready=0 com conv_ready=0 (host segura o pixel)", (in_ready === 1'b0));
        conv_ready = 1'b1;
        #1;
        chk("push_en volta a 1 quando conv libera", (push_en === 1'b1));

        // ------------------------------------------------------------------
        $display("\n-- 5. FALTA DE DADO: host sem pixel valido (in_valid=0)");
        in_valid = 1'b0;
        #1;
        chk("push_en=0 sem pixel valido (nao perde dado)", (push_en === 1'b0));
        in_valid = 1'b1;
        #1;

        // ------------------------------------------------------------------
        $display("\n-- 6. PADDING: passo que nao consome pixel (need_pixel=0)");
        need_pixel = 1'b0;
        in_valid   = 1'b0;         // host nao fornece nada
        #1;
        chk("push_en=1 mesmo sem pixel (padding e automatico)", (push_en === 1'b1));
        chk("in_ready=0 no passo de padding",                   (in_ready === 1'b0));
        need_pixel = 1'b1;
        in_valid   = 1'b1;
        #1;

        // ------------------------------------------------------------------
        $display("\n-- 7. Fim da varredura -> DRAIN");
        @(negedge clk);
        last_push = 1'b1;
        @(negedge clk);            // este ciclo tem push_en && last_push
        last_push = 1'b0;
        @(negedge clk);
        chk("busy continua 1 durante o DRAIN", (busy === 1'b1));
        chk("push_en=0 apos o ultimo passo",   (push_en === 1'b0));

        // ------------------------------------------------------------------
        $display("\n-- 8. Pooling entrega NUM_POOL resultados -> DENSE");
        for (i = 0; i < NUM_POOL; i = i + 1) begin
            @(negedge clk); pool_out_valid = 1'b1;
        end
        @(negedge clk); pool_out_valid = 1'b0;
        @(negedge clk);
        chk("dense_run pulsou exatamente 1 vez", (n_dense_run === 1));

        // ------------------------------------------------------------------
        $display("\n-- 9. Classificador termina -> FINISH");
        @(negedge clk); dense_done = 1'b1;
        @(negedge clk); dense_done = 1'b0;
        @(negedge clk); #1;   // deixa o monitor de pulsos atualizar
        chk("valid_out em nivel alto no ciclo de termino", (valid_out === 1'b1));
        chk("valid_out pulsou exatamente 1 vez", (n_valid_out === 1));
        chk("done=1 ao terminar",                (done  === 1'b1));
        chk("ready=1 (pronto para nova imagem)", (ready === 1'b1));
        chk("busy=0 ao terminar",                (busy  === 1'b0));

        // ------------------------------------------------------------------
        $display("\n-- 10. Pulsos nao ficam presos em nivel alto");
        repeat (5) @(negedge clk);
        chk("frame_start continua com 1 pulso apenas", (n_frame_start === 1));
        chk("dense_run continua com 1 pulso apenas",   (n_dense_run   === 1));
        chk("valid_out continua com 1 pulso apenas",   (n_valid_out   === 1));

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
