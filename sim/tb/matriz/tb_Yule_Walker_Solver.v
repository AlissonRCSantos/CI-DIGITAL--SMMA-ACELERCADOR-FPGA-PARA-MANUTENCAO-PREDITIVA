// ============================================================================
// Module: tb_Yule_Walker_Solver
// Description: Testbench do MODULO DE INVERSAO DE MATRIZ completo, ligado como
//              no SMMA_Top:
//
//     amostras -> autocorrelacao_yw -> Yule_Walker_Solver <-> gauss_jordan_inv
//                                                 |
//                                          a1/2, a2/2, a3/2 (Q1.15)
//
// Referencia: numpy.linalg.solve(R, r) / 2 em PONTO FLUTUANTE, sobre os
// mesmos rho em Q1.15 que o hardware produz (6 janelas reais de
// vetores/temp_teste.hex). A diferenca aceita e de 4 LSB (1,2e-4): o
// hardware faz Gauss-Jordan em Q8.16, e a comparacao e justamente a
// "analise de diferencas numericas" pedida no 6.6 -- o desvio maximo
// observado e impresso no final.
//
// A janela 4 e a mais mal condicionada (cond(R) ~ 66, |R^-1| ~ 16): e o caso
// que estoura o formato Q4.12 original e motivou o Q8.16.
// ============================================================================

