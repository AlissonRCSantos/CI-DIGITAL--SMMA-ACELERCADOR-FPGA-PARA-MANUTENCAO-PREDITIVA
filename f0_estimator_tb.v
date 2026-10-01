// =====================================================================
// f0_estimator_tb.v
// Testbench do modulo f0_estimator
//
// Casos cobertos:
//   1) k0=6, fs=10000 Hz  -> f0 = 6*10000/64 = 937,5 Hz
//      (mesmo k0 calculado pelo modulo MDC no exemplo do enunciado)
//   2) k0=8, fs=8000 Hz   -> f0 = 8*8000/64 = 1000 Hz (fracao exata = 0)
//   3) k0=0                -> f0 = 0 Hz (nenhum pico / DC)
//   4) k0=63 (maximo), fs=20000 Hz -> maior valor possivel de f0
// =====================================================================
`timescale 1ns/1ps

module f0_estimator_tb;

    localparam IDX_WIDTH = 6;
    localparam FS_WIDTH  = 20;
    localparam FFT_N     = 64;
    localparam CLK_PERIOD = 20; // 50 MHz

    reg                   clk, rst_n, start;
    wire                  busy, done;

    reg                   in_valid;
    wire                  in_ready;
    reg  [IDX_WIDTH-1:0]  in_data;

    reg  [FS_WIDTH-1:0]   cfg_fs;

    wire                  out_valid;
    reg                   out_ready;
    wire [FS_WIDTH-1:0]   f0_int;
    wire [IDX_WIDTH-1:0]  f0_frac;

    integer errors;

    f0_estimator #(
        .FFT_N(FFT_N), .IDX_WIDTH(IDX_WIDTH), .FS_WIDTH(FS_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .cfg_fs(cfg_fs),
        .out_valid(out_valid), .out_ready(out_ready),
        .f0_int(f0_int), .f0_frac(f0_frac)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    task run_case(
        input [IDX_WIDTH-1:0] k0,
        input [FS_WIDTH-1:0]  fs,
        input [FS_WIDTH-1:0]  exp_int,
        input [IDX_WIDTH-1:0] exp_frac,
        input [127:0]         case_name
    );
        integer cycles;
        begin
            cfg_fs    <= fs;
            out_ready <= 1'b1;

            @(posedge clk);
            in_data  <= k0;
            in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            in_valid <= 1'b0;

            cycles = 0;
            while (!done && cycles < 100) begin
                @(posedge clk);
                cycles = cycles + 1;
            end

            if (cycles >= 100) begin
                $display("[FALHA] %0s: timeout esperando done", case_name);
                errors = errors + 1;
            end else if (f0_int !== exp_int || f0_frac !== exp_frac) begin
                $display("[FALHA] %0s: esperado f0=%0d + %0d/%0d  obtido f0=%0d + %0d/%0d",
                          case_name, exp_int, exp_frac, FFT_N, f0_int, f0_frac, FFT_N);
                errors = errors + 1;
            end else begin
                $display("[OK]    %0s: k0=%0d fs=%0d -> f0 = %0d + %0d/%0d Hz (%0d ciclos)",
                          case_name, k0, fs, f0_int, f0_frac, FFT_N, cycles);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; start = 0;
        in_valid = 0; in_data = 0; out_ready = 0;
        cfg_fs = 0; errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Caso 1: k0=6, fs=10000 -> f0 = 937,5 Hz (937 + 32/64)
        run_case(6, 20'd10000, 20'd937, 6'd32, "k0_6_fs_10000");

        // Caso 2: k0=8, fs=8000 -> f0 = 1000 Hz exatos (fracao = 0)
        run_case(8, 20'd8000, 20'd1000, 6'd0, "k0_8_fs_8000_exato");

        // Caso 3: k0=0 -> f0 = 0 Hz
        run_case(0, 20'd10000, 20'd0, 6'd0, "k0_zero");

        // Caso 4: k0=63 (maximo indice), fs=20000
        // f0 = 63*20000/64 = 1260000/64 = 19687,5 Hz
        run_case(63, 20'd20000, 20'd19687, 6'd32, "k0_maximo");

        if (errors == 0)
            $display("\n===== TODOS OS TESTES PASSARAM =====");
        else
            $display("\n===== %0d TESTE(S) FALHARAM =====", errors);

        $finish;
    end

endmodule
