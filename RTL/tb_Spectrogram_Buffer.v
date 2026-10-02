// ============================================================================
// Module: tb_Spectrogram_Buffer
// Description: Testbench do buffer que monta a imagem 32x32 do espectrograma.
//
// O ponto critico deste bloco e a TRANSPOSICAO: os pixels entram por quadro
// (todos os bins de um instante) e precisam sair por linha (todos os
// instantes de um bin). Um erro de indice aqui nao quebra a simulacao -- so
// embaralha a imagem, e a CNN passaria a classificar lixo silenciosamente.
//
// Por isso o estimulo e um padrao ONDE CADA PIXEL CARREGA SUA PROPRIA
// COORDENADA (pixel = quadro*32 + bin). Assim a saida esperada e conhecida
// exatamente para as 1024 posicoes, e qualquer troca de linha por coluna
// aparece imediatamente.
// ============================================================================

`timescale 1ns / 1ps

module tb_Spectrogram_Buffer;

    parameter WIDTH     = 16;
    parameter N_BINS    = 32;
    parameter N_QUADROS = 32;
    parameter TOTAL     = N_BINS * N_QUADROS;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                  start;
    reg                  in_valid;
    reg  [WIDTH-1:0]     in_pixel;
    wire                 in_ready, ready, busy, done, out_valid;
    wire [WIDTH-1:0]     out_pixel;

    // contrapressao independente na saida
    reg       bp_enable;
    reg [1:0] bp_cnt;
    wire      out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    Spectrogram_Buffer #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(ready), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_pixel(in_pixel),
        .out_ready(out_ready), .out_valid(out_valid), .out_pixel(out_pixel)
    );

    integer success_count = 0;
    integer fail_count    = 0;

    // ---- produtor sincrono dos pixels de entrada ----
    integer idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst) begin
            in_valid <= 1'b0; in_pixel <= {WIDTH{1'b0}}; idx_in <= 0;
        end else if (enviando) begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < TOTAL) begin
                    in_valid <= 1'b1;
                    in_pixel <= idx_in + 1;      // pixel = quadro*32 + bin
                end else begin
                    in_valid <= 1'b0;
                end
            end else if (!in_valid && idx_in < TOTAL) begin
                in_valid <= 1'b1;
                in_pixel <= idx_in;
            end
        end
    end

    // ---- coletor da saida ----
    reg [WIDTH-1:0] saida [0:TOTAL-1];
    integer n_out;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (n_out < TOTAL) saida[n_out] = out_pixel;
            n_out = n_out + 1;
        end
    end

    integer i, lin, col, esperado, erros, guarda;

    initial begin
        $display("======================================================================");
        $display("   BUFFER DO ESPECTROGRAMA 32x32 -- verificacao da transposicao       ");
        $display("======================================================================");

        rst = 1; start = 0; enviando = 0; idx_in = 0; n_out = 0;
        bp_enable = 0; bp_cnt = 0;
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

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        enviando = 1'b1;
        bp_enable = 1'b1;                 // contrapressao durante toda a saida

        guarda = 0;
        while (n_out < TOTAL && guarda < 200000) begin
            @(posedge clk);
            guarda = guarda + 1;
        end
        repeat (20) @(negedge clk);

        // ---- 1. quantidade ----
        if (n_out == TOTAL) begin
            success_count = success_count + 1;
            $display("[PASS] Entregou %0d pixels (esperado %0d)", n_out, TOTAL);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Entregou %0d pixels, esperado %0d", n_out, TOTAL);
        end

        // ---- 2. ordem raster: linha = bin, coluna = quadro ----
        erros = 0;
        for (i = 0; i < TOTAL && i < n_out; i = i + 1) begin
            lin = i / N_QUADROS;                  // bin
            col = i % N_QUADROS;                  // quadro
            esperado = col * N_BINS + lin;        // pixel gravado naquela posicao
            if (saida[i] !== esperado[WIDTH-1:0]) begin
                if (erros < 6)
                    $display("[FAIL] pixel %0d (bin %0d, quadro %0d): obtido %0d, esperado %0d",
                             i, lin, col, saida[i], esperado);
                erros = erros + 1;
            end
        end
        if (erros == 0) begin
            success_count = success_count + 1;
            $display("[PASS] Transposicao correta nas %0d posicoes (linha=bin, coluna=quadro)",
                     TOTAL);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] %0d posicoes fora de ordem", erros);
        end

        // ---- 3. reuso sem reset ----
        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Pronto para a proxima imagem sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Nao voltou a IDLE (ready=%b busy=%b)", ready, busy);
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO BUFFER PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO BUFFER.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
