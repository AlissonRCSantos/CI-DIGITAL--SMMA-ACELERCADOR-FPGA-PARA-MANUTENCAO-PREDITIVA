// ============================================================================
// tb_LMS_Stage -- testbench: LMS em serie, repasse intacto e r_lms bit a bit
// ============================================================================

`timescale 1ns / 1ps

module tb_LMS_Stage;

    parameter WIDTH      = 16;
    parameter L          = 1056;
    parameter N_FEAT_ARQ = 4;
    parameter MAX_CASOS  = 6;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    // assinaturas de y(n) calculadas com o modelo Python
    integer sig_soma [0:MAX_CASOS-1];
    reg [31:0] sig_pond [0:MAX_CASOS-1];
    initial begin
        sig_soma[0] =    64; sig_pond[0] = 32'd39734;
        sig_soma[1] =   -38; sig_pond[1] = 32'd4294931443;
        sig_soma[2] =  -101; sig_pond[2] = 32'd4294899816;
        sig_soma[3] = 68881; sig_pond[3] = 32'd48379706;
        sig_soma[4] =   245; sig_pond[4] = 32'd178144;
        sig_soma[5] =   775; sig_pond[5] = 32'd549630;
    end

    reg                      start;
    reg                      in_valid;
    reg  signed [WIDTH-1:0]  in_sample;
    wire                     in_ready = rdy0 && rdy1;   // as duas recebem juntas

    // contrapressao aleatoria nas saidas
    reg [15:0] lfsr = 16'hBEEF;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire o_rdy0 = lfsr[0] | lfsr[3];
    wire o_rdy1 = lfsr[1] | lfsr[4];

    // ---------------- DUT0: SAIDA_LMS = 0 ----------------
    wire rdy0, ready0, busy0, done0, ov0, fv0;
    wire signed [WIDTH-1:0] os0, feat0;
    wire c0, st0, lb0, lv0;
    wire signed [WIDTH-1:0] x0, d0, y0, e0;

    LMS_Filter_Top #(.WIDTH(WIDTH), .FRAC(15), .MU_SHIFT(3)) u_lms0 (
        .clk(clk), .rst(rst || c0), .start(st0), .enable(1'b1), .valid_in(st0),
        .ready(), .busy(lb0), .valid_out(lv0), .in_x(x0), .in_d(d0),
        .out_y(y0), .out_error(e0),
        .w0(), .w1(), .w2(), .w3(), .w4(), .w5(), .w6(), .w7());

    LMS_Stage #(.WIDTH(WIDTH), .FRAC(15), .N_AMOSTRAS(L), .SAIDA_LMS(0)) dut0 (
        .clk(clk), .rst(rst), .start(start), .ready(ready0), .busy(busy0), .done(done0),
        .in_valid(in_valid && rdy1), .in_ready(rdy0), .in_sample(in_sample),
        .out_ready(o_rdy0), .out_valid(ov0), .out_sample(os0),
        .lms_clear(c0), .lms_start(st0), .lms_x(x0), .lms_d(d0),
        .lms_busy(lb0), .lms_valid_out(lv0), .lms_y(y0), .lms_error(e0),
        .feat_ready(1'b1), .feat_valid(fv0), .feat_lms(feat0));

    // ---------------- DUT1: SAIDA_LMS = 1 ----------------
    wire rdy1, ready1, busy1, done1, ov1, fv1;
    wire signed [WIDTH-1:0] os1, feat1;
    wire c1, st1, lb1, lv1;
    wire signed [WIDTH-1:0] x1, d1, y1, e1;

    LMS_Filter_Top #(.WIDTH(WIDTH), .FRAC(15), .MU_SHIFT(3)) u_lms1 (
        .clk(clk), .rst(rst || c1), .start(st1), .enable(1'b1), .valid_in(st1),
        .ready(), .busy(lb1), .valid_out(lv1), .in_x(x1), .in_d(d1),
        .out_y(y1), .out_error(e1),
        .w0(), .w1(), .w2(), .w3(), .w4(), .w5(), .w6(), .w7());

    LMS_Stage #(.WIDTH(WIDTH), .FRAC(15), .N_AMOSTRAS(L), .SAIDA_LMS(1)) dut1 (
        .clk(clk), .rst(rst), .start(start), .ready(ready1), .busy(busy1), .done(done1),
        .in_valid(in_valid && rdy0), .in_ready(rdy1), .in_sample(in_sample),
        .out_ready(o_rdy1), .out_valid(ov1), .out_sample(os1),
        .lms_clear(c1), .lms_start(st1), .lms_x(x1), .lms_d(d1),
        .lms_busy(lb1), .lms_valid_out(lv1), .lms_y(y1), .lms_error(e1),
        .feat_ready(1'b1), .feat_valid(fv1), .feat_lms(feat1));

    reg [15:0] arq [0:2 + MAX_CASOS*(L + N_FEAT_ARQ) - 1];
    integer n_casos;
    integer success_count = 0, fail_count = 0;

    // ---- produtor ----
    integer base_in, idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid <= 1'b0; in_sample <= {WIDTH{1'b0}}; idx_in <= 0;
        end else begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < L) begin in_valid <= 1'b1; in_sample <= arq[base_in + idx_in + 1]; end
                else in_valid <= 1'b0;
            end else if (!in_valid && idx_in < L) begin
                in_valid <= 1'b1; in_sample <= arq[base_in + idx_in];
            end
        end
    end

    // ---- consumidores ----
    integer n0, erros0, n1, soma1, termo;
    reg [31:0] pond1;
    reg signed [WIDTH-1:0] r_lms0;
    reg feat_ok0;
    always @(posedge clk) begin
        if (!rst && ov0 && o_rdy0) begin
            if (os0 !== $signed(arq[base_in + n0])) erros0 = erros0 + 1;
            n0 = n0 + 1;
        end
        if (!rst && ov1 && o_rdy1) begin
            soma1 = soma1 + os1;
            termo = (n1 + 1) * os1;          // inteiro com sinal
            pond1 = pond1 + termo;
            n1 = n1 + 1;
        end
        if (!rst && fv0) begin r_lms0 = feat0; feat_ok0 = 1; end
    end

    integer c, base, ciclos, e_caso;

    initial begin
        $display("======================================================================");
        $display("  ESTAGIO LMS EM SERIE: LMS_Stage + LMS_Filter_Top                    ");
        $display("======================================================================");
        $readmemh("vetores/temp_teste.hex", arq);
        n_casos = arq[0];
        rst = 1; start = 0; enviando = 0;
        repeat (3) @(negedge clk); rst = 0; @(negedge clk);

        for (c = 0; c < n_casos; c = c + 1) begin
            base = 2 + c*(L + N_FEAT_ARQ); base_in = base;
            n0 = 0; erros0 = 0; n1 = 0; soma1 = 0; pond1 = 0; feat_ok0 = 0; enviando = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            enviando = 1;
            ciclos = 0;
            while (!(ready0 && ready1 && feat_ok0) && ciclos < 500000) begin
                @(posedge clk); ciclos = ciclos + 1;
            end
            enviando = 0;
            repeat (3) @(negedge clk);

            e_caso = 0;
            if (n0 != L || erros0 != 0) begin
                e_caso = e_caso + 1;
                $display("[FAIL] caso %0d: repasse SAIDA_LMS=0 -- %0d amostras, %0d diferentes", c, n0, erros0);
            end
            if (r_lms0 !== $signed(arq[base + L])) begin
                e_caso = e_caso + 1;
                $display("[FAIL] caso %0d: r_lms %0d, esperado %0d", c, r_lms0, $signed(arq[base + L]));
            end
            if (n1 != L || soma1 != sig_soma[c] || pond1 !== sig_pond[c]) begin
                e_caso = e_caso + 1;
                $display("[FAIL] caso %0d: y(n) -- %0d amostras, soma %0d (esp %0d), assinatura %0d (esp %0d)",
                         c, n1, soma1, sig_soma[c], pond1, sig_pond[c]);
            end
            if (e_caso == 0) begin
                success_count = success_count + 1;
                $display("[PASS] caso %0d: 1056 amostras repassadas intactas, r_lms=%0d bit a bit, y(n) = modelo (soma %0d)  [%0d ciclos]",
                         c, r_lms0, soma1, ciclos);
            end else
                fail_count = fail_count + 1;
        end

        if (ready0 && ready1) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova janela sem reset");
        end else begin
            fail_count = fail_count + 1; $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO ESTAGIO LMS PASSARAM COM SUCESSO!");
        $finish;
    end

    initial begin #500_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
