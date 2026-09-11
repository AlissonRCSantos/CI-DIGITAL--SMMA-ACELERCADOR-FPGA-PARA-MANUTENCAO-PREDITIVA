`timescale 1ns/1ps

module mdc_gcd_tb;

    localparam IDX_WIDTH = 6;
    localparam NUM_PEAKS = 3;
    localparam CLK_PERIOD = 20; // 50 MHz

    reg                   clk;
    reg                   rst_n;
    reg                   start;
    wire                  busy;
    wire                  done;

    reg                   in_valid;
    wire                  in_ready;
    reg  [IDX_WIDTH-1:0]  in_data;

    reg  [IDX_WIDTH-1:0]  cfg_min_valid;

    wire                  out_valid;
    reg                   out_ready;
    wire [IDX_WIDTH-1:0]  out_data;
    wire                  out_error;

    integer errors;

    mdc_gcd #(
        .IDX_WIDTH(IDX_WIDTH),
        .NUM_PEAKS(NUM_PEAKS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .cfg_min_valid(cfg_min_valid),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .out_error(out_error)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------
    // task: envia um pico via handshake in_valid/in_ready
    // -------------------------------------------------------------
    task send_peak(input [IDX_WIDTH-1:0] value);
        begin
            @(posedge clk);
            in_data  <= value;
            in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            in_valid <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------
    // task: roda um caso de teste completo com 3 picos
    // -------------------------------------------------------------
    task run_case(
        input [IDX_WIDTH-1:0] p0, p1, p2,
        input [IDX_WIDTH-1:0] min_valid,
        input [IDX_WIDTH-1:0] expected_k0,
        input                 expected_error,
        input [127:0]         case_name
    );
        integer cycles;
        begin
            cfg_min_valid <= min_valid;
            out_ready     <= 1'b1;

            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            cycles = 0;
            send_peak(p0);
            send_peak(p1);
            send_peak(p2);

            // espera o resultado (com timeout de simulacao)
            while (!done && cycles < 1000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end

            if (cycles >= 1000) begin
                $display("[FALHA] %0s: timeout de simulacao, done nunca chegou", case_name);
                errors = errors + 1;
            end else if (out_data !== expected_k0 || out_error !== expected_error) begin
                $display("[FALHA] %0s: esperado k0=%0d err=%0d | obtido k0=%0d err=%0d (%0d ciclos)",
                          case_name, expected_k0, expected_error, out_data, out_error, cycles);
                errors = errors + 1;
            end else begin
                $display("[OK]    %0s: k0=%0d err=%0d em %0d ciclos",
                          case_name, out_data, out_error, cycles);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; start = 0;
        in_valid = 0; in_data = 0; out_ready = 0;
        cfg_min_valid = 0; errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Caso 1: exemplo do enunciado -> MDC(12,18,30) = 6
        run_case(12, 18, 30, 1, 6, 1'b0, "picos_12_18_30");

        // Caso 2: MDC(4,6,10) = 2
        run_case(4, 6, 10, 1, 2, 1'b0, "picos_4_6_10");

        // Caso 3: todos iguais -> MDC(8,8,8) = 8
        run_case(8, 8, 8, 1, 8, 1'b0, "picos_8_8_8");

        // Caso 4: um pico zero e tratado como neutro -> MDC(0,15,25)=5
        run_case(0, 15, 25, 1, 5, 1'b0, "picos_0_15_25");

        // Caso 5: todos zero -> invalido
        run_case(0, 0, 0, 1, 0, 1'b1, "picos_0_0_0");

        // Caso 6: resultado (k0=6) abaixo do minimo configurado (10) -> erro
        run_case(12, 18, 30, 10, 6, 1'b1, "abaixo_do_minimo");

        if (errors == 0)
            $display("\n===== TODOS OS TESTES PASSARAM =====");
        else
            $display("\n===== %0d TESTE(S) FALHARAM =====", errors);

        $finish;
    end

endmodule
