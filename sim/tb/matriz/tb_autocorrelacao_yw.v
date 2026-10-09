// ============================================================================
// Module: tb_autocorrelacao_yw
// Description: Testbench da autocorrelacao normalizada (1a etapa do modulo de
//              estimacao matricial). Verifica rho[0..3] de 6 janelas REAIS
//              (vetores/temp_teste.hex) contra o modelo Python, BIT A BIT:
//                rho[0] = 32767 (1,0 saturado em Q1.15)
//                rho[1..3] = colunas 1..3 do arquivo
//              e o protocolo de saida r_valid / r_index / r_data.
// ============================================================================

`timescale 1ns / 1ps

module tb_autocorrelacao_yw;

    parameter WIDTH      = 16;
    parameter L          = 1056;
    parameter N_FEAT_ARQ = 4;
    parameter MAX_CASOS  = 6;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                      start;
    reg                      in_valid;
    reg  signed [WIDTH-1:0]  in_sample;
    wire                     in_ready, ready, busy;
    wire                     r_valid;
    wire [2:0]               r_index;
    wire signed [WIDTH-1:0]  r_data;

    autocorrelacao_yw #(.WIDTH(WIDTH), .FRAC(15), .N_AMOSTRAS(L), .N_LAGS(3)) uut (
        .clk(clk), .reset(rst),
        .start(start), .ready(ready), .busy(busy),
        .lms_valid(in_valid), .lms_ready(in_ready), .lms_data(in_sample),
        .r_valid(r_valid), .r_index(r_index), .r_data(r_data)
    );

    reg [15:0] arq [0:2 + MAX_CASOS*(L + N_FEAT_ARQ) - 1];
    integer n_casos;
    integer success_count = 0, fail_count = 0;

    // ---- produtor (com bolhas aleatorias de valid) ----
    integer base_in, idx_in;
    reg     enviando;
    reg [3:0] lfsr = 4'b1001;
    always @(posedge clk) lfsr <= {lfsr[2:0], lfsr[3] ^ lfsr[2]};
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid <= 1'b0; in_sample <= {WIDTH{1'b0}}; idx_in <= 0;
        end else begin
            if (in_valid && in_ready) begin
                idx_in   <= idx_in + 1;
                in_valid <= 1'b0;
            end else if (!in_valid && idx_in < L && lfsr[0]) begin
                in_valid  <= 1'b1;
                in_sample <= arq[base_in + idx_in];
            end
        end
    end

    // ---- coletor ----
    reg signed [WIDTH-1:0] rho [0:3];
    reg [3:0] vistos;
    reg       ordem_ok;
    always @(posedge clk)
        if (!rst && r_valid) begin
            if (r_index !== vistos) ordem_ok = 1'b0;
            rho[r_index] = r_data;
            vistos = vistos + 1;
        end

    integer c, k, base, ciclos, erros_caso;

    initial begin
        $display("======================================================================");
        $display("  AUTOCORRELACAO NORMALIZADA (autocorrelacao_yw) -- janelas reais    ");
        $display("======================================================================");
        $readmemh("vetores/temp_teste.hex", arq);
        n_casos = arq[0];

        rst = 1; start = 0; enviando = 0;
        repeat (3) @(negedge clk); rst = 0; @(negedge clk);

        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1; $display("[PASS] Reset: ready=1, busy=0");
        end else begin
            fail_count = fail_count + 1; $display("[FAIL] Reset");
        end

        for (c = 0; c < n_casos; c = c + 1) begin
            base = 2 + c*(L + N_FEAT_ARQ); base_in = base;
            vistos = 0; ordem_ok = 1'b1; enviando = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            enviando = 1;
            ciclos = 0;
            while (vistos < 4 && ciclos < 200000) begin @(posedge clk); ciclos = ciclos + 1; end
            enviando = 0;
            repeat (3) @(negedge clk);

            erros_caso = 0;
            if (rho[0] !== 16'sd32767) erros_caso = erros_caso + 1;
            for (k = 1; k <= 3; k = k + 1)
                if (rho[k] !== $signed(arq[base + L + k])) begin
                    erros_caso = erros_caso + 1;
                    $display("[FAIL] caso %0d rho%0d: obtido %0d, esperado %0d",
                             c, k, rho[k], $signed(arq[base + L + k]));
                end
            if (!ordem_ok) begin
                erros_caso = erros_caso + 1;
                $display("[FAIL] caso %0d: r_index fora de ordem", c);
            end
            if (erros_caso == 0) begin
                success_count = success_count + 1;
                $display("[PASS] caso %0d: rho = [%0d %0d %0d %0d]  [%0d ciclos]",
                         c, rho[0], rho[1], rho[2], rho[3], ciclos);
            end else
                fail_count = fail_count + 1;
        end

        if (ready === 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova janela sem reset");
        end else begin
            fail_count = fail_count + 1; $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DA AUTOCORRELACAO PASSARAM COM SUCESSO!");
        $finish;
    end

    initial begin #200_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
