// ============================================================================
// Testbench: tb_CNN_ReLU
// Verifica a unidade de ativacao / requantizacao nas tres funcoes que ela faz:
//   1) Reescala Q?.30 -> Q1.15 com arredondamento simetrico
//   2) Satura em +32767 / -32768 em vez de dar wrap-around
//   3) Aplica ReLU  f(x) = max(0,x)  quando ENABLE_RELU = 1
//
// Sao instanciadas DUAS copias do modulo, com ENABLE_RELU = 1 e = 0, para
// provar que a mesma unidade serve para a saida da convolucao (com ReLU) e
// para os scores da camada densa (sem ReLU, pois scores podem ser negativos).
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_ReLU;

    localparam ACC_W = 40;
    localparam WIDTH = 16;

    reg  signed [ACC_W-1:0] in_acc;
    wire signed [WIDTH-1:0] y_relu;   // com ReLU
    wire signed [WIDTH-1:0] y_lin;    // sem ReLU (apenas satura)

    integer errors = 0, checks = 0;

    CNN_ReLU #(.ACC_W(ACC_W), .WIDTH(WIDTH), .SHIFT(15), .ENABLE_RELU(1))
        dut_relu (.in_acc(in_acc), .out_y(y_relu));

    CNN_ReLU #(.ACC_W(ACC_W), .WIDTH(WIDTH), .SHIFT(15), .ENABLE_RELU(0))
        dut_lin  (.in_acc(in_acc), .out_y(y_lin));

    task check_case(input [8*40-1:0] nome,
                    input signed [ACC_W-1:0] acc,
                    input signed [WIDTH-1:0] exp_relu,
                    input signed [WIDTH-1:0] exp_lin);
        begin
            in_acc = acc;
            #1;
            checks = checks + 2;
            if (y_relu !== exp_relu) begin
                errors = errors + 1;
                $display("  [FALHA] %0s ReLU=1: acc=%0d obtido=%0d esperado=%0d",
                         nome, acc, y_relu, exp_relu);
            end
            if (y_lin !== exp_lin) begin
                errors = errors + 1;
                $display("  [FALHA] %0s ReLU=0: acc=%0d obtido=%0d esperado=%0d",
                         nome, acc, y_lin, exp_lin);
            end
            if (y_relu === exp_relu && y_lin === exp_lin)
                $display("  [ OK  ] %-28s acc=%12d -> relu=%6d  linear=%6d",
                         nome, acc, y_relu, y_lin);
        end
    endtask

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_ReLU (ativacao + requantizacao)");
        $display("========================================================\n");

        // --------------------------------------------------------------
        // Reescala basica: 1.0 em Q?.30 vale 32768 -> 1 em Q1.15
        // --------------------------------------------------------------
        $display("-- Grupo 1: reescala e arredondamento");
        check_case("zero",              40'sd0,       16'sd0,  16'sd0);
        check_case("+1 LSB de Q1.15",   40'sd32768,   16'sd1,  16'sd1);
        check_case("+1 LSB - 1 (arred)",40'sd49151,   16'sd1,  16'sd1);
        check_case("valor medio +",     40'sd100000,  16'sd3,  16'sd3);
        check_case("valor medio -",    -40'sd100000,  16'sd0, -16'sd3);

        // --------------------------------------------------------------
        // ReLU: tudo que e negativo vira exatamente zero
        // --------------------------------------------------------------
        $display("\n-- Grupo 2: ReLU zera negativos (e a versao linear nao)");
        check_case("-1 LSB",           -40'sd32768,   16'sd0, -16'sd1);
        check_case("-1.5 LSB",         -40'sd49152,   16'sd0, -16'sd1);

        // --------------------------------------------------------------
        // Saturacao: sem ela, +max viraria -max e destruiria a classificacao
        // --------------------------------------------------------------
        $display("\n-- Grupo 3: saturacao simetrica (anti wrap-around)");
        check_case("overflow positivo",  40'sd1073741824,  16'sd32767,  16'sd32767);
        check_case("overflow negativo", -40'sd1073741824,  16'sd0,     -16'sd32768);
        check_case("limite +32767",      40'sd1073709056,  16'sd32767,  16'sd32767);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

endmodule
