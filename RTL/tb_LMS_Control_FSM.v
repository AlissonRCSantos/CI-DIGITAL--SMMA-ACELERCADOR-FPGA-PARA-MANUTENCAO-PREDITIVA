// ============================================================================
// Module: tb_LMS_Control_FSM_v3
// Description: Self-checking testbench to validate the LMS_Control_FSM_v2 module
//              in Verilog. Tests natural transitions, reset, and error cases.
//              Version 3 - Corrected Test 3 timing (repeat 11 instead of 12)
//              and updated to test LMS_Control_FSM_v2.
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Control_FSM;

    // Signals
    reg         clk;
    reg         rst;
    reg         sample_valid;

    wire [2:0]  rd_addr;
    wire        pe_sel;
    wire        pe_valid;
    wire        clear_acc;
    wire [2:0]  wr_addr;
    wire        wr_en_gate;
    wire        filter_busy;

    // Testbench stats
    integer success_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    // Instantiate Unit Under Test (UUT)
    LMS_Control_FSM uut (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .rd_addr(rd_addr),
        .pe_sel(pe_sel),
        .pe_valid(pe_valid),
        .clear_acc(clear_acc),
        .wr_addr(wr_addr),
        .wr_en_gate(wr_en_gate),
        .filter_busy(filter_busy)
    );

    // Clock Generator (50 MHz, 20 ns period)
    parameter CLK_PERIOD = 20;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Expected values validation task
    task check_outputs;
        input [4:0] exp_counter;
        input [2:0] exp_rd_addr;
        input       exp_pe_sel;
        input       exp_pe_valid;
        input       exp_clear_acc;
        input [2:0] exp_wr_addr;
        input       exp_wr_en_gate;
        input       exp_filter_busy;
        begin
            total_tests = total_tests + 1;
            
            // Compare counter value directly from internal UUT variable for debugging
            if (uut.counter !== exp_counter) begin
                fail_count = fail_count + 1;
                $display("[FAIL: COUNTER] Expected Counter = %d | Got = %d", exp_counter, uut.counter);
            end else if (
                rd_addr === exp_rd_addr &&
                pe_sel === exp_pe_sel &&
                pe_valid === exp_pe_valid &&
                clear_acc === exp_clear_acc &&
                wr_addr === exp_wr_addr &&
                wr_en_gate === exp_wr_en_gate &&
                filter_busy === exp_filter_busy
            ) begin
                success_count = success_count + 1;
                $display("[PASS] Counter %2d | RD_Addr=%d | PE_Sel=%b | PE_Valid=%b | Clear=%b | WR_Addr=%d | WR_En=%b | Busy=%b",
                         uut.counter, rd_addr, pe_sel, pe_valid, clear_acc, wr_addr, wr_en_gate, filter_busy);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL: SIGNALS] State mismatch on counter %2d!", uut.counter);
                $display("  Got:      RD_Addr=%d, PE_Sel=%b, PE_Valid=%b, Clear=%b, WR_Addr=%d, WR_En=%b, Busy=%b",
                         rd_addr, pe_sel, pe_valid, clear_acc, wr_addr, wr_en_gate, filter_busy);
                $display("  Expected: RD_Addr=%d, PE_Sel=%b, PE_Valid=%b, Clear=%b, WR_Addr=%d, WR_En=%b, Busy=%b",
                         exp_rd_addr, exp_pe_sel, exp_pe_valid, exp_clear_acc, exp_wr_addr, exp_wr_en_gate, exp_filter_busy);
            end
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        sample_valid = 0;

        $display("======================================================================");
        $display("    INICIANDO SIMULACAO DA UNIDADE DE CONTROLE (LMS FSM) - 50 MHz     ");
        $display("======================================================================");

        #(CLK_PERIOD * 3);
        rst = 0;
        $display("[INFO] Reset desativado. FSM em IDLE.");

        // --------------------------------------------------------------------
        // TESTE 1: Estado de IDLE e Estabilidade
        // --------------------------------------------------------------------
        @(negedge clk);
        if (filter_busy !== 1'b0 || uut.counter !== 5'd0) begin
            total_tests = total_tests + 1;
            fail_count = fail_count + 1;
            $display("[FAIL: IDLE] FSM should be completely idle and quiet before sample_valid.");
        end else begin
            $display("[PASS] FSM is successfully waiting in IDLE.");
        end

        // --------------------------------------------------------------------
        // TESTE 2: Ciclo de Transições Naturais (Ciclos 0 a 17)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 2: Ciclo de Transições Naturais (Ciclos 0 a 17) ---");
        
        // Dispara o ciclo
        @(negedge clk);
        sample_valid = 1'b1;
        
        @(negedge clk);
        sample_valid = 1'b0; // Garante que sample_valid dura apenas 1 clock

        // Agora verificamos cada um dos 18 ciclos ativos da iteração LMS
        // Espera de propagação combinatória e verifica
        
        // Ciclo 0 (counter = 0): Filtragem, clear_acc deve estar ativo
        check_outputs(5'd0, 3'd0, 1'b0, 1'b1, 1'b1, 3'd0, 1'b0, 1'b1);
        
        // Ciclo 1 (counter = 1)
        @(posedge clk); #1;
        check_outputs(5'd1, 3'd1, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0, 1'b1);

        // Ciclo 2 (counter = 2)
        @(posedge clk); #1;
        check_outputs(5'd2, 3'd2, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0, 1'b1);

        // Ciclo 3 (counter = 3)
        @(posedge clk); #1;
        check_outputs(5'd3, 3'd3, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0, 1'b1);

        // Ciclo 4 (counter = 4)
        @(posedge clk); #1;
        check_outputs(5'd4, 3'd4, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0, 1'b1);

        // Ciclo 5 (counter = 5)
        @(posedge clk); #1;
        check_outputs(5'd5, 3'd5, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0, 1'b1);

        // Ciclo 6 (counter = 6)
        @(posedge clk); #1;
        check_outputs(5'd6, 3'd6, 1'b0, 1'b1, 1'b0, 3'd1, 1'b0, 1'b1); 

        // Ciclo 7 (counter = 7)
        @(posedge clk); #1;
        check_outputs(5'd7, 3'd7, 1'b0, 1'b1, 1'b0, 3'd2, 1'b0, 1'b1);

        // Ciclo 8 (counter = 8): Intermediário, cálculo de erro, pe_valid desativa
        @(posedge clk); #1;
        check_outputs(5'd8, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0, 1'b1);

        // Ciclo 9 (counter = 9): Fase 2 de Atualização de Pesos
        @(posedge clk); #1;
        check_outputs(5'd9, 3'd0, 1'b1, 1'b1, 1'b0, 3'd4, 1'b1, 1'b1);

        // Ciclo 10 (counter = 10)
        @(posedge clk); #1;
        check_outputs(5'd10, 3'd1, 1'b1, 1'b1, 1'b0, 3'd5, 1'b1, 1'b1);

        // Ciclo 11 (counter = 11)
        @(posedge clk); #1;
        check_outputs(5'd11, 3'd2, 1'b1, 1'b1, 1'b0, 3'd6, 1'b1, 1'b1);

        // Ciclo 12 (counter = 12)
        @(posedge clk); #1;
        check_outputs(5'd12, 3'd3, 1'b1, 1'b1, 1'b0, 3'd7, 1'b1, 1'b1);

        // Ciclo 13 (counter = 13)
        @(posedge clk); #1;
        check_outputs(5'd13, 3'd4, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1, 1'b1);

        // Ciclo 14 (counter = 14)
        @(posedge clk); #1;
        check_outputs(5'd14, 3'd5, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1, 1'b1);

        // Ciclo 15 (counter = 15)
        @(posedge clk); #1;
        check_outputs(5'd15, 3'd6, 1'b1, 1'b1, 1'b0, 3'd1, 1'b1, 1'b1);

        // Ciclo 16 (counter = 16)
        @(posedge clk); #1;
        check_outputs(5'd16, 3'd7, 1'b1, 1'b1, 1'b0, 3'd2, 1'b1, 1'b1);

        // Ciclo 17 (counter = 17): Fim da iteração, último ciclo ativo
        @(posedge clk); #1;
        check_outputs(5'd17, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0, 1'b1);

        // Retorno ao IDLE (counter = 0, filter_busy = 0)
        @(posedge clk); #1;
        if (filter_busy !== 1'b0 || uut.counter !== 5'd0) begin
            total_tests = total_tests + 1;
            fail_count = fail_count + 1;
            $display("[FAIL: RETURN] FSM failed to return to IDLE after count 17.");
        end else begin
            $display("[PASS] FSM successfully returned to IDLE and lowered Busy flag.");
        end

        #(CLK_PERIOD * 2);

        // --------------------------------------------------------------------
        // TESTE 3: Caso de Erro - Ignorar sample_valid enquanto estiver ocupado
        // --------------------------------------------------------------------
        $display("\n--- TESTE 3: Caso de Erro (Ignorar sample_valid durante execução) ---");
        
        @(negedge clk);
        sample_valid = 1'b1;
        
        @(negedge clk);
        sample_valid = 1'b0;
        
        // Deixa rodar até o ciclo 5
        repeat (5) @(posedge clk);
        #1;
        
        // Tenta pulsar sample_valid novamente para ver se causa perturbação no ciclo
        @(negedge clk);
        sample_valid = 1'b1;
        
        @(negedge clk);
        sample_valid = 1'b0;
        
        // Espera o restante do ciclo terminar naturalmente (11 ciclos para de 6 chegar a 17)
        repeat (11) @(posedge clk);
        #1;
        
        total_tests = total_tests + 1;
        if (uut.counter == 5'd17 && filter_busy == 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] FSM ignored mid-cycle sample_valid pulses and remained stable.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL: IGNORE] FSM counter got corrupted or reset on mid-cycle pulse! Got counter = %d", uut.counter);
        end

        // Aguarda voltar para IDLE
        @(posedge clk); #1;
        
        // --------------------------------------------------------------------
        // TESTE 4: Reset Síncrono no Meio da Execução
        // --------------------------------------------------------------------
        $display("\n--- TESTE 4: Reset Síncrono no Meio da Execução ---");
        
        @(negedge clk);
        sample_valid = 1'b1;
        
        @(negedge clk);
        sample_valid = 1'b0;
        
        // Deixa rodar até o ciclo 10
        repeat (10) @(posedge clk);
        #1;
        
        $display("[INFO] Disparando reset síncrono...");
        @(negedge clk);
        rst = 1'b1;
        
        @(posedge clk); #1;
        total_tests = total_tests + 1;
        // Compare internal state for test verification (0 is idle)
        if (uut.counter == 5'd0 && uut.state == 1'b0 && filter_busy == 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] FSM successfully returned to IDLE instantly upon synchronous reset.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL: RESET] FSM failed to abort mid-run! Counter = %d, state = %b, busy = %b", 
                     uut.counter, uut.state, filter_busy);
        end
        
        @(negedge clk);
        rst = 1'b0;
        #(CLK_PERIOD * 3);

        // --------------------------------------------------------------------
        // CONSOLIDAÇÃO DOS RESULTADOS
        // --------------------------------------------------------------------
        $display("\n======================================================================");
        $display("                      RELATORIO FINAL DE SIMULACAO                    ");
        $display("======================================================================");
        $display("  Total de Operacoes Verificadas: %d", total_tests);
        $display("  Sucessos Confirmados:           %d", success_count);
        $display("  Failures Detectadas:            %d", fail_count);
        $display("======================================================================");

        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> [CONGRATS] A UNIDADE DE CONTROLE (FSM) PASSOU EM TODOS OS TESTES! <<<");
            $display("  >>> Ciclo de 18 estados, imunidade de re-trigger e reset síncrono validados. <<<");
        end else begin
            $display("  >>> [ERROR] Falhas identificadas no comportamento do Controlador. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule