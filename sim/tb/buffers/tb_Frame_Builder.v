// ============================================================================
// Module: tb_Frame_Builder
// Description: Testbench do montador de quadros da FFT.
//
// A entrada e uma RAMPA (amostra n vale n), escolhida de proposito: com ela o
// valor de cada amostra E o seu indice, entao o TB pode afirmar que o quadro f
// contem exatamente as amostras f*32 .. f*32+63. Um sinal "realista" tornaria
// um erro de deslocamento de 32 amostras praticamente invisivel -- e e esse o
// erro que este bloco pode cometer.
//
// Verifica tambem o que importa no sistema: que nenhuma amostra se perde
// quando o bloco baixa in_ready para despejar um quadro.
// ============================================================================

`timescale 1ns / 1ps

module tb_Frame_Builder;

    parameter WIDTH      = 16;
    parameter NFFT       = 64;
    parameter HOP        = 32;
    parameter N_QUADROS  = 32;
    parameter TOTAL      = (N_QUADROS-1)*HOP + NFFT;   // 1056
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                     start;
    reg                     in_valid;
    reg  signed [WIDTH-1:0] in_sample;
    wire                    in_ready, ready, busy, done;
    wire                    out_valid, out_frame_ini, out_frame_fim;
    wire signed [WIDTH-1:0] out_sample;

    // contrapressao na saida (a FFT nem sempre aceita)
    reg       bp_enable;
    reg [1:0] bp_cnt;
    wire      out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    Frame_Builder #(
        .WIDTH(WIDTH), .NFFT(NFFT), .HOP(HOP), .N_QUADROS(N_QUADROS)
    ) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(ready), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_sample(in_sample),
        .out_ready(out_ready), .out_valid(out_valid), .out_sample(out_sample),
        .out_frame_ini(out_frame_ini), .out_frame_fim(out_frame_fim)
    );

    integer success_count = 0;
    integer fail_count    = 0;

    // ---- produtor sincrono da rampa (uma unica fonte para idx_in) ----
    integer idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid <= 1'b0; in_sample <= {WIDTH{1'b0}}; idx_in <= 0;
        end else begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < TOTAL) begin
                    in_valid  <= 1'b1;
                    in_sample <= idx_in + 1;
                end else begin
                    in_valid <= 1'b0;
                end
            end else if (!in_valid && idx_in < TOTAL) begin
                in_valid  <= 1'b1;
                in_sample <= idx_in;
            end
        end
    end

    // Conta os aceites num registrador proprio: ler idx_in depois da janela
    // nao serve, porque o produtor zera o indice quando 'enviando' cai.
    integer n_aceitas;
    always @(posedge clk)
        if (!rst && in_valid && in_ready) n_aceitas = n_aceitas + 1;

    // ---- conferente dos quadros ----
    integer q_atual, p_atual, erros, n_quadros_vistos, erros_ini, erros_fim;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            // posicao esperada dentro do quadro e valor esperado
            if (out_sample !== q_atual*HOP + p_atual) begin
                if (erros < 10)
                    $display("[FAIL] quadro %0d posicao %0d: obtido %0d, esperado %0d",
                             q_atual, p_atual, out_sample, q_atual*HOP + p_atual);
                erros = erros + 1;
            end
            // os marcadores de inicio/fim tem de casar com a posicao
            if (out_frame_ini !== (p_atual == 0))         erros_ini = erros_ini + 1;
            if (out_frame_fim !== (p_atual == NFFT-1))    erros_fim = erros_fim + 1;

            if (p_atual == NFFT-1) begin
                p_atual = 0;
                q_atual = q_atual + 1;
                n_quadros_vistos = n_quadros_vistos + 1;
            end else begin
                p_atual = p_atual + 1;
            end
        end
    end

    integer rodada, ciclos;

    initial begin
        $display("======================================================================");
        $display("  MONTADOR DE QUADROS DA FFT -- 64 amostras, salto 32, 32 quadros     ");
        $display("======================================================================");

        rst = 1; start = 0; enviando = 0; bp_enable = 0; bp_cnt = 0;
        erros = 0; erros_ini = 0; erros_fim = 0; n_aceitas = 0;
        q_atual = 0; p_atual = 0; n_quadros_vistos = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reset: ready=1, busy=0");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Reset: ready=%b busy=%b", ready, busy);
        end

        // duas janelas: a segunda prova que o bloco reinicia limpo (os
        // ponteiros do circular tem de voltar ao zero, nao continuar de onde
        // pararam)
        for (rodada = 0; rodada < 2; rodada = rodada + 1) begin
            bp_enable = rodada;          // a 2a janela roda com contrapressao
            q_atual = 0; p_atual = 0; n_quadros_vistos = 0; n_aceitas = 0;
            enviando = 1'b0;

            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            enviando = 1'b1;

            ciclos = 0;
            while (!done && ciclos < 200000) begin
                @(posedge clk);
                ciclos = ciclos + 1;
            end
            enviando = 1'b0;
            repeat (3) @(negedge clk);

            $display("   janela %0d (%s): %0d quadros, %0d amostras aceitas, %0d ciclos",
                     rodada, bp_enable ? "com contrapressao" : "sem contrapressao",
                     n_quadros_vistos, n_aceitas, ciclos);

            if (n_quadros_vistos === N_QUADROS) begin
                success_count = success_count + 1;
                $display("[PASS] janela %0d: %0d quadros entregues", rodada, N_QUADROS);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] janela %0d: %0d quadros, esperado %0d",
                         rodada, n_quadros_vistos, N_QUADROS);
            end
        end

        // ---- nenhuma amostra perdida ou repetida ----
        if (n_aceitas === TOTAL) begin
            success_count = success_count + 1;
            $display("[PASS] Consumiu exatamente %0d amostras (nada perdido na pausa)",
                     TOTAL);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Consumiu %0d amostras, esperado %0d", n_aceitas, TOTAL);
        end

        if (erros == 0) begin
            success_count = success_count + 1;
            $display("[PASS] Sobreposicao correta: quadro f = amostras f*32 .. f*32+63");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] %0d amostras fora de posicao", erros);
        end

        if (erros_ini == 0 && erros_fim == 0) begin
            success_count = success_count + 1;
            $display("[PASS] Marcadores de inicio/fim de quadro alinhados");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Marcadores: %0d erros de inicio, %0d de fim",
                     erros_ini, erros_fim);
        end

        if (ready === 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] Voltou a IDLE, pronto para nova janela");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO MONTADOR DE QUADROS PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO MONTADOR DE QUADROS.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #100_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
