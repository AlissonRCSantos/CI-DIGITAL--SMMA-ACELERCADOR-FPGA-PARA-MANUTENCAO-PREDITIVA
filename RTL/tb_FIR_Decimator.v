// ============================================================================
// Module: tb_FIR_Decimator
// Description: Testbench auto-verificavel do FIR anti-aliasing + decimador /8.
//
// Estimulo e referencia vem de vetores/fir_teste.hex, gerado por
// 09_exportar_frontend.py a partir de 4096 amostras REAIS do dataset
// (0Nm_BPFO_10 -- escolhido por ter conteudo espectral rico, exercitando o
// filtro em toda a banda e nao so em baixa frequencia).
//
// A referencia usa a MESMA aritmetica inteira do hardware (arredondamento
// meio-para-cima e saturacao), entao a comparacao e BIT A BIT.
//
// Alem dos valores, verifica:
//   - a TAXA de saida: exatamente 1 amostra a cada 8 de entrada;
//   - o ALINHAMENTO: a primeira saida sai na amostra 62 (linha de atraso
//     cheia), que e o que o modo 'valid' da convolucao do modelo define;
//   - contrapressao: com out_ready baixo, nada se perde nem se sobrescreve.
// ============================================================================

`timescale 1ns / 1ps

module tb_FIR_Decimator;

    parameter WIDTH      = 16;
    parameter N_TAPS     = 63;
    parameter DECIM      = 8;
    parameter CLK_PERIOD = 20;
    parameter MAX_IN     = 4096;
    parameter MAX_OUT    = 1024;

    reg                     clk = 0;
    reg                     rst;
    reg                     in_valid;
    reg  signed [WIDTH-1:0] in_sample;

    // out_ready precisa oscilar SOZINHO: a tarefa 'envia' pode ficar parada
    // esperando in_ready, e o DUT (corretamente) segura a entrada enquanto
    // houver saida pendente. Se out_ready ficasse congelado dentro da tarefa,
    // o testbench travaria a si mesmo.
    reg                     bp_enable;
    reg [1:0]               bp_cnt;
    wire                    out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    wire                    in_ready, out_valid, overflow;
    wire signed [WIDTH-1:0] out_sample;

    integer success_count = 0;
    integer fail_count    = 0;

    // cabecalho (2 palavras) + entradas + saidas esperadas
    reg [15:0] arq [0:2 + MAX_IN + MAX_OUT - 1];
    integer n_in, n_out;

    reg signed [WIDTH-1:0] obtido [0:MAX_OUT-1];
    integer n_obtido;

    FIR_Decimator #(
        .WIDTH(WIDTH), .FRAC(15), .N_TAPS(N_TAPS), .DECIM(DECIM),
        .ACC_W(40), .ARQ_COEF("vetores/fir_coef.hex")
    ) uut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready), .in_sample(in_sample),
        .out_ready(out_ready), .out_valid(out_valid), .out_sample(out_sample),
        .overflow(overflow)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Coletor das saidas (so conta quando valid E ready -- transferencia real)
    integer idx_primeira;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (n_obtido < MAX_OUT) obtido[n_obtido] = out_sample;
            n_obtido = n_obtido + 1;
        end
    end

    // ------------------------------------------------------------------
    // Produtor SINCRONO das amostras.
    //
    // Dirigir o handshake com @(negedge)/@(posedge) dentro de uma task e
    // fragil: se 'in_valid' continuar alto por mais de um flanco em que
    // 'in_ready' tambem esta alto, a MESMA amostra e aceita duas vezes.
    // Foi exatamente o que aconteceu aqui (4231 aceites para 4096 amostras),
    // inflando a contagem de saidas. Este processo avanca o indice APENAS
    // quando a transferencia se completa, entao duplicar e impossivel.
    // ------------------------------------------------------------------
    integer idx;
    reg     enviando;

    always @(posedge clk) begin
        if (rst) begin
            in_valid  <= 1'b0;
            in_sample <= {WIDTH{1'b0}};
            idx       <= 0;
        end else if (enviando) begin
            if (in_valid && in_ready) begin        // amostra aceita
                idx <= idx + 1;
                if (idx + 1 < n_in) begin
                    in_valid  <= 1'b1;
                    in_sample <= $signed(arq[2 + idx + 1]);
                end else begin
                    in_valid <= 1'b0;
                end
            end else if (!in_valid && idx < n_in) begin
                in_valid  <= 1'b1;
                in_sample <= $signed(arq[2 + idx]);
            end
        end
    end

    integer i, dif, piores, amostra_primeira;

    initial begin
        $display("======================================================================");
        $display("   FIR ANTI-ALIASING (63 taps) + DECIMADOR /8 -- entrada do SMMA      ");
        $display("   estimulo real do dataset, referencia bit-exata                     ");
        $display("======================================================================");

        $readmemh("vetores/fir_teste.hex", arq);
        n_in  = arq[0];
        n_out = arq[1];
        $display("estimulo: %0d amostras @25.6 kHz -> esperado %0d @3.2 kHz", n_in, n_out);

        rst = 1; bp_enable = 0; bp_cnt = 0; enviando = 0; idx = 0;
        n_obtido = 0; amostra_primeira = -1;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // dispara o produtor e acompanha o progresso
        enviando = 1'b1;
        while (idx < n_in) begin
            @(posedge clk);
            bp_enable = (idx >= n_in/2);          // contrapressao na 2a metade
            if (amostra_primeira < 0 && n_obtido > 0) amostra_primeira = idx;
        end
        bp_enable = 1'b0;
        repeat (300) @(negedge clk);     // drena o que restou

        // ---- 1. taxa de saida ----
        if (n_obtido == n_out) begin
            success_count = success_count + 1;
            $display("[PASS] Taxa: %0d saidas para %0d entradas (1 a cada %0d)",
                     n_obtido, n_in, DECIM);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Taxa: %0d saidas, esperado %0d", n_obtido, n_out);
        end

        // ---- 2. valores bit a bit ----
        piores = 0;
        for (i = 0; i < n_out && i < n_obtido; i = i + 1) begin
            if (obtido[i] !== $signed(arq[2 + n_in + i])) begin
                if (piores < 8)
                    $display("[FAIL] saida %0d: obtido %0d, esperado %0d",
                             i, obtido[i], $signed(arq[2 + n_in + i]));
                piores = piores + 1;
            end
        end
        if (piores == 0) begin
            success_count = success_count + 1;
            $display("[PASS] %0d/%0d saidas batem BIT A BIT com o modelo", n_out, n_out);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] %0d saidas divergentes de %0d", piores, n_out);
        end

        // ---- 3. alinhamento da primeira saida ----
        // A linha de atraso enche na amostra N_TAPS-1 = 62.
        if (amostra_primeira >= N_TAPS-1 && amostra_primeira <= N_TAPS+DECIM) begin
            success_count = success_count + 1;
            $display("[PASS] Alinhamento: 1a saida apos a amostra %0d (linha cheia em %0d)",
                     amostra_primeira, N_TAPS-1);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Alinhamento: 1a saida na amostra %0d, esperado ~%0d",
                     amostra_primeira, N_TAPS-1);
        end

        // ---- 4. saturacao ----
        if (overflow === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Nenhuma saturacao com sinal real de fundo de escala +-32 g");
        end else begin
            $display("[INFO] Houve saturacao em alguma saida (overflow=1)");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO FIR+DECIMADOR PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO FIR+DECIMADOR.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
