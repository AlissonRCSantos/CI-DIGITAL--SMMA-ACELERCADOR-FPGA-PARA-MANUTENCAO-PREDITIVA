// ============================================================================
// Module: tb_gauss_jordan_inv
// Description: Testbench isolado do inversor de matriz (Gauss-Jordan com
//              pivotamento parcial), nas DUAS configuracoes de formato:
//
//                DUT A: Q4.12 em 16 bits  (configuracao original da branch)
//                DUT B: Q8.16 em 24 bits  (configuracao usada no SMMA_Top)
//
// Casos (inversas de referencia calculadas com numpy):
//   1. 2x2  [[4,7],[2,6]]                      -> [[0.6,-0.7],[-0.2,0.4]]
//   2. 3x3  [[0,2,1],[1,1,0],[2,0,1]]          pivo nulo na diagonal: exige
//                                              TROCA DE LINHAS
//   3. 4x4  tridiagonal Toeplitz (4 na diagonal, 1 fora) -- dimensao maxima
//   4. 2x2  singular [[1,2],[2,4]]             -> 'singular' = 1
// Tolerancia: 4 LSB do formato de cada DUT.
// ============================================================================

`timescale 1ns / 1ps

module tb_gauss_jordan_inv;

    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    // ---------------- DUT A: Q4.12 ----------------
    reg               a_start = 0, a_valid = 0;
    reg  [2:0]        a_n = 0;
    reg  [1:0]        a_lr = 0, a_lc = 0, a_rr = 0;
    reg  [2:0]        a_rc = 0;
    reg  signed [15:0] a_ld = 0;
    wire              a_ready, a_vout, a_busy, a_sing;
    wire signed [15:0] a_rd;

    gauss_jordan_inv #(.WIDTH(16), .FRAC(12), .N_MAX(4), .EPSILON(16'sd8)) dut_a (
        .clk(clk), .reset(rst), .enable(1'b1), .start(a_start), .n(a_n),
        .valid_in(a_valid), .ready(a_ready),
        .load_row(a_lr), .load_col(a_lc), .load_data(a_ld),
        .valid_out(a_vout), .busy(a_busy), .singular(a_sing),
        .read_row(a_rr), .read_col(a_rc), .read_data(a_rd));

    // ---------------- DUT B: Q8.16 ----------------
    reg               b_start = 0, b_valid = 0;
    reg  [2:0]        b_n = 0;
    reg  [1:0]        b_lr = 0, b_lc = 0, b_rr = 0;
    reg  [2:0]        b_rc = 0;
    reg  signed [23:0] b_ld = 0;
    wire              b_ready, b_vout, b_busy, b_sing;
    wire signed [23:0] b_rd;

    gauss_jordan_inv #(.WIDTH(24), .FRAC(16), .N_MAX(4), .EPSILON(24'sd128)) dut_b (
        .clk(clk), .reset(rst), .enable(1'b1), .start(b_start), .n(b_n),
        .valid_in(b_valid), .ready(b_ready),
        .load_row(b_lr), .load_col(b_lc), .load_data(b_ld),
        .valid_out(b_vout), .busy(b_busy), .singular(b_sing),
        .read_row(b_rr), .read_col(b_rc), .read_data(b_rd));

    real A   [0:15];     // matriz de entrada (linha*4 + coluna)
    real INV [0:15];     // inversa de referencia
    integer success_count = 0, fail_count = 0;
    integer i, j, c, erros;
    real ga, gb, da, db, dmax_a, dmax_b;

    task carrega_e_inverte(input integer n);
        begin
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    @(negedge clk);
                    a_valid = 1; a_lr = i; a_lc = j; a_ld = $rtoi(A[i*4+j] * 4096.0);
                    b_valid = 1; b_lr = i; b_lc = j; b_ld = $rtoi(A[i*4+j] * 65536.0);
                end
            @(negedge clk); a_valid = 0; b_valid = 0;
            a_n = n; b_n = n; a_start = 1; b_start = 1;
            @(negedge clk); a_start = 0; b_start = 0;
            c = 0;
            while (!(a_vout && b_vout) && c < 5000) begin @(posedge clk); c = c + 1; end
            @(negedge clk);
        end
    endtask

    task confere(input [8*20-1:0] nome, input integer n);
        begin
            erros = 0;
            if (a_sing || b_sing) begin
                erros = 1;
                $display("[FAIL] %0s: sinalizada singular (A=%b B=%b)", nome, a_sing, b_sing);
            end
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    a_rr = i; a_rc = n + j; b_rr = i; b_rc = n + j; #1;
                    ga = a_rd / 4096.0; gb = b_rd / 65536.0;
                    da = ga - INV[i*4+j]; if (da < 0) da = -da;
                    db = gb - INV[i*4+j]; if (db < 0) db = -db;
                    if (da > dmax_a) dmax_a = da;
                    if (db > dmax_b) dmax_b = db;
                    if (da > 4.0/4096.0 || db > 4.0/65536.0) begin
                        erros = erros + 1;
                        $display("[FAIL] %0s inv[%0d][%0d]: Q4.12=%f Q8.16=%f esperado %f",
                                 nome, i, j, ga, gb, INV[i*4+j]);
                    end
                end
            if (erros == 0) begin
                success_count = success_count + 1;
                $display("[PASS] %0s: inversa correta nos dois formatos (%0d ciclos)", nome, c);
            end else
                fail_count = fail_count + 1;
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("   INVERSOR GAUSS-JORDAN (pivotamento parcial) -- Q4.12 e Q8.16      ");
        $display("======================================================================");
        dmax_a = 0; dmax_b = 0;
        repeat (3) @(negedge clk); rst = 0; repeat (2) @(negedge clk);

        // 1. 2x2
        A[0]=4; A[1]=7; A[4]=2; A[5]=6;
        INV[0]=0.6; INV[1]=-0.7; INV[4]=-0.2; INV[5]=0.4;
        carrega_e_inverte(2); confere("2x2", 2);

        // 2. 3x3 com troca de linhas
        A[0]=0; A[1]=2; A[2]=1;  A[4]=1; A[5]=1; A[6]=0;  A[8]=2; A[9]=0; A[10]=1;
        INV[0]=-0.25; INV[1]=0.5;  INV[2]=0.25;
        INV[4]= 0.25; INV[5]=0.5;  INV[6]=-0.25;
        INV[8]= 0.5;  INV[9]=-1.0; INV[10]=0.5;
        carrega_e_inverte(3); confere("3x3 com pivoteamento", 3);

        // 3. 4x4 tridiagonal
        for (i = 0; i < 16; i = i + 1) A[i] = 0;
        A[0]=4; A[1]=1; A[4]=1; A[5]=4; A[6]=1; A[9]=1; A[10]=4; A[11]=1; A[14]=1; A[15]=4;
        INV[0]=0.267943;  INV[1]=-0.07177;  INV[2]=0.019139;  INV[3]=-0.004785;
        INV[4]=-0.07177;  INV[5]=0.287081;  INV[6]=-0.076555; INV[7]=0.019139;
        INV[8]=0.019139;  INV[9]=-0.076555; INV[10]=0.287081; INV[11]=-0.07177;
        INV[12]=-0.004785; INV[13]=0.019139; INV[14]=-0.07177; INV[15]=0.267943;
        carrega_e_inverte(4); confere("4x4", 4);

        // 4. singular
        A[0]=1; A[1]=2; A[4]=2; A[5]=4;
        carrega_e_inverte(2);
        if (a_sing === 1'b1 && b_sing === 1'b1 && !a_busy && !b_busy) begin
            success_count = success_count + 1;
            $display("[PASS] 2x2 singular: 'singular' = 1 nos dois formatos, sem travar");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] singular: A=%b B=%b", a_sing, b_sing);
        end

        $display("\n   erro maximo: Q4.12 = %f   Q8.16 = %f", dmax_a, dmax_b);
        $display("\n RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO INVERSOR PASSARAM COM SUCESSO!");
        $finish;
    end

    initial begin #10_000_000; $display("[FAIL] Timeout global"); $finish; end

endmodule
