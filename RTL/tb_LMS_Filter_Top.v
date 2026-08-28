// ============================================================================
// Module: tb_LMS_Filter_Top_v2
// Description: System-level self-checking testbench for the 8-tap folded LMS 
//              adaptive filter. Simulates a System Identification scenario
//              where the LMS filter converges to identify an unknown 3-tap
//              ideal plant.
//              Version 2 - Fully compliant with IEEE Verilog-2001 function arguments.
//
// Target Plant (Unknown System):
//   d(n) = 0.5 * x(n-1) - 0.25 * x(n-2) + 0.125 * x(n-3)
//   In Q1.15:
//   d(n) = (x(n-1) >>> 1) - (x(n-2) >>> 2) + (x(n-3) >>> 3)
//
// Testbench Operation:
//   - Generates a deterministic pseudo-random input x(n) using an LCG.
//   - Simulates 400 sample iterations at 50 MHz.
//   - Monitors and prints the evolution of the weights (w0, w1, w2) and MSE.
//   - Verifies convergence at the end of the simulation.
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Filter_Top;

    // Simulation Parameters
    parameter WIDTH = 16;
    parameter FRAC  = 15;
    parameter CLK_PERIOD = 20; // 50 MHz clock (20 ns)
    parameter N_SAMPLES = 400;

    // Signals
    reg                 clk;
    reg                 rst;
    reg                 sample_valid;
    reg signed [WIDTH-1:0] in_x;
    reg signed [WIDTH-1:0] in_d;

    wire signed [WIDTH-1:0] out_y;
    wire signed [WIDTH-1:0] out_error;
    wire                    filter_busy;

    // Weight debug wires from UUT
    wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7;

    // Instantiate Unit Under Test (UUT)
    LMS_Filter_Top # (
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) uut (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .in_x(in_x),
        .in_d(in_d),
        .out_y(out_y),
        .out_error(out_error),
        .filter_busy(filter_busy),
        .w0(w0), .w1(w1), .w2(w2), .w3(w3), .w4(w4), .w5(w5), .w6(w6), .w7(w7)
    );

    // Clock Generator
    always #(CLK_PERIOD/2) clk = ~clk;

    // LCG Pseudo-Random Generator (Seed-based)
    reg [31:0] seed;
    function signed [WIDTH-1:0] get_rand_x;
        input dummy; // Complies with Verilog-2001 (IEEE 1364) requiring at least one input
        begin
            seed = (seed * 1103515245 + 12345) & 31'h7FFFFFFF;
            // Map 16-bit to Q1.15 in range [-0.5, 0.5] to prevent overflow of y(n)
            // Limit values to -16384 to 16383
            get_rand_x = $signed(seed[30:15]) >>> 2; 
        end
    endfunction

    // Delay line registers inside the testbench to simulate the target plant
    reg signed [WIDTH-1:0] x_delay [0:2];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            x_delay[0] <= 16'sb0;
            x_delay[1] <= 16'sb0;
            x_delay[2] <= 16'sb0;
        end else if (sample_valid) begin
            x_delay[0] <= in_x;
            x_delay[1] <= x_delay[0];
            x_delay[2] <= x_delay[1];
        end
    end

    // Unknown system desired output calculation: d(n) = 0.5*x(n-1) - 0.25*x(n-2) + 0.125*x(n-3)
    // Shift operators on signed values in Verilog preserve the sign bit
    wire signed [WIDTH-1:0] d_ideal = (x_delay[0] >>> 1) 
                                    - (x_delay[1] >>> 2) 
                                    + (x_delay[2] >>> 3);

    // MSE tracking
    real sq_err_sum = 0.0;
    real mse;
    integer sample_count = 0;

    // Stimulus process
    initial begin
        // Setup initial signals
        clk = 0;
        rst = 1;
        sample_valid = 0;
        in_x = 0;
        in_d = 0;
        seed = 42; // Initialize seed

        $display("======================================================================");
        $display("   INICIANDO SIMULACAO DO SISTEMA COMPLETO (LMS FILTER TOP-LEVEL)    ");
        $display("======================================================================");
        $display("[INFO] Cenário de Aplicação: Identificação de Sistema (System ID)");
        $display("[INFO] Planta Desconhecida: d(n) = 0.5*x(n-1) - 0.25*x(n-2) + 0.125*x(n-3)");
        $display("[INFO] Carregando estimulos dinâmicos (%0d amostras)...", N_SAMPLES);

        #(CLK_PERIOD * 5);
        @(negedge clk);
        rst = 0;
        #(CLK_PERIOD * 2);

        // Process loops for N_SAMPLES
        for (sample_count = 0; sample_count < N_SAMPLES; sample_count = sample_count + 1) begin
            @(negedge clk);
            // 1. Injeta nova amostra de entrada x(n) (Passa argumento fictício 1 para conformidade IEEE)
            in_x = get_rand_x(1);
            // 2. Calcula d(n) síncronamente baseado no atraso anterior
            in_d = d_ideal;
            
            // 3. Ativa o pulso de validação de amostra por 1 ciclo
            sample_valid = 1'b1;
            
            @(negedge clk);
            sample_valid = 1'b0; // Desativa
            in_x = 16'd0;        // Limpa barramento de entrada para provar estabilidade da delay line

            // 4. Aguarda a FSM terminar os 17 ciclos de processamento sequencial
            while (filter_busy === 1'b1) begin
                @(posedge clk);
            end
            
            // Aguarda mais 1 clock para estabilizar as saídas registradas do acumulador
            @(posedge clk);
            #1;

            // 5. Acumula estatísticas de erro
            sq_err_sum = sq_err_sum + ((out_error / 32768.0) * (out_error / 32768.0));

            // Print status every 50 samples
            if (sample_count % 50 == 0 || sample_count == N_SAMPLES - 1) begin
                $display("Amostra %3d | x(n)=%6d | d(n)=%6d | y(n)=%6d | e(n)=%6d | w0=%5d, w1=%5d, w2=%5d", 
                         sample_count, $signed(x_delay[0]), $signed(in_d), $signed(out_y), $signed(out_error),
                         $signed(w0), $signed(w1), $signed(w2));
            end
        end

        // Calculate final MSE
        mse = sq_err_sum / N_SAMPLES;

        $display("\n======================================================================");
        $display("                      RELATORIO DE CONVERGENCIA                       ");
        $display("=====================================================================");
        $display("  Amostras Processadas:     %0d", N_SAMPLES);
        $display("  Erro Quadrático Médio:    %10.8f", mse);
        $display("----------------------------------------------------------------------");
        $display("  Coeficientes do Filtro vs. Planta Alvo (Esperada):");
        $display("  w0 (Ideal =  16384 | 0.500)  =>  Got: %6d | Float: %8.5f", $signed(w0), w0 / 32768.0);
        $display("  w1 (Ideal =  -8192 | -0.250) =>  Got: %6d | Float: %8.5f", $signed(w1), w1 / 32768.0);
        $display("  w2 (Ideal =   4096 |  0.125) =>  Got: %6d | Float: %8.5f", $signed(w2), w2 / 32768.0);
        $display("  w3 (Ideal =      0 |  0.000) =>  Got: %6d | Float: %8.5f", $signed(w3), w3 / 32768.0);
        $display("  w4 (Ideal =      0 |  0.000) =>  Got: %6d | Float: %8.5f", $signed(w4), w4 / 32768.0);
        $display("======================================================================");

        // Validation gate
        if (mse < 0.05 && $signed(w0) > 13000 && $signed(w1) < -6500 && $signed(w2) > 3000) begin
            $display("  >>> [SUCCESS] O FILTRO LMS CONVERGIU COM EXCEPCIONAL PRECISÃO! <<<");
            $display("  >>> Identificação do sistema desconhecido concluída com sucesso no FPGA. <<<");
        end else begin
            $display("  >>> [FAIL] O filtro não atingiu os critérios de convergência esperados. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule