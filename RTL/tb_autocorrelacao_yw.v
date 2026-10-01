`timescale 1ns/1ps

// =====================================================================
// tb_autocorrelacao_yw.v
//
// Testbench focado exclusivamente na validação do módulo autocorrelacao_yw.
// Lê 64 amostras do arquivo amostras_lms.txt (formato Hex Q4.12),
// envia sequencialmente para o DUT e exibe os resultados dos lags r[0..4]
// tanto em hexadecimal quanto em valores reais (ponto flutuante).
//
// USO: Apenas para simulação (ModelSim / EDA Playground / Icarus Verilog).
// =====================================================================

module tb_autocorrelacao_yw();

    localparam WIDTH = 16;
    localparam FRAC  = 12;

    reg clk;
    reg reset;

    // Sinais da interface do DUT
    reg                     lms_valid;
    reg  signed [WIDTH-1:0] lms_data;
    wire                    busy;
    wire                    r_valid;
    wire        [2:0]       r_index;
    wire signed [WIDTH-1:0] r_data;

    // Memória para carregar as amostras do arquivo externo
    reg signed [WIDTH-1:0] memoria_amostras [0:63];

    // Vetor para capturar as saídas calculadas (r[0] até r[4])
    reg signed [WIDTH-1:0] r_resultado [0:4];

    integer i;

    // -----------------------------------------------------------------
    // Instanciação do Módulo em Teste (DUT)
    // -----------------------------------------------------------------
    autocorrelacao_yw #(
        .WIDTH(WIDTH),
        .FRAC (FRAC)
    ) dut (
        .clk       (clk),
        .reset     (reset),
        .lms_valid (lms_valid),
        .lms_data  (lms_data),
        .busy      (busy),
        .r_valid   (r_valid),
        .r_index   (r_index),
        .r_data    (r_data)
    );

    // -----------------------------------------------------------------
    // Geração do Clock (50 MHz -> Período de 20 ns)
    // -----------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // -----------------------------------------------------------------
    // Função auxiliar para converter Q4.12 em número real (float/double)
    // -----------------------------------------------------------------
    function real q_to_real;
        input signed [WIDTH-1:0] valor;
        begin
            q_to_real = $itor(valor) / (2.0 ** FRAC);
        end
    endfunction

    // -----------------------------------------------------------------
    // Captura dos dados válidos na saída do módulo
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (r_valid) begin
            r_resultado[r_index] <= r_data;
            $display("[SAÍDA DETECTADA] r_index = %0d | r_data = %h (hex) | Real = %f", 
                     r_index, r_data, q_to_real(r_data));
        end
    end

    // -----------------------------------------------------------------
    // Sequência de Teste Principal
    // -----------------------------------------------------------------
    initial begin
        // Carrega o arquivo de amostras fornecido
        $readmemh("amostras_lms.txt", memoria_amostras);

        // Inicialização de Sinais
        lms_valid = 0;
        lms_data  = 0;
        reset     = 1;

        #40;
        reset = 0;
        #20;

        $display("=========================================================");
        $display("  INICIANDO TESTE ISOLADO: AUTOCORRELACAO YULE-WALKER    ");
        $display("=========================================================");

        // Injeção sequencial das 64 amostras
        $display("[TB] Enviando 64 amostras para o modulo...");
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            lms_valid <= 1'b1;
            lms_data  <= memoria_amostras[i];
        end

        @(posedge clk);
        lms_valid <= 1'b0;
        lms_data  <= 16'd0;

        $display("[TB] Aguardando processamento e normalizacao...");

        // Aguarda a FSM concluir todos os cálculos e transmissões
        wait (busy == 1'b1);
        wait (busy == 1'b0);

        @(posedge clk);
        #10;

        // Impressão do Relatório Final de Resultados
        $display("");
        $display("=========================================================");
        $display("             RESULTADO DA AUTOCORRELAÇÃO                 ");
        $display("=========================================================");
        for (i = 0; i < 5; i = i + 1) begin
            $display("  r[%0d] = %h (hex) | %f (real)", i, r_resultado[i], q_to_real(r_resultado[i]));
        end
        $display("=========================================================");

        // Verificação rápida de validação
        if (r_resultado[0] == 16'h1000) begin
            $display("[SUCESSO] r[0] e exatamente 1.0 (1000h em Q4.12), indicando normalizacao correta!");
        end else begin
            $display("[ALERTA] r[0] difere de 1.0. Verifique a etapa de divisao.");
        end

        $stop;
    end

endmodule