`timescale 1ns / 1ps

module tb_Yule_Walker_Solver;

    parameter WIDTH      = 16;
    parameter L          = 1056;
    parameter N_FEAT_ARQ = 4;
    parameter MAX_CASOS  = 6;
    parameter TOL        = 4;
    parameter CLK_PERIOD = 20;
    localparam W_INV = 24, F_INV = 16;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    // a/2 esperado (numpy, ponto flutuante), arredondado para Q1.15
    reg signed [15:0] esp [0:MAX_CASOS*3-1];
    initial begin
        esp[ 0]=-16622; esp[ 1]= -9990; esp[ 2]=-5730;
        esp[ 3]=-17182; esp[ 4]=-10402; esp[ 5]=-5198;
        esp[ 6]=-11460; esp[ 7]= -1230; esp[ 8]=  406;
        esp[ 9]=-15885; esp[10]=-11504; esp[11]=-2672;
        esp[12]=-22730; esp[13]=-11043; esp[14]=-2484;
        esp[15]=-12034; esp[16]= -6744; esp[17]=-6145;
    end

    reg                      start;
    reg                      in_valid;
    reg  signed [WIDTH-1:0]  in_sample;
    wire                     in_ready, ac_ready, ac_busy;
    wire                     r_valid;
    wire [2:0]               r_index;
    wire signed [WIDTH-1:0]  r_data;

    autocorrelacao_yw #(.WIDTH(WIDTH), .FRAC(15), .N_AMOSTRAS(L), .N_LAGS(3)) u_ac (
        .clk(clk), .reset(rst), .start(start), .ready(ac_ready), .busy(ac_busy),
        .lms_valid(in_valid), .lms_ready(in_ready), .lms_data(in_sample),
        .r_valid(r_valid), .r_index(r_index), .r_data(r_data)
    );

    wire                     yw_ready, yw_busy, yw_done, yw_singular;
    wire                     out_valid;
    wire signed [WIDTH-1:0]  out_feature;
    reg                      out_ready;

    wire                     inv_valid_in, inv_ready, inv_start;
    wire                     inv_valid_out, inv_busy, inv_singular;
    wire [1:0]               inv_load_row, inv_load_col, inv_read_row;
    wire [2:0]               inv_n, inv_read_col;
    wire signed [W_INV-1:0]  inv_load_data, inv_read_data;

    Yule_Walker_Solver #(.WIDTH(WIDTH), .W_INV(W_INV), .F_INV(F_INV), .ORDEM(3)) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(yw_ready), .busy(yw_busy), .done(yw_done),
        .r_valid(r_valid), .r_index(r_index), .r_data(r_data),
        .inv_valid_in(inv_valid_in), .inv_ready(inv_ready),
        .inv_load_row(inv_load_row), .inv_load_col(inv_load_col),
        .inv_load_data(inv_load_data), .inv_start(inv_start), .inv_n(inv_n),
        .inv_valid_out(inv_valid_out), .inv_singular(inv_singular),
        .inv_read_row(inv_read_row), .inv_read_col(inv_read_col),
        .inv_read_data(inv_read_data),
        .out_ready(out_ready), .out_valid(out_valid), .out_feature(out_feature),
        .singular(yw_singular)
    );

    gauss_jordan_inv #(.WIDTH(W_INV), .FRAC(F_INV), .N_MAX(4), .EPSILON(24'sd128)) u_inv (
        .clk(clk), .reset(rst), .enable(1'b1), .start(inv_start), .n(inv_n),
        .valid_in(inv_valid_in), .ready(inv_ready),
        .load_row(inv_load_row), .load_col(inv_load_col), .load_data(inv_load_data),
        .valid_out(inv_valid_out), .busy(inv_busy), .singular(inv_singular),
        .read_row(inv_read_row), .read_col(inv_read_col), .read_data(inv_read_data)
    );

    reg [15:0] arq [0:2 + MAX_CASOS*(L + N_FEAT_ARQ) - 1];
    integer n_casos;
    integer success_count = 0, fail_count = 0;

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

    reg signed [WIDTH-1:0] a [0:2];
    integer n_out;
    always @(posedge clk)
        if (!rst && out_valid && out_ready) begin a[n_out] = out_feature; n_out = n_out + 1; end

    integer c, k, base, ciclos, d, dmax, erros_caso;

    initial begin
        $display("======================================================================");
        $display("  INVERSAO DE MATRIZ: autocorrelacao -> Yule-Walker -> Gauss-Jordan   ");
        $display("======================================================================");
        $readmemh("vetores/temp_teste.hex", arq);
        n_casos = arq[0];
        rst = 1; start = 0; enviando = 0; out_ready = 1; dmax = 0;
        repeat (3) @(negedge clk); rst = 0; @(negedge clk);

        for (c = 0; c < n_casos; c = c + 1) begin
            base = 2 + c*(L + N_FEAT_ARQ); base_in = base;
            n_out = 0; enviando = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            enviando = 1;
            ciclos = 0;
            while (n_out < 3 && ciclos < 200000) begin
                @(posedge clk); ciclos = ciclos + 1;
                out_ready = (ciclos % 3) != 0;          // contrapressao na saida
            end
            out_ready = 1; enviando = 0;
            repeat (3) @(negedge clk);

            erros_caso = 0;
            for (k = 0; k < 3; k = k + 1) begin
                d = a[k] - esp[3*c+k]; if (d < 0) d = -d;
                if (d > dmax) dmax = d;
                if (d > TOL) begin
                    erros_caso = erros_caso + 1;
                    $display("[FAIL] caso %0d a%0d/2: obtido %0d, esperado %0d", c, k+1, a[k], esp[3*c+k]);
                end
            end
            if (yw_singular) begin
                erros_caso = erros_caso + 1;
                $display("[FAIL] caso %0d: matriz sinalizada como singular", c);
            end
            if (erros_caso == 0) begin
                success_count = success_count + 1;
                $display("[PASS] caso %0d: a = [%7.4f %7.4f %7.4f]  (numpy: [%7.4f %7.4f %7.4f])",
                         c, a[0]*2.0/32768.0, a[1]*2.0/32768.0, a[2]*2.0/32768.0,
                         esp[3*c]*2.0/32768.0, esp[3*c+1]*2.0/32768.0, esp[3*c+2]*2.0/32768.0);
            end else
                fail_count = fail_count + 1;
        end

        $display("\n   desvio maximo em relacao ao ponto flutuante: %0d LSB de Q1.15", dmax);

        if (yw_ready && ac_ready && inv_ready) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: os tres blocos voltaram ao repouso");
        end else begin
            fail_count = fail_count + 1; $display("[FAIL] Algum bloco nao voltou ao repouso");
        end

        $display("\n RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DA INVERSAO DE MATRIZ PASSARAM COM SUCESSO!");
        $finish;
    end

    initial begin #200_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
