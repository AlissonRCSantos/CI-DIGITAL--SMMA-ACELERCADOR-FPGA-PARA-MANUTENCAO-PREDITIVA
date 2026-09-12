// ============================================================================
// Module: tb_LMS_Control_FSM
// Description: Testbench corrigida para validar os 26 ciclos da LMS_Control_FSM
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Control_FSM;

    // Signals
    reg         clk;
    reg         rst;
    reg         start;
    reg         enable;
    reg         valid_in;

    wire        ready;
    wire        busy;
    wire        valid_out;
    wire        load_sample;
    wire [2:0]  rd_addr;
    wire        pe_sel;
    wire        pe_valid;
    wire        clear_acc;
    wire [2:0]  wr_addr;
    wire        wr_en_gate;

    // Testbench stats
    integer success_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    // Instantiate Unit Under Test (UUT)
    LMS_Control_FSM uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .valid_in(valid_in),
        .ready(ready),
        .busy(busy),
        .valid_out(valid_out),
        .load_sample(load_sample),
        .rd_addr(rd_addr),
        .pe_sel(pe_sel),
        .pe_valid(pe_valid),
        .clear_acc(clear_acc),
        .wr_addr(wr_addr),
        .wr_en_gate(wr_en_gate)
    );

    // Clock Generator (50 MHz, 20 ns period)
    parameter CLK_PERIOD = 20;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Task de verificação
    task check_outputs;
        input [4:0] exp_counter;
        input       exp_busy;
        input       exp_ready;
        input       exp_valid_out;
        input       exp_load_sample;
        input [2:0] exp_rd_addr;
        input       exp_pe_sel;
        input       exp_pe_valid;
        input       exp_clear_acc;
        input [2:0] exp_wr_addr;
        input       exp_wr_en_gate;
        begin
            total_tests = total_tests + 1;
            
            if (uut.counter !== exp_counter) begin
                fail_count = fail_count + 1;
                $display("[FAIL: COUNTER] Esperado Cnt = %d | Obtido = %d", exp_counter, uut.counter);
            end else if (
                busy === exp_busy &&
                ready === exp_ready &&
                valid_out === exp_valid_out &&
                load_sample === exp_load_sample &&
                rd_addr === exp_rd_addr &&
                pe_sel === exp_pe_sel &&
                pe_valid === exp_pe_valid &&
                clear_acc === exp_clear_acc &&
                wr_addr === exp_wr_addr &&
                wr_en_gate === exp_wr_en_gate
            ) begin
                success_count = success_count + 1;
                $display("[PASS] Cnt=%2d | busy=%b ready=%b val_out=%b load_s=%b rd_addr=%d pe_sel=%b pe_valid=%b clear=%b wr_addr=%d wr_en=%b",
                         uut.counter, busy, ready, valid_out, load_sample, rd_addr, pe_sel, pe_valid, clear_acc, wr_addr, wr_en_gate);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL: SIGNALS] Divergencia no contador %2d!", uut.counter);
                $display("  Obtido:   busy=%b, ready=%b, val_out=%b, load_s=%b, rd_addr=%d, pe_sel=%b, pe_valid=%b, clear=%b, wr_addr=%d, wr_en=%b",
                         busy, ready, valid_out, load_sample, rd_addr, pe_sel, pe_valid, clear_acc, wr_addr, wr_en_gate);
                $display("  Esperado: busy=%b, ready=%b, val_out=%b, load_s=%b, rd_addr=%d, pe_sel=%b, pe_valid=%b, clear=%b, wr_addr=%d, wr_en=%b",
                         exp_busy, exp_ready, exp_valid_out, exp_load_sample, exp_rd_addr, exp_pe_sel, exp_pe_valid, exp_clear_acc, exp_wr_addr, exp_wr_en_gate);
            end
        end
    endtask

    initial begin
        // Inicialização de Sinais
        clk = 0;
        rst = 1;
        start = 0;
        enable = 1;
        valid_in = 0;

        $display("======================================================================");
        $display("  INICIANDO SIMULACAO CORRIGIDA DA UNIDADE DE CONTROLE (LMS FSM)      ");
        $display("======================================================================");

        #(CLK_PERIOD * 3);
        rst = 0;
        $display("[INFO] Reset desativado. FSM em IDLE.");

        // --------------------------------------------------------------------
        // TESTE 1: Estado de IDLE
        // --------------------------------------------------------------------
        @(negedge clk);
        if (busy !== 1'b0 || ready !== 1'b1 || valid_out !== 1'b0 || uut.counter !== 5'd0) begin
            total_tests = total_tests + 1;
            fail_count = fail_count + 1;
            $display("[FAIL: IDLE] Sinais de handshake incorretos no IDLE!");
        end else begin
            $display("[PASS] Handshake estavel em IDLE.");
        end

        // --------------------------------------------------------------------
        // TESTE 2: Ciclo Completo (Ciclos 0 a 25)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 2: Ciclo de Transicoes Naturais Completo (Ciclos 0 a 25) ---");
        
        @(negedge clk);
        start = 1'b1;
        valid_in = 1'b1;
        
        // Ciclo 0: Carga de Amostra e Reset do Acumulador
        @(posedge clk); #1;
        check_outputs(5'd0, 1'b1, 1'b0, 1'b0, 1'b1, 3'd0, 1'b0, 1'b0, 1'b1, 3'd0, 1'b0);

        @(negedge clk);
        start = 1'b0;
        valid_in = 1'b0;

        // Ciclos 1 a 8: Fase 1 - Filtragem FIR (rd_addr de 0 a 7, pe_sel=0, pe_valid=1)
        @(posedge clk); #1; check_outputs(5'd1, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd2, 1'b1, 1'b0, 1'b0, 1'b0, 3'd1, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd3, 1'b1, 1'b0, 1'b0, 1'b0, 3'd2, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd4, 1'b1, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd5, 1'b1, 1'b0, 1'b0, 1'b0, 3'd4, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd6, 1'b1, 1'b0, 1'b0, 1'b0, 3'd5, 1'b0, 1'b1, 1'b0, 3'd1, 1'b0);
        @(posedge clk); #1; check_outputs(5'd7, 1'b1, 1'b0, 1'b0, 1'b0, 3'd6, 1'b0, 1'b1, 1'b0, 3'd2, 1'b0);
        @(posedge clk); #1; check_outputs(5'd8, 1'b1, 1'b0, 1'b0, 1'b0, 3'd7, 1'b0, 1'b1, 1'b0, 3'd3, 1'b0);

        // Ciclos 9 a 11: Latencia do Acumulador e Calculo de Erro (pe_valid=0)
        @(posedge clk); #1; check_outputs(5'd9,  1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd4, 1'b0);
        @(posedge clk); #1; check_outputs(5'd10, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd5, 1'b0);
        @(posedge clk); #1; check_outputs(5'd11, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd6, 1'b0);

        // Ciclo 12: Dado pronto! Pulsos de valid_out = 1 e ready = 1
        @(posedge clk); #1; check_outputs(5'd12, 1'b1, 1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd7, 1'b0);

        // Ciclos 13 a 20: Fase 2 - Atualizacao de Pesos (rd_addr de 0 a 7, pe_sel=1, pe_valid=1, wr_en_gate=1)
        @(posedge clk); #1; check_outputs(5'd13, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd14, 1'b1, 1'b1, 1'b0, 1'b0, 3'd1, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd15, 1'b1, 1'b1, 1'b0, 1'b0, 3'd2, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd16, 1'b1, 1'b1, 1'b0, 1'b0, 3'd3, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd17, 1'b1, 1'b1, 1'b0, 1'b0, 3'd4, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd18, 1'b1, 1'b1, 1'b0, 1'b0, 3'd5, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd19, 1'b1, 1'b1, 1'b0, 1'b0, 3'd6, 1'b1, 1'b1, 1'b0, 3'd1, 1'b1);
        @(posedge clk); #1; check_outputs(5'd20, 1'b1, 1'b1, 1'b0, 1'b0, 3'd7, 1'b1, 1'b1, 1'b0, 3'd2, 1'b1);

        // Ciclos 21 a 25: Esvaziamento da Pipeline de Escrita (Pipeline Drain)
        @(posedge clk); #1; check_outputs(5'd21, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0);
        @(posedge clk); #1; check_outputs(5'd22, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd4, 1'b0);
        @(posedge clk); #1; check_outputs(5'd23, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd5, 1'b0);
        @(posedge clk); #1; check_outputs(5'd24, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd6, 1'b0);
        @(posedge clk); #1; check_outputs(5'd25, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd7, 1'b0);

        // Retorno ao IDLE após o ciclo 25
        @(posedge clk); #1;
        total_tests = total_tests + 1;
        if (busy !== 1'b0 || ready !== 1'b1 || uut.counter !== 5'd0 || uut.state !== 1'b0) begin
            fail_count = fail_count + 1;
            $display("[FAIL: RETURN] FSM falhou ao retornar ao IDLE no ciclo 25.");
        end else begin
            success_count = success_count + 1;
            $display("[PASS] FSM retornou perfeitamente ao IDLE!");
        end

        #(CLK_PERIOD * 4);

        // --------------------------------------------------------------------
        // TESTE 3: Congelamento por Enable (enable = 0)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 3: Congelamento Sincrono (Enable = 0) ---");
        
        @(negedge clk);
        start = 1'b1;
        valid_in = 1'b1;
        
        @(posedge clk); #1;
        @(negedge clk);
        start = 1'b0;
        valid_in = 1'b0;

        repeat (4) @(posedge clk); #1;

        $display("[INFO] Desabilitando ENABLE no ciclo 4...");
        @(negedge clk);
        enable = 1'b0;

        repeat (3) begin
            @(posedge clk); #1;
            total_tests = total_tests + 1;
            if (uut.counter !== 5'd4 || busy !== 1'b1 || rd_addr !== 3'd3) begin
                fail_count = fail_count + 1;
                $display("[FAIL: FREEZE] Registradores alteraram com enable=0!");
            end else begin
                success_count = success_count + 1;
                $display("[PASS] FSM congelada no contador %2d.", uut.counter);
            end
        end

        $display("[INFO] Reabilitando ENABLE...");
        @(negedge clk);
        enable = 1'b1;

        while (busy === 1'b1) begin
            @(posedge clk);
        end
        #1;
        $display("[PASS] FSM retomou e concluiu com sucesso.");

        // --------------------------------------------------------------------
        // CONSOLIDAÇÃO DOS RESULTADOS
        // --------------------------------------------------------------------
        $display("\n======================================================================");
        $display("                      RELATORIO FINAL DE SIMULACAO                    ");
        $display("======================================================================");
        $display("  Total de Operacoes Verificadas: %d", total_tests);
        $display("  Sucessos Confirmados:           %d", success_count);
        $display("  Falhas Detectadas:              %d", fail_count);
        $display("======================================================================");

        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> [CONGRATS] A TESTBENCH CORRIGIDA PASSOU 100%%! <<<");
        end else begin
            $display("  >>> [ERROR] Ainda existem falhas na simulacao. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule