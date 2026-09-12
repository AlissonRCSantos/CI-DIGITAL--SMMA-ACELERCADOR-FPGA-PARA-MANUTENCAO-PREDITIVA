`timescale 1ns/1ps

module peak_detector_tb;

    localparam FFT_N     = 64;
    localparam IDX_WIDTH = 6;
    localparam MAG_WIDTH = 16;
    localparam CLK_PERIOD = 20; // 50 MHz

    reg                    clk, rst_n, start;
    wire                   busy, done;

    reg                    mag_valid;
    wire                   mag_ready;
    reg  [MAG_WIDTH-1:0]   mag_data;

    reg  [MAG_WIDTH-1:0]   cfg_threshold;

    wire                   out_valid;
    reg                    out_ready;
    wire [IDX_WIDTH-1:0]   out_data;

    reg [MAG_WIDTH-1:0] spectrum [0:FFT_N-1];
    integer errors;

    peak_detector #(
        .FFT_N(FFT_N), .IDX_WIDTH(IDX_WIDTH), .MAG_WIDTH(MAG_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .mag_valid(mag_valid), .mag_ready(mag_ready), .mag_data(mag_data),
        .cfg_threshold(cfg_threshold),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------
    // roda um caso: envia o espectro (ja carregado em `spectrum`),
    // coleta os 3 indices de saida e compara com o esperado
    // -------------------------------------------------------------
    task run_case(
        input [MAG_WIDTH-1:0] threshold,
        input [IDX_WIDTH-1:0] exp0, exp1, exp2,
        input [127:0]         case_name
    );
        integer k;
        reg [IDX_WIDTH-1:0] got [0:2];
        integer got_ptr;
        integer cycles;
        begin
            cfg_threshold <= threshold;
            out_ready     <= 1'b1;
            got_ptr = 0;

            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            k = 0;
            cycles = 0;
            while (k < FFT_N) begin
                @(posedge clk);
                if (mag_ready) begin
                    mag_data  <= spectrum[k];
                    mag_valid <= 1'b1;
                    k = k + 1;
                end
            end
            @(posedge clk);
            mag_valid <= 1'b0;

            // coleta os 3 valores de saida
            while (got_ptr < 3 && cycles < 200) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (out_valid && out_ready) begin
                    got[got_ptr] = out_data;
                    got_ptr = got_ptr + 1;
                end
            end

            if (got_ptr < 3) begin
                $display("[FALHA] %0s: timeout esperando saida (got_ptr=%0d)", case_name, got_ptr);
                errors = errors + 1;
            end else if (got[0] !== exp0 || got[1] !== exp1 || got[2] !== exp2) begin
                $display("[FALHA] %0s: esperado {%0d,%0d,%0d} obtido {%0d,%0d,%0d}",
                          case_name, exp0, exp1, exp2, got[0], got[1], got[2]);
                errors = errors + 1;
            end else begin
                $display("[OK]    %0s: picos = {%0d,%0d,%0d}", case_name, got[0], got[1], got[2]);
            end

            // esvazia handshake de done
            while (!done) @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        clk = 0; rst_n = 0; start = 0;
        mag_valid = 0; mag_data = 0; out_ready = 0;
        cfg_threshold = 0; errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---------------- Caso 1: picos limpos + decoys fora de faixa
        for (i = 0; i < FFT_N; i = i + 1) spectrum[i] = 16'd5; // ruido de fundo
        spectrum[0]  = 16'd999;  // DC - decoy, deve ser ignorado
        spectrum[44] = 16'd999;  // espelho de bin 20 - decoy, fora da faixa [1,31]
        spectrum[12] = 16'd100;
        spectrum[18] = 16'd80;
        spectrum[30] = 16'd60;
        run_case(16'd20, 6'd12, 6'd18, 6'd30, "picos_limpos_com_decoys");

        // ---------------- Caso 2: vazamento espectral (ombro adjacente)
        for (i = 0; i < FFT_N; i = i + 1) spectrum[i] = 16'd5;
        spectrum[20] = 16'd90;  // pico verdadeiro
        spectrum[21] = 16'd70;  // ombro do lobulo - NAO pode ser escolhido
        spectrum[8]  = 16'd50;
        spectrum[25] = 16'd40;
        run_case(16'd20, 6'd20, 6'd8, 6'd25, "vazamento_espectral");

        // ---------------- Caso 3: limiar alto, so 1 pico qualifica
        for (i = 0; i < FFT_N; i = i + 1) spectrum[i] = 16'd5;
        spectrum[10] = 16'd30;
        spectrum[20] = 16'd25; // abaixo do limiar 28
        run_case(16'd28, 6'd10, 6'd0, 6'd0, "limiar_apenas_um_pico");

        if (errors == 0)
            $display("\n===== TODOS OS TESTES PASSARAM =====");
        else
            $display("\n===== %0d TESTE(S) FALHARAM =====", errors);

        $finish;
    end

endmodule
