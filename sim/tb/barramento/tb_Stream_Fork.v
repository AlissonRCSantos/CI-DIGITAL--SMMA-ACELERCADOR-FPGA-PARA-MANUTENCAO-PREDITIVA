// ============================================================================
// tb_Stream_Fork -- testbench do join com 3 consumidores
// ============================================================================

`timescale 1ns / 1ps

module tb_Stream_Fork;

    localparam N = 3, TOTAL = 200;

    reg clk = 0, rst = 1;
    always #10 clk = ~clk;

    reg         in_valid = 0;
    reg  [15:0] dado = 0;
    wire        in_ready;
    wire [N-1:0] out_valid;
    reg  [N-1:0] out_ready = 0;

    Stream_Fork #(.N(N)) uut (.in_valid(in_valid), .in_ready(in_ready),
                              .out_valid(out_valid), .out_ready(out_ready));

    // LFSR para os ready dos consumidores
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        out_ready <= lfsr[2:0] | {lfsr[5], 2'b00};
    end

    // produtor: segura o dado ate o handshake
    integer enviados = 0;
    always @(posedge clk) begin
        if (rst) begin in_valid <= 0; dado <= 0; end
        else begin
            if (in_valid && in_ready) begin
                enviados <= enviados + 1;
                dado     <= dado + 1;
                in_valid <= (enviados + 1 < TOTAL) && lfsr[7];
            end else if (!in_valid && enviados < TOTAL)
                in_valid <= lfsr[8];
        end
    end

    // consumidores: conferem a sequencia
    integer recebidos [0:N-1];
    integer erros = 0, i;
    always @(posedge clk)
        for (i = 0; i < N; i = i + 1)
            if (out_valid[i] && out_ready[i]) begin
                if (dado !== recebidos[i]) erros = erros + 1;
                recebidos[i] = recebidos[i] + 1;
            end

    integer success_count = 0, fail_count = 0;
    initial begin
        $display("======================================================================");
        $display("   STREAM_FORK -- handshake com 3 consumidores independentes          ");
        $display("======================================================================");
        for (i = 0; i < N; i = i + 1) recebidos[i] = 0;
        repeat (3) @(negedge clk); rst = 0;
        wait (enviados == TOTAL);
        repeat (5) @(negedge clk);
        if (erros == 0 && recebidos[0] == TOTAL && recebidos[1] == TOTAL && recebidos[2] == TOTAL) begin
            success_count = success_count + 1;
            $display("[PASS] %0d palavras entregues aos 3 consumidores, em ordem, sem perda nem duplicacao", TOTAL);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] recebidos %0d/%0d/%0d, %0d fora de ordem",
                     recebidos[0], recebidos[1], recebidos[2], erros);
        end
        $display("\n RESUMO: %0d OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0) $display(" TODOS OS TESTES DO STREAM_FORK PASSARAM");
        $finish;
    end

    initial begin #1_000_000; $display("[FAIL] timeout"); $finish; end
endmodule
