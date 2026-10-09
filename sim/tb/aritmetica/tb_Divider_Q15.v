// ============================================================================
// tb_Divider_Q15 -- testbench do divisor Q1.15
// ============================================================================

`timescale 1ns / 1ps

module tb_Divider_Q15;

    parameter NUM_W = 32;
    parameter DEN_W = 32;
    parameter FRAC  = 15;
    parameter CLK_PERIOD = 20;
    parameter N_ALEAT = 2000;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                  start;
    reg  [NUM_W-1:0]     num;
    reg  [DEN_W-1:0]     den;
    wire                 ready, done, div_zero;
    wire [FRAC:0]        quociente;

    Divider_Q15 #(.NUM_W(NUM_W), .DEN_W(DEN_W), .FRAC(FRAC)) uut (
        .clk(clk), .rst(rst), .start(start), .ready(ready), .done(done),
        .num(num), .den(den), .quociente(quociente), .div_zero(div_zero)
    );

    integer success_count = 0;
    integer fail_count    = 0;
    integer erros_mostrados = 0;
    integer ciclos_max = 0;

    // referencia independente
    function [FRAC:0] ref_q;
        input [NUM_W-1:0] n;
        input [DEN_W-1:0] d;
        reg [63:0] v;
        begin
            if (d == 0) ref_q = {(FRAC+1){1'b1}};
            else begin
                v = ({32'd0, n} << FRAC) / {32'd0, d};
                ref_q = (v > 32767) ? 16'h7FFF : v[FRAC:0];
            end
        end
    endfunction

    task divide;
        input [NUM_W-1:0] n;
        input [DEN_W-1:0] d;
        integer c;
        begin
            @(negedge clk);
            num = n; den = d; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            c = 0;
            while (done !== 1'b1 && c < 100) begin
                @(posedge clk);
                c = c + 1;
            end
            if (c > ciclos_max) ciclos_max = c;
        end
    endtask

    task checa;
        input [NUM_W-1:0] n;
        input [DEN_W-1:0] d;
        reg [FRAC:0] esp;
        begin
            divide(n, d);
            esp = ref_q(n, d);
            if (quociente !== esp) begin
                fail_count = fail_count + 1;
                if (erros_mostrados < 10) begin
                    $display("[FAIL] %0d/%0d: obtido %0d, esperado %0d",
                             n, d, quociente, esp);
                    erros_mostrados = erros_mostrados + 1;
                end
            end
        end
    endtask

    integer i, n_ok;
    reg [31:0] lfsr;

    initial begin
        $display("======================================================================");
        $display("   DIVISOR Q1.15 (restauracao) -- razoes do classificador             ");
        $display("======================================================================");

        rst = 1; start = 0; num = 0; den = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ---- casos de borda ----
        n_ok = fail_count;
        checa(32'd0,      32'd1000);     // numerador zero
        checa(32'd1,      32'd1);        // num == den -> satura
        checa(32'd1000,   32'd1000);     // idem
        checa(32'd1,      32'd32768);    // menor razao representavel
        checa(32'd1,      32'd100000);   // abaixo da resolucao -> 0
        checa(32'd50000,  32'd100000);   // 0.5
        checa(32'd99999,  32'd100000);   // perto de 1
        checa(32'd200000, 32'd100000);   // maior que 1 -> satura
        if (fail_count == n_ok) begin
            success_count = success_count + 1;
            $display("[PASS] 8 casos de borda corretos (zero, igualdade, saturacao, resolucao)");
        end

        // ---- divisao por zero ----
        divide(32'd1234, 32'd0);
        if (div_zero === 1'b1 && quociente === 16'h7FFF) begin
            success_count = success_count + 1;
            $display("[PASS] Divisao por zero: sinaliza div_zero e satura, sem travar");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Divisao por zero: div_zero=%b q=%0d", div_zero, quociente);
        end

        // ---- varredura pseudo-aleatoria ----
        n_ok = fail_count;
        lfsr = 32'hACE1_2345;
        for (i = 0; i < N_ALEAT; i = i + 1) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            // faixa tipica das razoes: numerador menor que o denominador
            checa(lfsr[19:0] % 40000, (lfsr[31:20] % 60000) + 40000);
        end
        if (fail_count == n_ok) begin
            success_count = success_count + 1;
            $display("[PASS] %0d divisoes pseudo-aleatorias corretas", N_ALEAT);
        end else begin
            $display("[FAIL] %0d de %0d divisoes aleatorias erradas",
                     fail_count - n_ok, N_ALEAT);
        end

        // ---- latencia ----
        if (ciclos_max <= FRAC + 4) begin
            success_count = success_count + 1;
            $display("[PASS] Latencia maxima: %0d ciclos (1 bit por ciclo)", ciclos_max);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Latencia de %0d ciclos, esperado ate %0d", ciclos_max, FRAC+4);
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO DIVISOR PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO DIVISOR.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
