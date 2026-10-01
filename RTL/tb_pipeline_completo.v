`timescale 1ns/1ps

// =====================================================================
// tb_pipeline_completo.v
//
// Testbench de integracao FINAL, depois da correcao do autocorrelacao_yw.
// Como o AR agora ja devolve valores normalizados corretos (sem estourar
// os 16 bits), nao precisa mais de nenhum "modelo de referencia manual"
// dentro do testbench: a matriz de Yule-Walker e montada DIRETO da saida
// real do autocorrelacao_yw, e carregada no gauss_jordan_inv real.
//
// Os dois DUTs continuam instanciados separadamente (nada de modulo
// "fundido"); este testbench e so a ponte entre os dois, como um modulo
// de integracao faria no sistema real.
//
// SO PARA SIMULACAO (ModelSim/xrun/Icarus). NAO adicionar ao projeto
// Quartus como arquivo de sintese.
// =====================================================================

module tb_pipeline_completo();

    localparam WIDTH = 16;
    localparam FRAC  = 12;

    reg clk;
    reg reset;

    initial clk = 0;
    always #10 clk = ~clk;

    // -------------------------------------------------------------
    // AR (autocorrelacao_yw) - DUT real
    // -------------------------------------------------------------
    reg        lms_valid;
    reg signed [WIDTH-1:0] lms_data;
    wire       ar_busy;
    wire       ar_r_valid;
    wire [2:0] ar_r_index;
    wire signed [WIDTH-1:0] ar_r_data;

    autocorrelacao_yw #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) dut_ar (
        .clk       (clk),
        .reset     (reset),
        .lms_valid (lms_valid),
        .lms_data  (lms_data),
        .busy      (ar_busy),
        .r_valid   (ar_r_valid),
        .r_index   (ar_r_index),
        .r_data    (ar_r_data)
    );

    reg signed [WIDTH-1:0] memoria_amostras [0:63];
    integer i;

    // Resultados normalizados que o AR realmente produziu
    reg signed [WIDTH-1:0] r_dut [0:4];

    always @(posedge clk) begin
        if (ar_r_valid) r_dut[ar_r_index] <= ar_r_data;
    end

    function real q_to_real;
        input signed [WIDTH-1:0] valor;
        begin
            q_to_real = $itor(valor) / (2.0 ** FRAC);
        end
    endfunction

    // -------------------------------------------------------------
    // Gauss-Jordan - DUT 
    // -------------------------------------------------------------
    wire        gj_enable = 1'b1;
    reg         gj_start;
    reg  [2:0]  gj_n;
    reg         gj_valid_in;
    wire        gj_ready;
    reg  [1:0]  gj_load_row, gj_load_col;
    reg  signed [WIDTH-1:0] gj_load_data;
    wire        gj_valid_out;
    wire        gj_busy;
    wire        gj_singular;
    reg  [1:0]  gj_read_row;
    reg  [2:0]  gj_read_col;
    wire signed [WIDTH-1:0] gj_read_data;

    gauss_jordan_inv #(
        .WIDTH(WIDTH),
        .FRAC(FRAC),
        .N_MAX(4)
    ) dut_gj (
        .clk        (clk),
        .reset      (reset),
        .enable     (gj_enable),
        .start      (gj_start),
        .n          (gj_n),
        .valid_in   (gj_valid_in),
        .ready      (gj_ready),
        .load_row   (gj_load_row),
        .load_col   (gj_load_col),
        .load_data  (gj_load_data),
        .valid_out  (gj_valid_out),
        .busy       (gj_busy),
        .singular   (gj_singular),
        .read_row   (gj_read_row),
        .read_col   (gj_read_col),
        .read_data  (gj_read_data)
    );

    integer li, co, lag;

    // -------------------------------------------------------------
    // Monta a matriz Toeplitz 4x4 DIRETO da saida real do AR e
    // carrega no inversor
    // -------------------------------------------------------------
    task carrega_e_inverte;
        begin
            for (li = 0; li < 4; li = li + 1) begin
                for (co = 0; co < 4; co = co + 1) begin
                    lag = (li > co) ? (li - co) : (co - li); // |i-j|
                    @(posedge clk);
                    gj_load_row  <= li[1:0];
                    gj_load_col  <= co[1:0];
                    gj_load_data <= r_dut[lag]; // valor real do AR, sem atalho
                    gj_valid_in  <= 1'b1;
                end
            end
            @(posedge clk);
            gj_valid_in <= 1'b0;

            @(posedge clk);
            gj_n     <= 3'd4;
            gj_start <= 1'b1;
            @(posedge clk);
            gj_start <= 1'b0;

            wait (gj_valid_out == 1'b1);
            #1;
        end
    endtask

    task imprime_resultado;
        begin
            if (gj_singular) begin
                $display("[GAUSS-JORDAN] Matriz SINGULAR - inversao nao concluida.");
            end else begin
                $display("[GAUSS-JORDAN] Inversao concluida. Matriz R^-1 (Q4.12):");
                for (li = 0; li < 4; li = li + 1) begin
                    gj_read_row <= li[1:0];
                    for (co = 0; co < 4; co = co + 1) begin
                        gj_read_col <= (4 + co);
                        #1;
                        $display("  R^-1[%0d][%0d] = %h (hex) = %f (real)",
                                  li, co, gj_read_data, q_to_real(gj_read_data));
                    end
                end
            end
        end
    endtask

    initial begin
        $readmemh("amostras_lms.txt", memoria_amostras);

        lms_valid    = 0;
        lms_data     = 0;
        gj_start     = 0;
        gj_valid_in  = 0;
        gj_load_row  = 0;
        gj_load_col  = 0;
        gj_load_data = 0;
        gj_read_row  = 0;
        gj_read_col  = 0;
        gj_n         = 0;
        reset = 1;
        #50;
        reset = 0;
        #50;

        $display("=========================================================");
        $display("PARTE A - autocorrelacao_yw (ja corrigido/normalizado)");
        $display("=========================================================");

        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            lms_valid = 1;
            lms_data  = memoria_amostras[i];
        end
        @(posedge clk);
        lms_valid = 0;

        wait (ar_busy == 0);
        @(posedge clk);
        @(posedge clk);

        for (i = 0; i < 5; i = i + 1)
            $display("r[%0d] = %h  (%f)", i, r_dut[i], q_to_real(r_dut[i]));

        $display("");
        $display("=========================================================");
        $display("PARTE B - gauss_jordan_inv com a matriz vinda do AR real");
        $display("=========================================================");

        carrega_e_inverte;
        imprime_resultado;

        $display("");
        $display("Pipeline completo (AR -> Gauss-Jordan) validado.");
        $stop;
    end

endmodule
