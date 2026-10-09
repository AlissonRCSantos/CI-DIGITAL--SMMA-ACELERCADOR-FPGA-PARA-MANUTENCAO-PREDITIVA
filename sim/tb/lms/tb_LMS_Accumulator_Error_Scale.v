// ============================================================================
// tb_LMS_Accumulator_Error_Scale -- testbench do acumulador/erro do LMS
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Accumulator_Error_Scale;

    // Simulation Parameters
    parameter WIDTH      = 16;
    parameter FRAC       = 15;
    parameter MU_SHIFT   = 4;
    parameter CLK_PERIOD = 20; // 50 MHz Clock (20 ns)

    // Signals
    reg                 clk;
    reg                 rst;
    reg                 clear_acc;
    reg                 valid_y_part;
    reg signed [WIDTH-1:0] in_y_part;
    reg signed [WIDTH-1:0] in_d;

    wire signed [WIDTH-1:0] out_y;
    wire signed [WIDTH-1:0] out_error;
    wire signed [WIDTH-1:0] out_u_e;
    wire                    valid_u_e;

    // Testbench stats
    integer success_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    // Instantiate Unit Under Test (UUT)
    LMS_Accumulator_Error_Scale #(
        .WIDTH(WIDTH),
        .FRAC(FRAC),
        .MU_SHIFT(MU_SHIFT)
    ) uut (
        .clk(clk),
        .rst(rst),
        .clear_acc(clear_acc),
        .valid_y_part(valid_y_part),
        .in_y_part(in_y_part),
        .in_d(in_d),
        .out_y(out_y),
        .out_error(out_error),
        .out_u_e(out_u_e),
        .valid_u_e(valid_u_e)
    );

    // Clock Generator (50 MHz)
    always #(CLK_PERIOD/2) clk = ~clk;

    // Task for checking final output
    task check_outputs;
        input signed [WIDTH-1:0] exp_y;
        input signed [WIDTH-1:0] exp_err;
        input signed [WIDTH-1:0] exp_ue;
        begin
            total_tests = total_tests + 1;
            if (valid_u_e !== 1'b1) begin
                fail_count = fail_count + 1;
                $display("[FAIL: TIMING] valid_u_e is low! Expected high.");
            end else if (out_y === exp_y && out_error === exp_err && out_u_e === exp_ue) begin
                success_count = success_count + 1;
                $display("[PASS] Out_Y = %d (hex: %h) | Err = %d (hex: %h) | mu_e = %d (hex: %h)",
                         out_y, out_y, out_error, out_error, out_u_e, out_u_e);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL: MATH] Output mismatch!");
                $display("  Got:      Y = %5d (%h), Err = %5d (%h), mu_e = %5d (%h)", out_y, out_y, out_error, out_error, out_u_e, out_u_e);
                $display("  Expected: Y = %5d (%h), Err = %5d (%h), mu_e = %5d (%h)", exp_y, exp_y, exp_err, exp_err, exp_ue, exp_ue);
            end
        end
    endtask

    // Main Test Sequence
    initial begin
        clk = 0;
        rst = 1;
        clear_acc = 0;
        valid_y_part = 0;
        in_y_part = 0;
        in_d = 0;

        $display("======================================================================");
        $display("   INICIANDO SIMULACAO DO ACUMULADOR E CALCULO DE ERRO DO LMS - Q1.15 ");
        $display("======================================================================");

        #(CLK_PERIOD * 3);
        rst = 0;
        $display("[INFO] Reset desativado.");

        // TESTE 1: Acumulacao normal sem saturacao
        $display("\n--- TESTE 1: Acumulacao Normal (Sem Saturacao) ---");
        @(negedge clk);
        clear_acc = 1;
        in_d = 16'h4CCD; // 19661 (0.6)

        @(negedge clk);
        clear_acc = 0;
        valid_y_part = 1;
        in_y_part = 16'd1000; // 1

        repeat (7) begin
            @(negedge clk);
            in_y_part = 16'd1000;
        end

        @(negedge clk);
        valid_y_part = 0;
        in_y_part = 0;

        // Aguarda 1 clock para o pipeline de processamento e saturação
        @(posedge clk);
        #1;
        check_outputs(16'd8000, 16'd11661, 16'd728);

        // Aguarda a subida de clock do ciclo seguinte (T+1)
        // para dar tempo do hardware síncrono ler o sinal de clear e desativar o pino.
        @(posedge clk);
        #1;
        if (valid_u_e !== 1'b0) begin
            total_tests = total_tests + 1;
            fail_count = fail_count + 1;
            $display("[FAIL: TIMING] valid_u_e did not clear on next cycle!");
        end else begin
            $display("[PASS] valid_u_e cleared on the next cycle.");
        end

        #(CLK_PERIOD * 2);

        // TESTE 2: Saturação de Y (Overflow Positivo)
        $display("\n--- TESTE 2: Overflow de Y (Saturacao em +0.9999) ---");
        @(negedge clk);
        clear_acc = 1;
        in_d = 16'h4000; // 16384 (0.5)

        @(negedge clk);
        clear_acc = 0;
        valid_y_part = 1;
        in_y_part = 16'd10000;

        repeat (7) begin
            @(negedge clk);
            in_y_part = 16'd10000;
        end

        @(negedge clk);
        valid_y_part = 0;
        in_y_part = 0;

        @(posedge clk);
        #1;
        check_outputs(16'h7FFF, -16'd16383, -16'd1024);

        #(CLK_PERIOD * 2);

        // TESTE 3: Saturação de Erro (Overflow de Subtração)
        $display("\n--- TESTE 3: Saturação do Erro (Overflow de Subtração) ---");
        @(negedge clk);
        clear_acc = 1;
        in_d = 16'h8000; // -32768 (-1.0)

        @(negedge clk);
        clear_acc = 0;
        valid_y_part = 1;
        in_y_part = 16'd4095; // Q1.15 max 32767 / 8 = 4095.8

        repeat (7) begin
            @(negedge clk);
            in_y_part = 16'd4095; // total ~ 32760
        end

        @(negedge clk);
        valid_y_part = 0;
        in_y_part = 0;

        @(posedge clk);
        #1;
        check_outputs(16'd32760, 16'h8000, -16'd4096);

        #(CLK_PERIOD * 2);

        // TESTE 4: Saturação de Y (Overflow Negativo)
        $display("\n--- TESTE 4: Underflow de Y & Overflow Positivo de Erro ---");
        @(negedge clk);
        clear_acc = 1;
        in_d = 16'h4000; // 16384 (0.5)

        @(negedge clk);
        clear_acc = 0;
        valid_y_part = 1;
        in_y_part = -16'd8000;

        repeat (7) begin
            @(negedge clk);
            in_y_part = -16'd8000;
        end

        @(negedge clk);
        valid_y_part = 0;
        in_y_part = 0;

        @(posedge clk);
        #1;
        check_outputs(16'h8000, 16'h7FFF, 16'd3072);

        #(CLK_PERIOD * 3);

        // CONSOLIDACAO DOS RESULTADOS
        $display("\n======================================================================");
        $display("                      RELATORIO FINAL DE SIMULACAO                    ");
        $display("======================================================================");
        $display("  Total de Operacoes Verificadas: %d", total_tests);
        $display("  Sucessos Confirmados:           %d", success_count);
        $display("  Falhas Detectadas:              %d", fail_count);
        $display("======================================================================");

        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> [CONGRATS] O ACUMULADOR E UNIDADE DE ERRO PASSOU EM TODOS OS TESTES! <<<");
            $display("  >>> Lógica de acumulação com guard bits, saturação simétrica de y(n), <<<");
            $display("  >>> cálculo de erro estável e deslocamento mu_e validados com perfeição! <<<");
        end else begin
            $display("  >>> [ERROR] Falhas identificadas no processamento do Acumulador/Erro. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule
