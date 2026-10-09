// ============================================================================
// tb_FFT_Log2_Compress -- testbench: log2 nas 65 536 entradas
// ============================================================================

`timescale 1ns / 1ps

module tb_FFT_Log2_Compress;

    parameter WIDTH      = 16;
    parameter CLK_PERIOD = 20;

    reg                  clk = 0;
    reg                  rst;
    reg                  en;
    reg                  in_valid;
    reg  [WIDTH-1:0]     in_mag;
    wire                 out_valid;
    wire [WIDTH-1:0]     out_pixel;

    integer success_count = 0;
    integer fail_count    = 0;
    integer erros_mostrados = 0;

    FFT_Log2_Compress #(.WIDTH(WIDTH)) uut (
        .clk(clk), .rst(rst), .en(en),
        .in_valid(in_valid), .in_mag(in_mag),
        .out_valid(out_valid), .out_pixel(out_pixel)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Referencia independente: expoente por divisoes sucessivas
    function integer pixel_ref;
        input integer mag;
        integer m, e, tmp, frac, mant, pix;
        begin
            m = mag + 1;
            e = 0;
            tmp = m;
            while (tmp > 1) begin      // e = floor(log2 m), por divisao
                tmp = tmp / 2;
                e = e + 1;
            end
            frac = m - (1 << e);
            mant = (frac * 2048) / (1 << e);   // ((frac << 11) >> e)
            pix  = e * 2048 + mant;
            if (pix > 32767) pix = 32767;
            pixel_ref = pix;
        end
    endfunction

    integer k;
    integer esperado;
    integer pix_anterior;
    integer degrau, maior_degrau;

    initial begin
        $display("======================================================================");
        $display("   TESTE EXAUSTIVO DA COMPRESSAO LOG2 DO ESPECTROGRAMA (65536 casos)  ");
        $display("======================================================================");

        rst = 1; en = 1; in_valid = 0; in_mag = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        pix_anterior = -1;
        maior_degrau = 0;

        // ---- Varredura completa do espaco de entrada ----
        for (k = 0; k < 65536; k = k + 1) begin
            @(negedge clk);
            in_mag   = k[WIDTH-1:0];
            in_valid = 1'b1;
            @(posedge clk);            // DUT registra neste flanco
            @(negedge clk);            // saida ja disponivel

            esperado = pixel_ref(k);

            if (out_pixel !== esperado[WIDTH-1:0]) begin
                fail_count = fail_count + 1;
                if (erros_mostrados < 10) begin
                    $display("[FAIL] mag=%0d: esperado %0d, obtido %0d",
                             k, esperado, out_pixel);
                    erros_mostrados = erros_mostrados + 1;
                end
            end

            if ((k > 0) && (out_pixel < pix_anterior)) begin
                fail_count = fail_count + 1;
                if (erros_mostrados < 10) begin
                    $display("[FAIL] monotonicidade quebrada em mag=%0d: %0d -> %0d",
                             k, pix_anterior, out_pixel);
                    erros_mostrados = erros_mostrados + 1;
                end
            end

            // Propriedade 2: maior degrau entre amostras consecutivas
            if (pix_anterior >= 0) begin
                degrau = out_pixel - pix_anterior;
                if (degrau > maior_degrau) maior_degrau = degrau;
            end
            pix_anterior = out_pixel;
        end

        if (fail_count == 0) begin
            success_count = success_count + 1;
            $display("[PASS] 65536/65536 valores batem BIT A BIT com a referencia");
            $display("[PASS] monotonicidade preservada em todo o dominio");
        end

        // Pontos de ancora conferidos a mao contra python/smma/espectrograma.py
        $display("\n-- Pontos de ancora (conferidos contra o modelo Python) --");
        $display("   mag=    0  -> pixel=%5d   (esperado     0)", pixel_ref(0));
        $display("   mag=    1  -> pixel=%5d   (esperado  2048)", pixel_ref(1));
        $display("   mag= 2048  -> pixel=%5d   (esperado 22529)", pixel_ref(2048));
        $display("   mag=32767  -> pixel=%5d   (esperado 30720)", pixel_ref(32767));
        $display("   maior degrau entre magnitudes consecutivas: %0d", maior_degrau);

        if (pixel_ref(0)==0 && pixel_ref(1)==2048 &&
            pixel_ref(2048)==22529 && pixel_ref(32767)==30720) begin
            success_count = success_count + 1;
            $display("[PASS] Ancoras conferem com a especificacao Python");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Ancoras divergem da especificacao Python");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DA COMPRESSAO LOG2 PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NA COMPRESSAO LOG2.");
        $display("======================================================================");
        $finish;
    end

endmodule
