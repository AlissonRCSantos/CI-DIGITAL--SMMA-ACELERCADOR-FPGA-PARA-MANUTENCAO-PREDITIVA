// ============================================================================
// Module: tb_Feature_Temporal
// Description: Testbench do extrator das 4 caracteristicas temporais.
//
// Os vetores sao 6 janelas REAIS da particao de teste do dataset, cobrindo
// as 4 classes e as 3 cargas (0/2/4 Nm). Cada caso traz as 1056 amostras
// decimadas que entram e os 4 valores que o modelo Python produz.
//
// A comparacao e BIT A BIT. Nao e rigor gratuito: os limiares da arvore
// foram aprendidos sobre estes numeros, e o LMS e RECURSIVO -- um unico LSB
// de diferenca no erro contamina os pesos e divergindo ao longo de 1056
// amostras. Uma verificacao por tolerancia esconderia exatamente o tipo de
// bug que importa aqui.
// ============================================================================

`timescale 1ns / 1ps

module tb_Feature_Temporal;

    parameter WIDTH      = 16;
    parameter N_FEAT     = 4;
    parameter L          = 1056;      // amostras por janela
    parameter MAX_CASOS  = 6;      // casos em vetores/temp_teste.hex
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                      start;
    reg                      in_valid, in_last;
    reg  signed [WIDTH-1:0]  in_sample;
    wire                     in_ready, ready, busy, done, out_valid;
    wire signed [WIDTH-1:0]  out_feature;

    // contrapressao independente na saida
    reg       bp_enable;
    reg [1:0] bp_cnt;
    wire      out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    Feature_Temporal #(
        .WIDTH(WIDTH), .FRAC(15), .N_TAPS(8), .MU_SHIFT(3),
        .N_LAGS(3), .ACC_W(48)
    ) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(ready), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_sample(in_sample), .in_last(in_last),
        .out_ready(out_ready), .out_valid(out_valid), .out_feature(out_feature)
    );

    // arquivo: [n_casos][Lcheck][caso 0: L amostras + 4 features][caso 1: ...]
    reg [15:0] arq [0:2 + MAX_CASOS*(L + N_FEAT) - 1];
    integer n_casos, l_arq;

    integer success_count = 0;
    integer fail_count    = 0;

    // ---- produtor sincrono das amostras ----
    // 'idx_in' e escrito SO por este processo; zera-lo no bloco initial criaria
    // duas fontes para o mesmo registrador (corrida entre bloqueante e
    // nao-bloqueante), bug que ja apareceu no TB do FIR.
    integer base_in, idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid  <= 1'b0;
            in_last   <= 1'b0;
            in_sample <= {WIDTH{1'b0}};
            idx_in    <= 0;
        end else begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < L) begin
                    in_valid  <= 1'b1;
                    in_sample <= arq[base_in + idx_in + 1];
                    in_last   <= (idx_in + 1 == L - 1);
                end else begin
                    in_valid <= 1'b0;
                    in_last  <= 1'b0;
                end
            end else if (!in_valid && idx_in < L) begin
                in_valid  <= 1'b1;
                in_sample <= arq[base_in + idx_in];
                in_last   <= (idx_in == L - 1);
            end
        end
    end

    // ---- coletor das features ----
    reg signed [WIDTH-1:0] obtido [0:N_FEAT-1];
    integer n_out;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (n_out < N_FEAT) obtido[n_out] = out_feature;
            n_out = n_out + 1;
        end
    end

    integer c, f, base, erros, erros_caso, ciclos, ciclos_max;

    initial begin
        $display("======================================================================");
        $display("  EXTRATOR DAS 4 FEATURES TEMPORAIS -- janelas reais do dataset       ");
        $display("    r_lms (preditor LMS 8 taps, mu=2^-3) + rho1..rho3                 ");
        $display("======================================================================");

        $readmemh("vetores/temp_teste.hex", arq);
        n_casos = arq[0];
        l_arq   = arq[1];
        $display("casos: %0d janelas  |  %0d amostras cada\n", n_casos, l_arq);

        if (l_arq !== L) begin
            $display("[FAIL] O arquivo traz L=%0d mas o TB espera %0d", l_arq, L);
            fail_count = fail_count + 1;
        end

        rst = 1; start = 0; enviando = 0; n_out = 0;
        bp_enable = 0; bp_cnt = 0; erros = 0; ciclos_max = 0;
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

        for (c = 0; c < n_casos; c = c + 1) begin
            base     = 2 + c*(L + N_FEAT);
            base_in  = base;
            n_out    = 0;
            enviando = 1'b0;
            bp_enable = (c % 2);           // metade dos casos com contrapressao

            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            enviando = 1'b1;

            ciclos = 0;
            while (n_out < N_FEAT && ciclos < 500000) begin
                @(posedge clk);
                ciclos = ciclos + 1;
            end
            if (ciclos > ciclos_max) ciclos_max = ciclos;
            enviando = 1'b0;
            repeat (5) @(negedge clk);

            erros_caso = 0;
            for (f = 0; f < N_FEAT; f = f + 1) begin
                if (obtido[f] !== $signed(arq[base + L + f])) begin
                    erros_caso = erros_caso + 1;
                    if (erros < 12) begin
                        $display("[FAIL] caso %0d feature %0d: obtido %0d, esperado %0d",
                                 c, f, obtido[f], $signed(arq[base + L + f]));
                        erros = erros + 1;
                    end
                end
            end
            if (erros_caso == 0)
                $display("   caso %0d: 4/4 corretas  r_lms=%6d rho=[%6d %6d %6d]  [%0d ciclos]",
                         c, obtido[0], obtido[1], obtido[2], obtido[3], ciclos);
            else
                fail_count = fail_count + 1;
        end

        if (fail_count == 0) begin
            success_count = success_count + 1;
            $display("\n[PASS] %0d janelas x 4 features batem BIT A BIT com o modelo Python",
                     n_casos);
        end

        // Orcamento: uma janela de 32 quadros equivale a 320 ms de sinal; a
        // 50 MHz isso da 16 milhoes de ciclos. 1056 amostras x ~22 ciclos
        // deixa folga de tres ordens de grandeza.
        if (ciclos_max < 40000) begin
            success_count = success_count + 1;
            $display("[PASS] Latencia maxima: %0d ciclos (%0d us @ 50 MHz)",
                     ciclos_max, ciclos_max*CLK_PERIOD/1000);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Latencia de %0d ciclos", ciclos_max);
        end

        if (ready === 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova janela sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO EXTRATOR TEMPORAL PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO EXTRATOR TEMPORAL.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
