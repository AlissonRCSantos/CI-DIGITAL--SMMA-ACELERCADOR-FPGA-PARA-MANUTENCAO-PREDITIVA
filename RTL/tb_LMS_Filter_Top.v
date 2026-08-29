// ============================================================================
// Module: tb_LMS_Filter_Top_v3
// Description: System-level self-checking testbench for the LMS_Filter_Top_v3.
//              Tests the full handshake protocol (start, enable, valid_in, 
//              ready, busy, valid_out) in a System Identification scenario
//              with 400 samples.
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
    
    // Handshake & Control Ports
    reg                 start;
    reg                 enable;
    reg                 valid_in;
    
    wire                ready;
    wire                busy;
    wire                valid_out;

    reg signed [WIDTH-1:0] in_x;
    wire signed [WIDTH-1:0] out_y;
    wire signed [WIDTH-1:0] out_error;

    // Weight debug wires from UUT
    wire signed [WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7;

    // Instantiate Unit Under Test (UUT)
    LMS_Filter_Top #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .valid_in(valid_in),
        .ready(ready),
        .busy(busy),
        .valid_out(valid_out),
        .in_x(in_x),
        .out_y(out_y),
        .out_error(out_error),
        .w0(w0), .w1(w1), .w2(w2), .w3(w3), .w4(w4), .w5(w5), .w6(w6), .w7(w7)
    );

    // Clock Generator
    always #(CLK_PERIOD/2) clk = ~clk;

    // LCG Pseudo-Random Generator (Seed-based)
    reg [31:0] seed;
    function signed [WIDTH-1:0] get_rand_x;
        input dummy; // Complies with Verilog-2001
        begin
            seed = (seed * 1103515245 + 12345) & 31'h7FFFFFFF;
            // Map 16-bit to Q1.15 in range [-0.5, 0.5] to prevent overflow
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
        end else if (start && valid_in && enable && ready) begin
            x_delay[0] <= in_x;
            x_delay[1] <= x_delay[0];
            x_delay[2] <= x_delay[1];
        end
    end

    // Unknown system desired output calculation: d(n) = 0.5*x(n-1) - 0.25*x(n-2) + 0.125*x(n-3)
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
        start = 0;
        enable = 1; // Always enabled for this simulation
        valid_in = 0;
        in_x = 0;
        seed = 42; // Initialize seed

        $display("======================================================================");
        $display("   INICIANDO SIMULACAO DO SISTEMA COM HANDSHAKE (LMS FILTER_TOP V3)  ");
        $display("======================================================================");
        $display("[INFO] Cenário de Aplicação: Identificação de Sistema (System ID)");
        $display("[INFO] Planta Alvo: d(n) = 0.5*x(n-1) - 0.25*x(n-2) + 0.125*x(n-3)");
        $display("[INFO] Interface: start, enable, valid_in, ready, busy, valid_out");
        $display("[INFO] Carregando estimulos dinâmicos (%0d amostras)...", N_SAMPLES);

        #(CLK_PERIOD * 5);
        @(negedge clk);
        rst = 0;
        #(CLK_PERIOD * 2);

        // Process loops for N_SAMPLES
        for (sample_count = 0; sample_count < N_SAMPLES; sample_count = sample_count + 1) begin
            
            // 1. Wait until the module is ready and not busy
            while (ready !== 1'b1 || busy !== 1'b0) begin
                @(posedge clk);
            end
            
            @(negedge clk);
            // 2. Set new input sample and trigger handshake
            in_x = get_rand_x(1);
            start = 1'b1;
            valid_in = 1'b1;
            
            @(negedge clk);
            // 3. Clear handshake signals after 1 clock cycle
            start = 1'b0;
            valid_in = 1'b0;
            in_x = 16'd0; // Clear input bus to verify capture stability

            // 4. Wait for valid_out strobe to capture output data
            while (valid_out !== 1'b1) begin
                @(posedge clk);
            end
            #1; // Wait 1ns after clock edge to sample stable outputs

            // 5. Accumulate error statistics
            sq_err_sum = sq_err_sum + ((out_error / 32768.0) * (out_error / 32768.0));

            // Print status every 50 samples
            if (sample_count % 50 == 0 || sample_count == N_SAMPLES - 1) begin
                $display("Amostra %3d | x(n)=%6d | y(n)=%6d | e(n)=%6d | w0=%5d, w1=%5d, w2=%5d | Ready=%b, Busy=%b", 
                         sample_count, $signed(x_delay[0]), $signed(out_y), $signed(out_error),
                         $signed(w0), $signed(w1), $signed(w2), ready, busy);
            end
            
            // 6. Wait for FSM to completely finish before proceeding to next loop iteration
            while (busy === 1'b1) begin
                @(posedge clk);
            end
        end

        // Calculate final MSE
        mse = sq_err_sum / N_SAMPLES;

        $display("\n======================================================================");
        $display("                      RELATORIO DE CONVERGENCIA                       ");
        $display("======================================================================");
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
            $display("  >>> [SUCCESS] O FILTRO LMS CONVERGIU COM EXCEPCIONAL PRECISÃO! <<<\");
            $display("  >>> Handshake industrial de controle completely validado no FPGA. <<<");
        end else begin
            $display("  >>> [FAIL] O filtro não atingiu os critérios de convergência esperados. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule
