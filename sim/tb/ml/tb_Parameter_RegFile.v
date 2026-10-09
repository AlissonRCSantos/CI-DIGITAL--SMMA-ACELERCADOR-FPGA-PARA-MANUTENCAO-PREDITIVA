// ============================================================================
// tb_Parameter_RegFile -- testbench: 16 posicoes em ordem, chegada embaralhada
// ============================================================================

`timescale 1ns / 1ps

module tb_Parameter_RegFile;

    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    reg         start = 0;
    reg         esp_valid = 0, lms_valid = 0, f0_valid = 0, ar_valid = 0, r_valid = 0;
    reg  [15:0] esp_data = 0, lms_data = 0, f0_data = 0, ar_data = 0, r_data = 0;
    reg  [2:0]  r_index = 0;
    wire        esp_ready, lms_ready, f0_ready, ar_ready;
    wire        ready, busy, done, out_valid;
    wire [15:0] out_feature;
    reg         out_ready = 1;

    Parameter_RegFile uut (
        .clk(clk), .rst(rst), .start(start), .ready(ready), .busy(busy), .done(done),
        .esp_valid(esp_valid), .esp_ready(esp_ready), .esp_data(esp_data),
        .lms_valid(lms_valid), .lms_ready(lms_ready), .lms_data(lms_data),
        .r_valid(r_valid), .r_index(r_index), .r_data(r_data),
        .f0_valid(f0_valid), .f0_ready(f0_ready), .f0_data(f0_data),
        .ar_valid(ar_valid), .ar_ready(ar_ready), .ar_data(ar_data),
        .out_ready(out_ready), .out_valid(out_valid), .out_feature(out_feature));

    integer success_count = 0, fail_count = 0;
    reg [15:0] obt [0:15];
    integer n_out, k, erros, rodada;
    reg cedo;

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            if (n_out < 16) obt[n_out] = out_feature;
            n_out = n_out + 1;
        end
    end

    // valor esperado da posicao k na rodada r
    function [15:0] valor(input integer r, input integer k);
        valor = 16'h1000 * r + k;
    endfunction

    task envia_stream(input integer qual, input integer n, input integer base_idx);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                case (qual)
                    0: begin esp_valid = 1; esp_data = valor(rodada, base_idx+i); end
                    1: begin lms_valid = 1; lms_data = valor(rodada, base_idx+i); end
                    2: begin f0_valid  = 1; f0_data  = valor(rodada, base_idx+i); end
                    3: begin ar_valid  = 1; ar_data  = valor(rodada, base_idx+i); end
                endcase
                @(posedge clk);
                while (!((qual==0 && esp_ready) || (qual==1 && lms_ready) ||
                         (qual==2 && f0_ready)  || (qual==3 && ar_ready))) @(posedge clk);
            end
            @(negedge clk); esp_valid = 0; lms_valid = 0; f0_valid = 0; ar_valid = 0;
        end
    endtask

    task envia_rho;
        integer i;
        begin
            for (i = 0; i <= 3; i = i + 1) begin
                @(negedge clk); r_valid = 1; r_index = i;
                r_data = (i == 0) ? 16'h7FFF : valor(rodada, 8 + i);
            end
            @(negedge clk); r_valid = 0;
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("   PARAMETER_REGFILE -- vetor de 16 caracteristicas                   ");
        $display("======================================================================");
        repeat (3) @(negedge clk); rst = 0; @(negedge clk);

        for (rodada = 1; rodada <= 2; rodada = rodada + 1) begin
            n_out = 0; cedo = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            // ordem de chegada propositalmente embaralhada
            envia_stream(2, 1, 12);        // f0 primeiro (MDC)
            envia_stream(1, 1, 8);         // r_lms
            envia_stream(0, 8, 0);         // 8 espectrais
            envia_rho;                     // rho0..rho3
            if (n_out != 0) cedo = 1;
            out_ready = (rodada == 2) ? 0 : 1;
            envia_stream(3, 3, 13);        // a1..a3 por ultimo (inversao)
            k = 0;
            while (n_out < 16 && k < 200) begin
                @(negedge clk); k = k + 1;
                if (rodada == 2) out_ready = (k % 3 == 0);   // contrapressao
            end
            out_ready = 1;
            repeat (4) @(negedge clk);

            erros = 0;
            for (k = 0; k < 16; k = k + 1)
                if (obt[k] !== valor(rodada, k)) begin
                    erros = erros + 1;
                    $display("[FAIL] rodada %0d pos %0d: %h, esperado %h", rodada, k, obt[k], valor(rodada, k));
                end
            if (cedo) begin erros = erros + 1; $display("[FAIL] rodada %0d: saida antes de completar", rodada); end
            if (n_out != 16) begin erros = erros + 1; $display("[FAIL] rodada %0d: %0d palavras na saida", rodada, n_out); end
            if (erros == 0) begin
                success_count = success_count + 1;
                $display("[PASS] rodada %0d: 16 posicoes na ordem certa%0s", rodada,
                         (rodada == 2) ? ", com contrapressao, sem reset" : "");
            end else fail_count = fail_count + 1;
        end

        if (ready) begin success_count = success_count + 1; $display("[PASS] voltou ao repouso"); end
        else begin fail_count = fail_count + 1; $display("[FAIL] nao voltou ao repouso"); end

        $display("\n RESUMO: %0d OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO PARAMETER_REGFILE PASSARAM");
        $finish;
    end

    initial begin #2_000_000; $display("[FAIL] timeout"); $finish; end
endmodule
