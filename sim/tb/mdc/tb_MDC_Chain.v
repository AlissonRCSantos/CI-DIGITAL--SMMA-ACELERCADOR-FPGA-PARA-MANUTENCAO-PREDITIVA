// ============================================================================
// Module: tb_MDC_Chain
// Description: Testbench do MODULO MDC completo, ligado como no SMMA_Top:
//
//     espectro medio (32 bins) -> peak_detector -> mdc_gcd -> f0_estimator
//
// Casos:
//   1. Exemplo do enunciado (3.1): picos nos bins 12, 18 e 30
//      -> k0 = MDC(12,18,30) = 6 -> f0 = 6 * 3200 / 64 = 300 Hz.
//   2. Harmonicos de 50 Hz (bins 2, 4, 6 de uma rotacao em 100 Hz)
//      -> k0 = 2 -> f0 = 100 Hz.
//   3. Picos sem fator comum (bins 7, 11, 13) -> k0 = 1 -> 50 Hz.
//   4. Espectro plano abaixo do limiar: nenhum pico -> MDC sinaliza erro.
//   5. Reuso sem reset (caso 1 de novo).
// ============================================================================

`timescale 1ns / 1ps

module tb_MDC_Chain;

    localparam N_BINS = 32;
    localparam FS     = 3200;

    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    reg         start = 0;
    reg         mag_valid = 0;
    reg  [15:0] mag_data = 0;
    wire        mag_ready;

    wire        pk_valid, pk_ready;
    wire [5:0]  pk_data;
    wire        mdc_valid, mdc_ready, mdc_err;
    wire [5:0]  k0;
    wire        f0_valid;
    wire [19:0] f0_int;
    wire [5:0]  f0_frac;
    wire        pk_busy, pk_done, mdc_busy, mdc_done, f0_busy, f0_done;

    peak_detector #(.FFT_N(N_BINS), .IDX_WIDTH(6), .MAG_WIDTH(16), .NUM_PEAKS(3),
                    .SEARCH_START(1), .SEARCH_END(N_BINS-2)) u_peak (
        .clk(clk), .rst_n(!rst), .start(start), .busy(pk_busy), .done(pk_done),
        .mag_valid(mag_valid), .mag_ready(mag_ready), .mag_data(mag_data),
        .cfg_threshold(16'd64),
        .out_valid(pk_valid), .out_ready(pk_ready), .out_data(pk_data));

    mdc_gcd #(.IDX_WIDTH(6), .NUM_PEAKS(3)) u_mdc (
        .clk(clk), .rst_n(!rst), .start(start), .busy(mdc_busy), .done(mdc_done),
        .in_valid(pk_valid), .in_ready(pk_ready), .in_data(pk_data),
        .cfg_min_valid(6'd1),
        .out_valid(mdc_valid), .out_ready(mdc_ready), .out_data(k0), .out_error(mdc_err));

    f0_estimator #(.FFT_N(64), .IDX_WIDTH(6), .FS_WIDTH(20)) u_f0 (
        .clk(clk), .rst_n(!rst), .start(1'b0), .busy(f0_busy), .done(f0_done),
        .in_valid(mdc_valid), .in_ready(mdc_ready), .in_data(k0),
        .cfg_fs(FS[19:0]),
        .out_valid(f0_valid), .out_ready(1'b1), .f0_int(f0_int), .f0_frac(f0_frac));

    reg [5:0] k0_cap;  reg err_cap;
    always @(posedge clk) if (mdc_valid && mdc_ready) begin k0_cap <= k0; err_cap <= mdc_err; end

    reg [15:0] espectro [0:N_BINS-1];
    integer success_count = 0, fail_count = 0;
    integer b;

    task monta(input integer p1, input integer p2, input integer p3, input integer nivel);
        begin
            for (b = 0; b < N_BINS; b = b + 1) espectro[b] = 16'd20 + (b % 3);
            if (p1 > 0) espectro[p1] = nivel;
            if (p2 > 0) espectro[p2] = nivel - 100;
            if (p3 > 0) espectro[p3] = nivel - 200;
        end
    endtask

    task roda(input [8*24-1:0] nome, input integer k0_esp, input integer err_esp,
              input integer f0_esp);
        integer c;
        begin
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            for (b = 0; b < N_BINS; b = b + 1) begin
                mag_valid = 1; mag_data = espectro[b];
                @(posedge clk); while (!mag_ready) @(posedge clk);
                #1;
            end
            mag_valid = 0;
            c = 0;
            while (!f0_valid && c < 2000) begin @(posedge clk); c = c + 1; end
            #1;
            if (c >= 2000) begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s: timeout", nome);
            end else if (err_esp) begin
                if (err_cap === 1'b1) begin
                    success_count = success_count + 1;
                    $display("[PASS] %0s: MDC sinalizou resultado invalido (err=1)", nome);
                end else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] %0s: esperado err=1, obtido k0=%0d err=%0d", nome, k0_cap, err_cap);
                end
            end else if (k0_cap === k0_esp && err_cap === 1'b0 && f0_int === f0_esp && f0_frac === 0) begin
                success_count = success_count + 1;
                $display("[PASS] %0s: k0=%0d -> f0=%0d Hz (%0d ciclos apos o ultimo bin)", nome, k0_cap, f0_int, c);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s: esperado k0=%0d f0=%0d | obtido k0=%0d err=%0d f0=%0d",
                         nome, k0_esp, f0_esp, k0_cap, err_cap, f0_int);
            end
            repeat (5) @(negedge clk);
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("   MODULO MDC: peak_detector -> mdc_gcd -> f0_estimator               ");
        $display("======================================================================");
        repeat (3) @(negedge clk); rst = 0; repeat (2) @(negedge clk);

        monta(12, 18, 30, 900); roda("enunciado 12,18,30",  6, 0, 300);
        monta( 2,  4,  6, 900); roda("harmonicos 2,4,6",    2, 0, 100);
        monta( 7, 11, 13, 900); roda("primos 7,11,13",      1, 0,  50);
        monta( 0,  0,  0, 900); roda("sem picos",            0, 1,   0);
        monta(12, 18, 30, 900); roda("reuso sem reset",      6, 0, 300);

        $display("\n RESUMO: %0d OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO MODULO MDC PASSARAM");
        $finish;
    end

    initial begin #5_000_000; $display("[FAIL] timeout global"); $finish; end

endmodule
