// ============================================================================
// Module: tb_LMS_Residual_Feature
// Description: Testbench do MODULO LMS como ele roda no SMMA_Top:
//              LMS_Residual_Feature conduzindo o LMS_Filter_Top (8 taps,
//              mu = 2^-3) amostra a amostra, como preditor linear.
//
// Vetores: 6 janelas REAIS da particao de teste (vetores/temp_teste.hex),
// 1056 amostras decimadas cada, com o r_lms que o modelo Python produz.
// Comparacao BIT A BIT: o LMS e recursivo, e um LSB de diferenca no erro
// contamina os pesos pelo resto da janela.
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Residual_Feature;

    parameter WIDTH      = 16;
    parameter L          = 1056;
    parameter N_FEAT_ARQ = 4;        // r_lms, rho1, rho2, rho3 no arquivo
    parameter MAX_CASOS  = 6;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                      start;
    reg                      in_valid;
    reg  signed [WIDTH-1:0]  in_sample;
    wire                     in_ready, ready, busy, done, out_valid;
    wire signed [WIDTH-1:0]  out_feature;

    reg       bp_enable;
    reg [1:0] bp_cnt;
    wire      out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    // ---- LMS_Filter_Top + controlador de janela, ligados como no top ----
    wire                     lms_clear, lms_start, lms_busy, lms_valid_out;
    wire signed [WIDTH-1:0]  lms_x, lms_d, lms_error;

    LMS_Filter_Top #(.WIDTH(WIDTH), .FRAC(15), .MU_SHIFT(3)) u_lms (
        .clk(clk), .rst(rst || lms_clear),
        .start(lms_start), .enable(1'b1), .valid_in(lms_start),
        .ready(), .busy(lms_busy), .valid_out(lms_valid_out),
        .in_x(lms_x), .in_d(lms_d), .out_y(), .out_error(lms_error),
        .w0(), .w1(), .w2(), .w3(), .w4(), .w5(), .w6(), .w7()
    );

    LMS_Residual_Feature #(.WIDTH(WIDTH), .FRAC(15), .N_AMOSTRAS(L)) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(ready), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_sample(in_sample),
        .lms_clear(lms_clear), .lms_start(lms_start),
        .lms_x(lms_x), .lms_d(lms_d),
        .lms_busy(lms_busy), .lms_valid_out(lms_valid_out), .lms_error(lms_error),
        .out_ready(out_ready), .out_valid(out_valid), .out_feature(out_feature)
    );

    reg [15:0] arq [0:2 + MAX_CASOS*(L + N_FEAT_ARQ) - 1];
    integer n_casos;
    integer success_count = 0, fail_count = 0;

    // ---- produtor sincrono das amostras ----
    integer base_in, idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid <= 1'b0; in_sample <= {WIDTH{1'b0}}; idx_in <= 0;
        end else begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < L) begin
                    in_valid  <= 1'b1;
                    in_sample <= arq[base_in + idx_in + 1];
                end else
                    in_valid <= 1'b0;
            end else if (!in_valid && idx_in < L) begin
                in_valid  <= 1'b1;
                in_sample <= arq[base_in + idx_in];
            end
        end
    end

    reg signed [WIDTH-1:0] obtido;
    integer n_out;
    always @(posedge clk)
        if (!rst && out_valid && out_ready) begin obtido = out_feature; n_out = n_out + 1; end

    integer c, base, ciclos, ciclos_max;
    reg signed [WIDTH-1:0] esperado;

    initial begin
        $display("======================================================================");
        $display("  MODULO LMS: LMS_Filter_Top + LMS_Residual_Feature (r_lms)          ");
        $display("======================================================================");
        $readmemh("vetores/temp_teste.hex", arq);
        n_casos = arq[0];

        rst = 1; start = 0; enviando = 0; n_out = 0; bp_enable = 0; bp_cnt = 0; ciclos_max = 0;
        repeat (3) @(negedge clk); rst = 0; @(negedge clk);

        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1; $display("[PASS] Reset: ready=1, busy=0");
        end else begin
            fail_count = fail_count + 1; $display("[FAIL] Reset: ready=%b busy=%b", ready, busy);
        end

        for (c = 0; c < n_casos; c = c + 1) begin
            base = 2 + c*(L + N_FEAT_ARQ); base_in = base;
            n_out = 0; enviando = 0; bp_enable = (c % 2);
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            enviando = 1;
            ciclos = 0;
            while (n_out < 1 && ciclos < 500000) begin @(posedge clk); ciclos = ciclos + 1; end
            if (ciclos > ciclos_max) ciclos_max = ciclos;
            enviando = 0;
            repeat (5) @(negedge clk);
            esperado = arq[base + L];
            if (obtido === esperado) begin
                success_count = success_count + 1;
                $display("[PASS] caso %0d: r_lms = %0d  (bit a bit com o modelo)  [%0d ciclos]",
                         c, obtido, ciclos);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] caso %0d: r_lms obtido %0d, esperado %0d", c, obtido, esperado);
            end
        end

        // 1056 amostras x ~32 ciclos; orcamento de uma janela: 16,5 M ciclos
        if (ciclos_max < 60000) begin
            success_count = success_count + 1;
            $display("[PASS] Latencia maxima: %0d ciclos (%0d us @ 50 MHz)",
                     ciclos_max, ciclos_max*CLK_PERIOD/1000);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Latencia de %0d ciclos", ciclos_max);
        end

        if (ready === 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova janela sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO MODULO LMS PASSARAM COM SUCESSO!");
        $finish;
    end

    initial begin #500_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
