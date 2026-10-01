// ============================================================================
// Module: tb_LMS_Processing_Element
// Description: Self-checking testbench to validate the LMS_Processing_Element
//              module in Verilog under Q1.15 fixed-point arithmetic.
//
// Tests:
//   - Initial reset states
//   - Phase 1 (Filtering/Convolution) latency and mathematical accuracy
//   - Phase 2 (Weight Update) latency, delay alignments, and arithmetic accuracy
//   - Pipeline overlapping test with back-to-back operations
//   - Statistical success and failure counters
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Processing_Element;

    // Simulation Parameters
    parameter WIDTH = 16;
    parameter FRAC  = 15;
    parameter CLK_PERIOD = 20; // 50 MHz Clock (20 ns period)

    // Signals
    reg                 clk;
    reg                 rst;
    reg                 sel;
    reg                 valid_in;
    reg signed [WIDTH-1:0] in_x;
    reg signed [WIDTH-1:0] in_w;
    reg signed [WIDTH-1:0] in_u_e;

    wire signed [WIDTH-1:0] out_y_part;
    wire signed [WIDTH-1:0] out_w_next;
    wire                    valid_y_part;
    wire                    valid_w_next;

    // Testbench Variables
    integer success_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    // Instantiate Unit Under Test (UUT)
    LMS_Processing_Element #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) uut (
        .clk(clk),
        .rst(rst),
        .sel(sel),
        .valid_in(valid_in),
        .in_x(in_x),
        .in_w(in_w),
        .in_u_e(in_u_e),
        .out_y_part(out_y_part),
        .out_w_next(out_w_next),
        .valid_y_part(valid_y_part),
        .valid_w_next(valid_w_next)
    );

    // Clock Generator (50 MHz)
    always #(CLK_PERIOD/2) clk = ~clk;

    // Sychronous Queues to track expected values through the pipelines
    // Delay lines for expected outputs
    reg signed [WIDTH-1:0] exp_y_queue [0:2];
    reg                    exp_valid_y_queue [0:2];
    
    reg signed [WIDTH-1:0] exp_w_queue [0:4];
    reg                    exp_valid_w_queue [0:4];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 3; k = k + 1) begin
                exp_y_queue[k]       <= 16'sb0;
                exp_valid_y_queue[k] <= 1'b0;
            end
            for (k = 0; k < 5; k = k + 1) begin
                exp_w_queue[k]       <= 16'sb0;
                exp_valid_w_queue[k] <= 1'b0;
            end
        end else begin
            // Shift Delay lines
            exp_y_queue[0]       <= (sel == 1'b0 && valid_in) ? calc_y(in_x, in_w) : 16'sb0;
            exp_valid_y_queue[0] <= (sel == 1'b0 && valid_in);
            for (k = 1; k < 3; k = k + 1) begin
                exp_y_queue[k]       <= exp_y_queue[k-1];
                exp_valid_y_queue[k] <= exp_valid_y_queue[k-1];
            end

            exp_w_queue[0]       <= (sel == 1'b1 && valid_in) ? calc_w(in_x, in_w, in_u_e) : 16'sb0;
            exp_valid_w_queue[0] <= (sel == 1'b1 && valid_in);
            for (k = 1; k < 5; k = k + 1) begin
                exp_w_queue[k]       <= exp_w_queue[k-1];
                exp_valid_w_queue[k] <= exp_valid_w_queue[k-1];
            end
        end
    end

    // Mathematical reference functions matching hardware (Q1.15 rounding and saturation)
    function signed [WIDTH-1:0] calc_y;
        input signed [WIDTH-1:0] x;
        input signed [WIDTH-1:0] w;
        reg signed [31:0] raw_prod;
        reg signed [31:0] rounded_prod;
        reg signed [15:0] result;
        begin
            raw_prod = x * w;
            rounded_prod = raw_prod + 32'h00004000; // Rounding term: 2^(15-1)
            result = rounded_prod >>> 15;
            
            // Saturation limits check
            if (raw_prod[31] == 1'b0 && result[15] == 1'b1) begin
                calc_y = 16'h7FFF; // Positive Overflow Saturated
            end else if (raw_prod[31] == 1'b1 && result[15] == 1'b0) begin
                calc_y = 16'h8000; // Negative Overflow Saturated
            end else begin
                calc_y = result;
            end
        end
    endfunction

    function signed [WIDTH-1:0] calc_w;
        input signed [WIDTH-1:0] x;
        input signed [WIDTH-1:0] w;
        input signed [WIDTH-1:0] u_e;
        reg signed [31:0] raw_prod;
        reg signed [31:0] rounded_prod;
        reg signed [15:0] delta_w;
        reg signed [16:0] sum_temp; // Extra bit for intermediate sum
        begin
            raw_prod = x * u_e;
            rounded_prod = raw_prod + 32'h00004000;
            delta_w = rounded_prod >>> 15;
            
            // Saturated multiplication delta_w
            if (raw_prod[31] == 1'b0 && delta_w[15] == 1'b1) begin
                delta_w = 16'h7FFF;
            end else if (raw_prod[31] == 1'b1 && delta_w[15] == 1'b0) begin
                delta_w = 16'h8000;
            end
            
            sum_temp = w + delta_w;
            
            // Saturation for final addition
            if (sum_temp[16] == 1'b0 && sum_temp[15] == 1'b1) begin
                calc_w = 16'h7FFF; // Overflow positive
            end else if (sum_temp[16] == 1'b1 && sum_temp[15] == 1'b0) begin
                calc_w = 16'h8000; // Underflow negative
            end else begin
                calc_w = sum_temp[15:0];
            end
        end
    endfunction

    // ---- MONITOR COMPORTAMENTAL SÍNCRONO ----
    // Checks outputs at every rising clock edge based on queue models
    always @(posedge clk) begin
        #1; // Wait 1ns after clock edge to avoid race condition in simulation
        if (!rst) begin
            // 1. Check out_y_part validation (Phase 1 Filtering)
            if (exp_valid_y_queue[2]) begin
                total_tests = total_tests + 1;
                if (valid_y_part !== 1'b1) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL: VALID] Filtering valid_y_part is low! Expected high.");
                end else if (out_y_part === exp_y_queue[2]) begin
                    success_count = success_count + 1;
                    $display("[PASS: Y_PART] Expected = %d (hex: %h) | Got = %d (hex: %h)", 
                             exp_y_queue[2], exp_y_queue[2], out_y_part, out_y_part);
                end else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL: Y_PART] Math mismatch in Filtering! Expected = %d (hex: %h) | Got = %d (hex: %h)", 
                             exp_y_queue[2], exp_y_queue[2], out_y_part, out_y_part);
                end
            end else if (valid_y_part === 1'b1) begin
                // If output valid is high when it should be low
                total_tests = total_tests + 1;
                fail_count = fail_count + 1;
                $display("[FAIL: SPURIOUS] Spurious valid_y_part detected!");
            end

            // 2. Check out_w_next validation (Phase 2 Weight Update)
            if (exp_valid_w_queue[4]) begin
                total_tests = total_tests + 1;
                if (valid_w_next !== 1'b1) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL: VALID] Weight update valid_w_next is low! Expected high.");
                end else if (out_w_next === exp_w_queue[4]) begin
                    success_count = success_count + 1;
                    $display("[PASS: W_NEXT] Expected = %d (hex: %h) | Got = %d (hex: %h)", 
                             exp_w_queue[4], exp_w_queue[4], out_w_next, out_w_next);
                end else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL: W_NEXT] Math mismatch in Weight Update! Expected = %d (hex: %h) | Got = %d (hex: %h)", 
                             exp_w_queue[4], exp_w_queue[4], out_w_next, out_w_next);
                end
            end else if (valid_w_next === 1'b1) begin
                // If output valid is high when it should be low
                total_tests = total_tests + 1;
                fail_count = fail_count + 1;
                $display("[FAIL: SPURIOUS] Spurious valid_w_next detected!");
            end
        end
    end

    // ---- ROTINA PRINCIPAL DE ESTÍMULOS ----
    initial begin
        // Setup outputs & initial signals
        clk = 0;
        rst = 1;
        sel = 0;
        valid_in = 0;
        in_x = 0;
        in_w = 0;
        in_u_e = 0;

        $display("======================================================================");
        $display("   INICIANDO SIMULACAO DO ELEMENTO DE PROCESSAMENTO (LMS PE) - Q1.15  ");
        $display("======================================================================");

        // Reset system
        #(CLK_PERIOD * 3);
        rst = 0;
        $display("[INFO] Reset desativado, iniciando estimulos sintonizados síncronos.");

        // --------------------------------------------------------------------
        // TESTE 1: FASE 1 - FILTRAGEM (Operacoes de Multiplicacao FIR)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 1: Fase 1 (Filtragem FIR - Latencia de 3 Clocks) ---");
        
        // Injetando Amostra 1: x = 0.5 (16384), w = 0.8 (26214) => Esperado Y = 0.4 (13107)
        @(negedge clk);
        sel      = 1'b0;
        valid_in = 1'b1;
        in_x     = 16'h4000; // 0.5
        in_w     = 16'h6666; // 0.8
        in_u_e   = 16'h0000;

        // Injetando Amostra 2 (overlapping no pipeline): x = -0.25 (-8192), w = -0.4 (-13107) => Esperado Y = 0.10 (3277)
        @(negedge clk);
        in_x     = 16'hE000; // -0.25
        in_w     = 16'hCCCC; // -0.4

        // Injetando Amostra 3 (limite superior positivo): x = 0.999 (32735), w = 0.999 (32735) => Esperado Y = 0.998 (32702)
        @(negedge clk);
        in_x     = 16'h7FDF; // 0.999
        in_w     = 16'h7FDF; // 0.999

        // Desativa entrada de dados síncronos
        @(negedge clk);
        valid_in = 1'b0;
        in_x     = 16'h0000;
        in_w     = 16'h0000;

        // Aguarda os dados terminarem de circular pelo pipeline (3 clocks)
        #(CLK_PERIOD * 4);

        // --------------------------------------------------------------------
        // TESTE 2: FASE 2 - ATUALIZACAO DE PESOS (Operacoes de Ajuste)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 2: Fase 2 (Atualizacao de Pesos - Latencia de 5 Clocks) ---");

        // Injetando Ajuste 1: x = 0.5 (16384), w = 0.8 (26214), u_e = 0.0625 (2048)
        // delta_w = 0.5 * 0.0625 = 0.03125 (1024)
        // w_next = 0.8 + 0.03125 = 0.83125 (27238 -> hex: 16'h6A66)
        @(negedge clk);
        sel      = 1'b1;
        valid_in = 1'b1;
        in_x     = 16'h4000; // x = 0.5
        in_w     = 16'h6666; // w = 0.8
        in_u_e   = 16'h0800; // u_e = 0.0625

        // Injetando Ajuste 2 (Foco em negativo): x = -0.25 (-8192), w = -0.4 (-13107), u_e = 0.0625 (2048)
        // delta_w = -0.25 * 0.0625 = -0.015625 (-512)
        // w_next = -0.4 + (-0.015625) = -0.415625 (-13619 -> hex: 16'hCAAD)
        @(negedge clk);
        in_x     = 16'hE000; // x = -0.25
        in_w     = 16'hCCCC; // w = -0.4
        in_u_e   = 16'h0800; // u_e = 0.0625

        // Injetando Ajuste 3 (Saturacao Overflow Positivo): w = MaxPos (32767), delta_w = positivo (512) => w_next = MaxPos
        @(negedge clk);
        in_x     = 16'h4000; // 0.5
        in_w     = 16'h7FFF; // 0.9999 (MaxPos)
        in_u_e   = 16'h0400; // 0.03125 (delta_w = 512)

        // Injetando Ajuste 4 (Saturacao Overflow Negativo): w = MinNeg (-32768), delta_w = negativo (-512) => w_next = MinNeg
        @(negedge clk);
        in_x     = 16'hE000; // -0.25
        in_w     = 16'h8000; // -1.0 (MinNeg)
        in_u_e   = 16'h0800; // 0.0625 (delta_w = -512)

        // Finaliza entradas
        @(negedge clk);
        valid_in = 1'b0;
        in_x     = 16'h0000;
        in_w     = 16'h0000;
        in_u_e   = 16'h0000;

        // Aguarda os dados terminarem de circular pelo pipeline (5 clocks)
        #(CLK_PERIOD * 6);

        // --------------------------------------------------------------------
        // TESTE 3: FLUXO CONTINUO MISTO DE PIPELINE (ESTRESSE)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 3: Fluxo de Estresse Misto (Overlapping) ---");

        // Transicoes continuas simulando ciclos rapidos do filtro LMS
        @(negedge clk);
        sel      = 1'b0; // Fase 1 (Filtragem)
        valid_in = 1'b1;
        in_x     = 16'h2000; // 0.25
        in_w     = 16'h4000; // 0.5
        
        @(negedge clk);
        in_x     = 16'h1000; // 0.125
        in_w     = 16'h2000; // 0.25

        @(negedge clk);
        sel      = 1'b1; // Troca síncrona de fase sem parar o pipeline
        in_x     = 16'h4000; // 0.5
        in_w     = 16'h3000; // 0.375
        in_u_e   = 16'h0800; // 0.0625 (delta_w = 512, w_next = 0.375 + 0.03125 = 0.40625)

        @(negedge clk);
        valid_in = 1'b0;

        #(CLK_PERIOD * 8);

        // --------------------------------------------------------------------
        // CONSOLIDACAO DOS RESULTADOS
        // --------------------------------------------------------------------
        $display("\n======================================================================");
        $display("                      RELATORIO FINAL DE SIMULACAO                    ");
        $display("======================================================================");
        $display("  Total de Operacoes Verificadas: %d", total_tests);
        $display("  Sucessos Confirmados:           %d", success_count);
        $display("  Falhas Detectadas:              %d", fail_count);
        $display("======================================================================");

        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> [CONGRATS] O ELEMENTO DE PROCESSAMENTO (PE) PASSOU EM TODOS OS TESTES! <<<");
            $display("  >>> Lógica de dados, seleção de multiplexadores e alinhamento do pipeline validados. <<<");
        end else begin
            $display("  >>> [ERROR] Falhas identificadas no processamento. Verifique as mensagens acima. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule
