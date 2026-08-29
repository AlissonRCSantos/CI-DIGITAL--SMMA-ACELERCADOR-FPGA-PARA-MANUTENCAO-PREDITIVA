// ============================================================================
// Module: tb_LMS_Control_FSM_v4
// Description: Self-checking testbench to validate the LMS_Control_FSM_v3 module
//              in Verilog. Tests handshake protocol (start, ready, busy, valid_out),
//              natural transitions, reset, and the clock-enable freezing mechanism.
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

    // Expected values validation task
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
            
            // Compare counter value directly from internal UUT variable for debugging
            if (uut.counter !== exp_counter) begin
                fail_count = fail_count + 1;
                $display("[FAIL: COUNTER] Expected Counter = %d | Got = %d", exp_counter, uut.counter);
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
                $display("[FAIL: SIGNALS] State mismatch on counter %2d!", uut.counter);
                $display("  Got:      busy=%b, ready=%b, val_out=%b, load_s=%b, rd_addr=%d, pe_sel=%b, pe_valid=%b, clear=%b, wr_addr=%d, wr_en=%b",
                         busy, ready, valid_out, load_sample, rd_addr, pe_sel, pe_valid, clear_acc, wr_addr, wr_en_gate);
                $display("  Expected: busy=%b, ready=%b, val_out=%b, load_s=%b, rd_addr=%d, pe_sel=%b, pe_valid=%b, clear=%b, wr_addr=%d, wr_en=%b",
                         exp_busy, exp_ready, exp_valid_out, exp_load_sample, exp_rd_addr, exp_pe_sel, exp_pe_valid, exp_clear_acc, exp_wr_addr, exp_wr_en_gate);
            end
        end
    endtask

    initial begin
        // Initialize signals
        clk = 0;
        rst = 1;
        start = 0;
        enable = 1;
        valid_in = 0;

        $display("======================================================================");
        $display("  INICIANDO SIMULACAO DA UNIDADE DE CONTROLE (LMS FSM V3) - 50 MHz    ");
        $display("======================================================================");

        #(CLK_PERIOD * 3);
        rst = 0;
        $display("[INFO] Reset desativado. FSM em IDLE.");

        // --------------------------------------------------------------------
        // TESTE 1: Estado de IDLE e Estabilidade de Handshake
        // --------------------------------------------------------------------
        @(negedge clk);
        if (busy !== 1'b0 || ready !== 1'b1 || valid_out !== 1'b0 || uut.counter !== 5'd0) begin
            total_tests = total_tests + 1;
            fail_count = fail_count + 1;
            $display("[FAIL: IDLE] FSM handshake ports are incorrect in IDLE! busy=%b, ready=%b, val_out=%b", busy, ready, valid_out);
        end else begin
            $display("[PASS] FSM handshake interface is perfectly stable in IDLE.");
        end

        // --------------------------------------------------------------------
        // TESTE 2: Ciclo de Transições Naturais Completo (Ciclos 0 a 17)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 2: Ciclo de Transições Naturais (Ciclos 0 a 17) ---");
        
        // Dispara o ciclo
        @(negedge clk);
        start = 1'b1;
        valid_in = 1'b1;
        
        // No ciclo seguinte à detecção na borda de descida do testbench (borda de subida do hardware)
        @(posedge clk); #1;
        // uut.counter = 0 (primeiro ciclo de corrida)
        // O load_sample deve estar ativo para deslocar na delay line
        // rd_addr = 0, pe_sel = 0 (filtragem), pe_valid = 1, clear_acc = 1, wr_addr = 0, wr_en_gate = 0
        // busy = 1, ready = 0, valid_out = 0
        check_outputs(5'd0, 1'b1, 1'b0, 1'b0, 1'b1, 3'd0, 1'b0, 1'b1, 1'b1, 3'd0, 1'b0);

        @(negedge clk);
        start = 1'b0;
        valid_in = 1'b0; // Limpa os pulsos para garantir que duraram 1 ciclo

        // Ciclo 1 (counter = 1)
        @(posedge clk); #1;
        check_outputs(5'd1, 1'b1, 1'b0, 1'b0, 1'b0, 3'd1, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);

        // Ciclos 2 a 5
        @(posedge clk); #1; check_outputs(5'd2, 1'b1, 1'b0, 1'b0, 1'b0, 3'd2, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd3, 1'b1, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd4, 1'b1, 1'b0, 1'b0, 1'b0, 3'd4, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);
        @(posedge clk); #1; check_outputs(5'd5, 1'b1, 1'b0, 1'b0, 1'b0, 3'd5, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);

        // Ciclo 6: rd_addr=6, wr_addr=1 (devido a wr_addr_pipe4)
        @(posedge clk); #1; check_outputs(5'd6, 1'b1, 1'b0, 1'b0, 1'b0, 3'd6, 1'b0, 1'b1, 1'b0, 3'd1, 1'b0);

        // Ciclo 7: rd_addr=7, wr_addr=2
        @(posedge clk); #1; check_outputs(5'd7, 1'b1, 1'b0, 1'b0, 1'b0, 3'd7, 1'b0, 1'b1, 1'b0, 3'd2, 1'b0);

        // Ciclo 8: Cálculo de erro, pe_valid = 0, rd_addr = 0, wr_addr = 3
        @(posedge clk); #1; check_outputs(5'd8, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0);

        // Ciclo 9: Atualização de pesos, pe_sel = 1, pe_valid = 1, wr_en_gate = 1, wr_addr = 4
        @(posedge clk); #1; check_outputs(5'd9, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b1, 1'b1, 1'b0, 3'd4, 1'b1);

        // Ciclo 10: O valid_out deve subir agora! E o ready deve ir para 1!
        // counter = 10, pe_sel = 1, pe_valid = 1, wr_en_gate = 1, wr_addr = 5, rd_addr = 1
        @(posedge clk); #1; check_outputs(5'd10, 1'b1, 1'b1, 1'b1, 1'b0, 3'd1, 1'b1, 1'b1, 1'b0, 3'd5, 1'b1);

        // Ciclo 11: valid_out desce de volta a 0. ready continua em 1.
        // counter = 11, rd_addr = 2, wr_addr = 6
        @(posedge clk); #1; check_outputs(5'd11, 1'b1, 1'b1, 1'b0, 1'b0, 3'd2, 1'b1, 1'b1, 1'b0, 3'd6, 1'b1);

        // Ciclos 12 a 16
        @(posedge clk); #1; check_outputs(5'd12, 1'b1, 1'b1, 1'b0, 1'b0, 3'd3, 1'b1, 1'b1, 1'b0, 3'd7, 1'b1);
        @(posedge clk); #1; check_outputs(5'd13, 1'b1, 1'b1, 1'b0, 1'b0, 3'd4, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd14, 1'b1, 1'b1, 1'b0, 1'b0, 3'd5, 1'b1, 1'b1, 1'b0, 3'd0, 1'b1);
        @(posedge clk); #1; check_outputs(5'd15, 1'b1, 1'b1, 1'b0, 1'b0, 3'd6, 1'b1, 1'b1, 1'b0, 3'd1, 1'b1);
        @(posedge clk); #1; check_outputs(5'd16, 1'b1, 1'b1, 1'b0, 1'b0, 3'd7, 1'b1, 1'b1, 1'b0, 3'd2, 1'b1);

        // Ciclo 17: Fim do cálculo, último ciclo ativo, pe_valid = 0, wr_en_gate = 0, wr_addr = 3
        @(posedge clk); #1; check_outputs(5'd17, 1'b1, 1'b1, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0);

        // Retorno ao IDLE (counter = 0, busy = 0, ready = 1)
        @(posedge clk); #1;
        total_tests = total_tests + 1;
        if (busy !== 1'b0 || ready !== 1'b1 || uut.counter !== 5'd0 || uut.state !== 1'b0) begin
            fail_count = fail_count + 1;
            $display("[FAIL: RETURN] FSM failed to return to IDLE after count 17. busy=%b ready=%b", busy, ready);
        end else begin
            success_count = success_count + 1;
            $display("[PASS] FSM successfully returned to IDLE, set ready=1, and lowered busy.");
        end

        #(CLK_PERIOD * 2);

        // --------------------------------------------------------------------
        // TESTE 3: Congelamento Síncrono de Operação (Pino Enable)
        // --------------------------------------------------------------------
        $display("\n--- TESTE 3: Congelamento Síncrono de Operação (Enable = 0) ---");
        
        @(negedge clk);
        start = 1'b1;
        valid_in = 1'b1;
        
        @(posedge clk); #1;
        // Entrou em RUN, counter = 0
        check_outputs(5'd0, 1'b1, 1'b0, 1'b0, 1'b1, 3'd0, 1'b0, 1'b1, 1'b1, 3'd0, 1'b0);

        @(negedge clk);
        start = 1'b0;
        valid_in = 1'b0;

        // Avança até o ciclo 4
        repeat (4) @(posedge clk); #1;
        // Agora estamos no ciclo 4
        check_outputs(5'd4, 1'b1, 1'b0, 1'b0, 1'b0, 3'd4, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);

        $display("[INFO] Desabilitando pino ENABLE (enable = 0) no ciclo 4...");
        @(negedge clk);
        enable = 1'b0;

        // Bate 3 ciclos de clock com o circuito desabilitado
        repeat (3) begin
            @(posedge clk); #1;
            total_tests = total_tests + 1;
            if (uut.counter !== 5'd4 || busy !== 1'b1 || ready !== 1'b0 || rd_addr !== 3'd4) begin
                fail_count = fail_count + 1;
                $display("[FAIL: FREEZE] FSM registers changed while enable is low! counter=%d, busy=%b, rd_addr=%d", uut.counter, busy, rd_addr);
            end else begin
                success_count = success_count + 1;
                $display("[PASS] FSM is frozen at counter %2d. busy=%b, ready=%b, rd_addr=%d", uut.counter, busy, ready, rd_addr);
            end
        end

        $display("[INFO] Reabilitando pino ENABLE (enable = 1)...");
        @(negedge clk);
        enable = 1'b1;

        // No ciclo seguinte, deve avançar para o ciclo 5
        @(posedge clk); #1;
        check_outputs(5'd5, 1'b1, 1'b0, 1'b0, 1'b0, 3'd5, 1'b0, 1'b1, 1'b0, 3'd0, 1'b0);

        // Deixa rodar até o final
        while (busy === 1'b1) begin
            @(posedge clk);
        end
        #1;
        $display("[PASS] FSM successfully resumed and finished computation.");

        #(CLK_PERIOD * 2);

        // --------------------------------------------------------------------
        // TESTE 4: Reset Síncrono no Meio da Execução
        // --------------------------------------------------------------------
        $display("\n--- TESTE 4: Reset Síncrono no Meio da Execução ---");
        
        @(negedge clk);
        start = 1'b1;
        valid_in = 1'b1;
        
        @(posedge clk); #1;
        @(negedge clk);
        start = 1'b0;
        valid_in = 1'b0;

        // Deixa rodar até o ciclo 8
        repeat (8) @(posedge clk); #1;
        check_outputs(5'd8, 1'b1, 1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0, 1'b0, 3'd3, 1'b0);

        $display("[INFO] Disparando reset síncrono...");
        @(negedge clk);
        rst = 1'b1;
        
        @(posedge clk); #1;
        total_tests = total_tests + 1;
        if (uut.counter == 5'd0 && uut.state == 1'b0 && busy == 1'b0 && ready == 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] FSM successfully returned to IDLE instantly upon synchronous reset.");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL: RESET] FSM failed to abort mid-run! Counter=%d, state=%b, busy=%b, ready=%b", 
                     uut.counter, uut.state, busy, ready);
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
        $display("  Falhas Detectadas:              %d", fail_count);
        $display("======================================================================");

        if (fail_count == 0 && total_tests > 0) begin
            $display("  >>> [CONGRATS] A UNIDADE DE CONTROLE (FSM V3) PASSOU EM TODOS OS TESTES! <<<");
            $display("  >>> Interface de Handshake, Sinais de Status e Congelamento por Enable OK! <<<");
        end else begin
            $display("  >>> [ERROR] Falhas identificadas no comportamento do Controlador. <<<");
        end
        $display("======================================================================\n");

        $finish;
    end

endmodule
