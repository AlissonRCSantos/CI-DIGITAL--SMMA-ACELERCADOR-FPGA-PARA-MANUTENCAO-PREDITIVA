// ============================================================================
// Testbench: tb_CNN_MAC_Unit
// Verifica:
//   1) Acumulacao de 9 produtos (uma janela 3x3 completa)
//   2) Uso do init_acc como BIAS pre-carregado
//   3) Produtos negativos / acumulacao negativa
//   4) Acumulacoes CONSECUTIVAS sem bolha: comprova que o flag 'first'
//      recarrega o acumulador no momento certo, sem vazar o resultado
//      anterior (bug classico de aceleradores com pipeline)
//   5) Latencia exata de 3 ciclos entre o produto 'last' e o strobe out_valid
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_MAC_Unit;

    localparam WIDTH = 16;
    localparam ACC_W = 40;

    reg                     clk = 0;
    reg                     rst = 1;
    reg                     en = 0, first = 0, last = 0;
    reg  signed [ACC_W-1:0] init_acc = 0;
    reg  signed [WIDTH-1:0] in_a = 0, in_b = 0;
    wire signed [ACC_W-1:0] out_acc;
    wire                    out_valid;

    integer errors = 0, checks = 0;
    integer t, n_res;
    reg signed [ACC_W-1:0] cap_acc;
    integer lat_cnt, lat_meas;
    reg lat_arm;

    // Vetores de estimulo
    reg signed [WIDTH-1:0] va [0:8];
    reg signed [WIDTH-1:0] vb [0:8];

    always #10 clk = ~clk;

    CNN_MAC_Unit #(.WIDTH(WIDTH), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst(rst), .en(en), .first(first), .last(last),
        .init_acc(init_acc), .in_a(in_a), .in_b(in_b),
        .out_acc(out_acc), .out_valid(out_valid)
    );

    // ---- Captura de resultados (amostragem no negedge = valores estaveis) ----
    initial begin n_res = 0; lat_arm = 0; lat_cnt = 0; lat_meas = -1; end

    // Captura dos resultados (negedge: valores ja estaveis no ciclo)
    always @(negedge clk) begin
        if (out_valid) begin
            cap_acc = out_acc;
            n_res   = n_res + 1;
        end
    end

    // Medicao de latencia: conta bordas de clock a partir daquela em que o
    // DUT amostra o produto marcado com 'last'.
    always @(posedge clk) begin
        if (en && last) begin
            lat_cnt <= 1;
            lat_arm <= 1;
        end else if (lat_arm && !out_valid) begin
            lat_cnt <= lat_cnt + 1;
        end

        if (lat_arm && out_valid) begin
            lat_meas <= lat_cnt;
            lat_arm  <= 1'b0;
        end
    end

    // ---- Verificador ----
    task check(input [8*48-1:0] nome, input signed [ACC_W-1:0] got,
                                   input signed [ACC_W-1:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FALHA] %0s: obtido=%0d esperado=%0d", nome, got, exp);
            end else begin
                $display("  [ OK  ] %0s = %0d", nome, got);
            end
        end
    endtask

    // ---- Executa uma acumulacao de 'n' produtos ----
    task mac_run(input integer n, input signed [ACC_W-1:0] init);
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk);
                en       = 1'b1;
                first    = (t == 0);
                last     = (t == n-1);
                init_acc = init;
                in_a     = va[t];
                in_b     = vb[t];
            end
            @(negedge clk);
            en = 1'b0; first = 1'b0; last = 1'b0;
        end
    endtask

    integer i;

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_MAC_Unit");
        $display("========================================================");

        repeat (3) @(negedge clk);
        rst = 0;

        // ------------------------------------------------------------------
        // TESTE 1: 9 produtos, sem bias.  sum((i+1)*1000 * 10) = 450000
        // ------------------------------------------------------------------
        $display("\n-- Teste 1: acumulacao de 9 produtos (janela 3x3), bias=0");
        for (i = 0; i < 9; i = i + 1) begin
            va[i] = (i+1)*1000;
            vb[i] = 10;
        end
        mac_run(9, 40'sd0);
        repeat (6) @(negedge clk);
        check("soma de 9 produtos", cap_acc, 40'sd450000);

        // ------------------------------------------------------------------
        // TESTE 2: mesma soma com BIAS pre-carregado (5 << 15 = 163840)
        //          9 * (100 * -200) = -180000 ; -180000 + 163840 = -16160
        // ------------------------------------------------------------------
        $display("\n-- Teste 2: init_acc usado como bias + produtos negativos");
        for (i = 0; i < 9; i = i + 1) begin
            va[i] = 100;
            vb[i] = -200;
        end
        mac_run(9, 40'sd163840);
        repeat (6) @(negedge clk);
        check("bias + 9 produtos negativos", cap_acc, -40'sd16160);

        // ------------------------------------------------------------------
        // TESTE 3: duas acumulacoes CONSECUTIVAS (sem bolha entre elas).
        //          Se o flag 'first' nao recarregasse corretamente, o
        //          resultado da segunda viria contaminado pela primeira.
        // ------------------------------------------------------------------
        $display("\n-- Teste 3: acumulacoes consecutivas (back-to-back)");
        n_res = 0;
        for (i = 0; i < 9; i = i + 1) begin va[i] = 7; vb[i] = 11; end
        // Primeira janela: 9*77 = 693
        for (t = 0; t < 9; t = t + 1) begin
            @(negedge clk);
            en = 1; first = (t==0); last = (t==8); init_acc = 0;
            in_a = va[t]; in_b = vb[t];
        end
        // Segunda janela emendada imediatamente: 9 * (2*3) = 54
        for (t = 0; t < 9; t = t + 1) begin
            @(negedge clk);
            en = 1; first = (t==0); last = (t==8); init_acc = 0;
            in_a = 2; in_b = 3;
        end
        @(negedge clk); en = 0; first = 0; last = 0;
        repeat (6) @(negedge clk);
        check("2a janela nao contaminada pela 1a", cap_acc, 40'sd54);
        checks = checks + 1;
        if (n_res !== 2) begin
            errors = errors + 1;
            $display("  [FALHA] numero de strobes out_valid: obtido=%0d esperado=2", n_res);
        end else
            $display("  [ OK  ] exatamente 2 strobes out_valid emitidos");

        // ------------------------------------------------------------------
        // TESTE 4: latencia medida no teste 1
        // ------------------------------------------------------------------
        $display("\n-- Teste 4: latencia do pipeline");
        checks = checks + 1;
        if (lat_meas !== 3) begin
            errors = errors + 1;
            $display("  [FALHA] latencia entre 'last' e out_valid: esperado=3 obtido=%0d", lat_meas);
        end else
            $display("  [ OK  ] out_valid exatamente 3 ciclos apos o produto 'last'");

        // ------------------------------------------------------------------
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
