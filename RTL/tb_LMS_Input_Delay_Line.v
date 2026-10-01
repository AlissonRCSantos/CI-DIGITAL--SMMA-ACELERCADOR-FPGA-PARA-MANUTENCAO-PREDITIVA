// ============================================================================
// Module: tb_LMS_Input_Delay_Line
// Description: Testbench to validate the LMS_Input_Delay_Line module.
//              Verifies sample shifting, desired signal registration, 
//              and addressable multiplexed reading.
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Input_Delay_Line;

    // Parameters
    parameter WIDTH = 16;
    parameter CLK_PERIOD = 20; // 50 MHz clock

    // Inputs
    reg                 clk;
    reg                 rst;
    reg                 sample_valid;
    reg signed [WIDTH-1:0] in_x;
    reg [2:0]           rd_addr;

    // Outputs
    wire signed [WIDTH-1:0] out_x_k;
    wire signed [WIDTH-1:0] out_d;

    // Instantiate UUT
    LMS_Input_Delay_Line #(
        .WIDTH(WIDTH)
    ) uut (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .in_x(in_x),
        .rd_addr(rd_addr),
        .out_x_k(out_x_k),
        .out_d(out_d)
    );

    // Clock generator (50 MHz)
    always #(CLK_PERIOD/2) clk = ~clk;

    // Statistics and simulation tracking
    integer success_count = 0;
    integer fail_count = 0;

    // Task for verification
    task verify_read;
        input [2:0] addr;
        input signed [WIDTH-1:0] expected_val;
        begin
            rd_addr = addr;
            #1; // Wait for combinational logic to settle
            if (out_x_k === expected_val) begin
                success_count = success_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] Read Addr %d | Got: %d, Expected: %d", addr, out_x_k, expected_val);
            end
        end
    endtask

    initial begin
        // Initialize inputs
        clk = 0;
        rst = 1;
        sample_valid = 0;
        in_x = 0;
        rd_addr = 0;

        // Apply Reset
        #(CLK_PERIOD * 3);
        @(negedge clk);
        rst = 0;
        #(CLK_PERIOD);

        $display("=========================================================");
        $display(" INICIANDO TESTBENCH DA LINHA DE ATRASO DE ENTRADA (LMS) ");
        $display("=========================================================");

        // --- TEST CASE 1: Inserir Amostra 1 (x = 100) ---
        @(negedge clk);
        in_x = 16'd100;
        sample_valid = 1;
        @(negedge clk);
        sample_valid = 0;
        in_x = 16'd0; // Clear input to verify capture

        // Verificar d(n) capturado (deve ser 100)
        #(CLK_PERIOD);
        if (out_d === 16'd100) begin
            success_count = success_count + 1;
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] out_d Capture | Got: %d, Expected: 100", out_d);
        end

        // No primeiro deslocamento:
        // shift_reg[0] (x(n-1)) deve ser 100
        // Todos os outros devem ser 0
        verify_read(3'd0, 16'd100);
        verify_read(3'd1, 16'd0);
        verify_read(3'd7, 16'd0);

        // --- TEST CASE 2: Inserir Amostra 2 (x = -200) ---
        @(negedge clk);
        in_x = -16'd200;
        sample_valid = 1;
        @(negedge clk);
        sample_valid = 0;
        in_x = 16'd0;

        // d(n) deve atualizar para -200
        #(CLK_PERIOD);
        if (out_d === -16'd200) begin
            success_count = success_count + 1;
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] out_d Capture | Got: %d, Expected: -200", out_d);
        end

        // Registradores de atraso devem conter:
        // shift_reg[0] (x(n-1)) = -200
        // shift_reg[1] (x(n-2)) = 100
        verify_read(3'd0, -16'd200);
        verify_read(3'd1, 16'd100);
        verify_read(3'd2, 16'd0);

        // --- TEST CASE 3: Sequência de escrita (Estresse de Shifting) ---
        // Vamos preencher a linha de atraso com valores: 10, 20, 30, 40, 50, 60, 70, 80
        // Injetando uma amostra de cada vez
        // No final:
        // x(n-1) = 80, x(n-2) = 70, ..., x(n-8) = 10
        begin : stress_shift
            integer k;
            for (k = 1; k <= 8; k = k + 1) begin
                @(negedge clk);
                in_x = k * 10;
                sample_valid = 1;
                @(negedge clk);
                sample_valid = 0;
            end
        end

        #(CLK_PERIOD);
        // Verificando d(n) final (deve ser 80)
        if (out_d === 16'd80) begin
            success_count = success_count + 1;
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] out_d Final Capture | Got: %d, Expected: 80", out_d);
        end

        // Verificando todos os 8 taps sequencialmente
        verify_read(3'd0, 16'd80);  // x(n-1)
        verify_read(3'd1, 16'd70);  // x(n-2)
        verify_read(3'd2, 16'd60);  // x(n-3)
        verify_read(3'd3, 16'd50);  // x(n-4)
        verify_read(3'd4, 16'd40);  // x(n-5)
        verify_read(3'd5, 16'd30);  // x(n-6)
        verify_read(3'd6, 16'd20);  // x(n-7)
        verify_read(3'd7, 16'd10);  // x(n-8)

        // --- TEST CASE 4: Sem alteração quando sample_valid = 0 ---
        // Mudamos in_x, mas como sample_valid = 0, nada deve mudar
        @(negedge clk);
        in_x = 16'd999;
        sample_valid = 0;
        #(CLK_PERIOD * 3);
        
        verify_read(3'd0, 16'd80); // Ainda deve ser 80
        if (out_d === 16'd80) begin
            success_count = success_count + 1;
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Hold state | out_d changed without sample_valid!");
        end

        // --- RELATÓRIO FINAL ---
        $display("=========================================================");
        $display("               RELATÓRIO DE SIMULAÇÃO DA LINHA           ");
        $display("=========================================================");
        $display("  Total de Verificações:  %d", success_count + fail_count);
        $display("  Sucessos:              %d", success_count);
        $display("  Falhas:                 %d", fail_count);
        $display("=========================================================");
        if (fail_count == 0) begin
            $display("  >>> [PASS] LINHA DE ATRASO DE ENTRADA COMPLETAMENTE VALIDADA! <<<");
        end else begin
            $display("  >>> [FAIL] FORAM ENCONTRADOS ERROS NA LINHA DE ATRASO <<<");
        end
        $display("=========================================================");

        $finish;
    end

endmodule
