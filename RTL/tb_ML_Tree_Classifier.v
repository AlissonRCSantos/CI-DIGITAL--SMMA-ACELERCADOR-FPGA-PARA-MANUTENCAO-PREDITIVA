// ============================================================================
// Module: tb_ML_Tree_Classifier
// Description: Testbench auto-verificavel do classificador de arvore (PBL 3.5).
//
// Estrategia:
//   Os vetores vem de vetores/clf_teste.hex, gerado por
//   08_exportar_classificador.py a partir de janelas REAIS do dataset (Jung
//   et al.) que o modelo nunca viu no treino. Cada caso traz as 12 features em
//   Q1.15 e a classe que o modelo QUANTIZADO em Python produziu -- ou seja, a
//   comparacao e BIT A BIT contra a referencia, nao "proxima o suficiente".
//
//   Alem da igualdade de classe, verifica o protocolo:
//     - handshake de entrada (in_valid/in_ready) com origem lenta;
//     - contrapressao na saida (out_ready baixo) sem perder resultado;
//     - reuso sem reset entre classificacoes;
//     - latencia dentro do esperado.
// ============================================================================

`timescale 1ns / 1ps

module tb_ML_Tree_Classifier;

    parameter WIDTH      = 16;
    parameter N_FEATURES = 12;
    parameter N_CASOS    = 64;
    parameter CLK_PERIOD = 20;          // 50 MHz

    reg                     clk = 0;
    reg                     rst;
    reg                     start;
    reg                     enable;
    reg                     in_valid;
    reg  signed [WIDTH-1:0] in_feature;
    reg                     out_ready;

    wire                    ready, busy, done, in_ready, out_valid, out_error;
    wire [1:0]              out_class;

    integer success_count = 0;
    integer fail_count    = 0;

    // vetores: N_CASOS x (12 features + 1 classe esperada)
    reg [15:0] vet [0:N_CASOS*(N_FEATURES+1)-1];

    ML_Tree_Classifier #(
        .WIDTH(WIDTH), .N_FEATURES(N_FEATURES),
        .N_NOS(153), .IDX_W(8), .PROF_MAX(9),
        .ARQ_ROM("vetores/arvore.hex")
    ) uut (
        .clk(clk), .rst(rst),
        .start(start), .enable(enable), .ready(ready), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_feature(in_feature),
        .out_ready(out_ready), .out_valid(out_valid),
        .out_class(out_class), .out_error(out_error)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    integer caso, k, ciclos, ciclos_max, timeout;
    reg [1:0] esperado;
    integer acertos;

    // Envia uma feature respeitando o handshake
    task envia;
        input signed [WIDTH-1:0] v;
        begin
            @(negedge clk);
            in_valid   = 1'b1;
            in_feature = v;
            while (in_ready !== 1'b1) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("   CLASSIFICADOR DE ARVORE DE DECISAO - SMMA (enunciado 3.5)          ");
        $display("   vetores reais do dataset, referencia = modelo Q1.15 em Python      ");
        $display("======================================================================");

        $readmemh("vetores/clf_teste.hex", vet);

        rst = 1; start = 0; enable = 1; in_valid = 0; in_feature = 0; out_ready = 1;
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

        acertos    = 0;
        ciclos_max = 0;

        for (caso = 0; caso < N_CASOS; caso = caso + 1) begin
            // A partir da metade dos casos, exercita a contrapressao da saida.
            out_ready = (caso < N_CASOS/2) ? 1'b1 : 1'b0;

            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            for (k = 0; k < N_FEATURES; k = k + 1)
                envia($signed(vet[caso*(N_FEATURES+1) + k]));

            // conta ciclos ate o resultado aparecer
            ciclos = 0;
            while (out_valid !== 1'b1 && ciclos < 200) begin
                @(posedge clk);
                ciclos = ciclos + 1;
            end
            if (ciclos > ciclos_max) ciclos_max = ciclos;

            if (caso >= N_CASOS/2) begin
                // segura o resultado alguns ciclos: nao pode se perder
                repeat (5) @(negedge clk);
                if (out_valid !== 1'b1) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] caso %0d: resultado se perdeu sob contrapressao", caso);
                end
                out_ready = 1'b1;
            end

            esperado = vet[caso*(N_FEATURES+1) + N_FEATURES][1:0];

            if (out_valid === 1'b1) begin
                if (out_class === esperado && out_error === 1'b0) begin
                    acertos = acertos + 1;
                end else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] caso %0d: classe %0d, esperado %0d (erro=%b)",
                             caso, out_class, esperado, out_error);
                end
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] caso %0d: TIMEOUT, out_valid nunca subiu", caso);
            end

            // consome o resultado
            timeout = 0;
            while (done !== 1'b1 && timeout < 50) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            @(negedge clk);
        end

        if (acertos == N_CASOS) begin
            success_count = success_count + 1;
            $display("[PASS] %0d/%0d casos batem BIT A BIT com o modelo Python",
                     acertos, N_CASOS);
        end else begin
            $display("[FAIL] apenas %0d/%0d casos corretos", acertos, N_CASOS);
        end

        // Reuso sem reset: o modulo voltou a IDLE e aceita nova classificacao
        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova classificacao sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Reuso: ready=%b busy=%b", ready, busy);
        end

        // Latencia: 12 ciclos de carga + 1 de ROM + ate 9 de percurso
        if (ciclos_max <= 40) begin
            success_count = success_count + 1;
            $display("[PASS] Latencia maxima observada: %0d ciclos (%0d ns @ 50 MHz)",
                     ciclos_max, ciclos_max*CLK_PERIOD);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Latencia excessiva: %0d ciclos", ciclos_max);
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO CLASSIFICADOR PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO CLASSIFICADOR.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
