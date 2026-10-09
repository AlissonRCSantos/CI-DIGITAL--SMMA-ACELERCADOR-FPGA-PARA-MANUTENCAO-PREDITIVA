// ============================================================================
// Module: tb_LMS_Weight_Storage
// Description: Self-checking testbench for LMS_Weight_Storage module in Verilog.
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Weight_Storage;

    parameter WIDTH = 16;
    parameter CLK_PERIOD = 20; // 50 MHz

    reg                 clk;
    reg                 rst;
    reg [2:0]           rd_addr;
    reg                 we;
    reg [2:0]           wr_addr;
    reg signed [WIDTH-1:0] wr_data;

    wire signed [WIDTH-1:0] rd_data;
    wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7;

    integer success_count = 0;
    integer fail_count = 0;

    // Instantiate UUT
    LMS_Weight_Storage #(
        .WIDTH(WIDTH)
    ) uut (
        .clk(clk),
        .rst(rst),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .we(we),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .w0(w0), .w1(w1), .w2(w2), .w3(w3), .w4(w4), .w5(w5), .w6(w6), .w7(w7)
    );

    // Clock generator
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        clk = 0;
        rst = 1;
        rd_addr = 0;
        we = 0;
        wr_addr = 0;
        wr_data = 0;

        $display("======================================================================");
        $display("          INICIANDO SIMULACAO DO BANCO DE PESOS (WEIGHT STORAGE)       ");
        $display("======================================================================");

        #(CLK_PERIOD * 3);
        rst = 0;

        // Teste 1: Verificar se todos os pesos foram inicializados em 0
        $display("\n--- TESTE 1: Inicializacao pós-reset ---");
        rd_addr = 3'd0;
        #1;
        if (rd_data === 16'sh0000 && w0 === 16'sh0000 && w7 === 16'sh0000) begin
            success_count = success_count + 1;
            $display("[PASS] Pesos inicializados em 0 com sucesso.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Falha na inicializacao dos pesos! Got rd_data = %h", rd_data);
        end

        // Teste 2: Escrita síncrona e leitura combinatória
        $display("\n--- TESTE 2: Escrita síncrona e Leitura combinatória ---");
        @(negedge clk);
        we = 1'b1;
        wr_addr = 3'd2;
        wr_data = 16'h1234; // Peso fictício
        
        @(negedge clk);
        we = 1'b0; // Desativa escrita
        
        // Leitura imediata (combinatória)
        rd_addr = 3'd2;
        #1;
        if (rd_data === 16'h1234 && w2 === 16'h1234) begin
            success_count = success_count + 1;
            $display("[PASS] Escrita e leitura no endereco 2 funcionaram perfeitamente.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Falha ao ler o peso escrito! Got %h", rd_data);
        end

        // Teste 3: Garantir que escrita não ocorre quando we está desabilitado
        $display("\n--- TESTE 3: Protecao de escrita (we = 0) ---");
        @(negedge clk);
        we = 1'b0;
        wr_addr = 3'd5;
        wr_data = 16'hAAAA;
        
        @(negedge clk);
        rd_addr = 3'd5;
        #1;
        if (rd_data === 16'h0000 && w5 === 16'h0000) begin
            success_count = success_count + 1;
            $display("[PASS] Protecao de escrita funcionando. Dado nao foi gravado.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Erro! Gravacao indevida com we desabilitado.");
        end

        // Teste 4: Escrita múltipla consecutiva
        $display("\n--- TESTE 4: Escritas consecutivas ---");
        @(negedge clk);
        we = 1'b1;
        wr_addr = 3'd0; wr_data = 16'h5555;
        @(negedge clk);
        wr_addr = 3'd7; wr_data = 16'h7777;
        @(negedge clk);
        we = 1'b0;

        #1;
        if (w0 === 16'h5555 && w7 === 16'h7777) begin
            success_count = success_count + 1;
            $display("[PASS] Escritas consecutivas nos extremos (0 e 7) confirmadas.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Erro em escritas consecutivas! w0=%h, w7=%h", w0, w7);
        end

        $display("\n======================================================================");
        $display("                      RELATORIO FINAL DE SIMULACAO                    ");
        $display("======================================================================");
        $display("  Sucessos Confirmados: %d", success_count);
        $display("  Falhas Detectadas:    %d", fail_count);
        $display("======================================================================");
        if (fail_count == 0) begin
            $display("  >>> [CONGRATS] O BANCO DE PESOS PASSOU EM TODOS OS TESTES! <<<");
        end else begin
            $display("  >>> [ERROR] Falhas detectadas no banco de pesos. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule
