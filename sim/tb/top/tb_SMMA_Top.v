// ============================================================================
// tb_SMMA_Top -- testbench ponta a ponta pelos pinos da placa
// ============================================================================

`timescale 1ns / 1ps

module tb_SMMA_Top;

    parameter CLK_PERIOD = 20;          // 50 MHz
    parameter N_JANELAS  = 12;

    reg        CLOCK_50 = 0;
    reg  [1:0] KEY;                     // ativo em BAIXO
    reg  [9:0] SW;
    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    always #(CLK_PERIOD/2) CLOCK_50 = ~CLOCK_50;

    SMMA_Top #(.MODO_RAPIDO(1), .N_NOS(141)) uut (
        .CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    integer success_count = 0;
    integer fail_count    = 0;

    // ---- rotulos de referencia, lidos do mesmo arquivo que a ROM usa ----
    // bits[3:2] = classe verdadeira, bits[1:0] = previsao do modelo Python
    reg [3:0] rotulo [0:N_JANELAS-1];

    reg [8*17-1:0] nome_classe [0:3];

    integer j, ciclos;
    integer acertos_modelo, acertos_hw, casam_modelo, concordam_cnn, f0_ok;
    integer f0_lido;
    reg [1:0] hw_arv, hw_cnn, hw_ver, esp_ver, esp_mod;

    function [3:0] le_seg7;
        input [6:0] s;
        begin
            case (s)
                7'b1000000: le_seg7 = 4'd0;
                7'b1111001: le_seg7 = 4'd1;
                7'b0100100: le_seg7 = 4'd2;
                7'b0110000: le_seg7 = 4'd3;
                7'b0011001: le_seg7 = 4'd4;
                7'b0010010: le_seg7 = 4'd5;
                7'b0000010: le_seg7 = 4'd6;
                7'b1111000: le_seg7 = 4'd7;
                7'b0000000: le_seg7 = 4'd8;
                7'b0010000: le_seg7 = 4'd9;
                default:    le_seg7 = 4'hF;      // apagado ou nao-digito
            endcase
        end
    endfunction

    task aperta_disparo;
        begin
            KEY[1] = 1'b1;  repeat (4) @(negedge CLOCK_50);
            KEY[1] = 1'b0;  repeat (4) @(negedge CLOCK_50);   // borda
            KEY[1] = 1'b1;  @(negedge CLOCK_50);
        end
    endtask

    initial begin
        $display("======================================================================");
        $display("    SMMA -- TESTE PONTA A PONTA DO SISTEMA COMPLETO                   ");
        $display("    dataset -> FIR -> /8 -> FFT/MDC/LMS/matriz -> arvore + CNN       ");
        $display("======================================================================");

        $readmemh("vetores/demo_rotulos.hex", rotulo);
        nome_classe[0] = "normal";
        nome_classe[1] = "desbalanceamento";
        nome_classe[2] = "desalinhamento";
        nome_classe[3] = "rolamento";

        acertos_modelo = 0; acertos_hw = 0;
        casam_modelo   = 0; concordam_cnn = 0; f0_ok = 0;

        SW = 10'd0;
        KEY = 2'b00;                     // KEY[0]=0 -> reset ativo
        repeat (8) @(negedge CLOCK_50);
        KEY = 2'b11;                     // libera reset e solta o disparo
        repeat (8) @(negedge CLOCK_50);

        if (LEDR[8] === 1'b0 && LEDR[9] === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reset: parado e sem resultado valido");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Reset: LEDR[8]=%b LEDR[9]=%b", LEDR[8], LEDR[9]);
        end

        $display("\n jan  verdadeira         modelo             arvore(HW)         CNN(HW)");
        $display(" ---------------------------------------------------------------------");

        for (j = 0; j < N_JANELAS; j = j + 1) begin
            SW[3:0] = j[3:0];
            @(negedge CLOCK_50);

            aperta_disparo;

            // espera o veredito (LEDR[9])
            ciclos = 0;
            while (LEDR[9] !== 1'b1 && ciclos < 40_000_000) begin
                @(posedge CLOCK_50);
                ciclos = ciclos + 1;
            end

            if (LEDR[9] !== 1'b1) begin
                fail_count = fail_count + 1;
                $display("[FAIL] janela %0d: travou apos %0d ciclos", j, ciclos);
            end else begin
                hw_arv  = le_seg7(HEX0);
                hw_cnn  = le_seg7(HEX1);
                hw_ver  = le_seg7(HEX2);
                esp_ver = rotulo[j][3:2];
                esp_mod = rotulo[j][1:0];

                $display(" %2d   %-18s %-18s %-18s %-18s %s",
                         j, nome_classe[esp_ver], nome_classe[esp_mod],
                         nome_classe[hw_arv], nome_classe[hw_cnn],
                         (hw_arv === esp_mod) ? "" : "<<< DIVERGE DO MODELO");

                // (1) o hardware reproduz o modelo?
                if (hw_arv === esp_mod) casam_modelo = casam_modelo + 1;
                else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] janela %0d: arvore em HW deu %0d, modelo diz %0d",
                             j, hw_arv, esp_mod);
                end

                // (2) a classe verdadeira chega correta ao painel?
                if (hw_ver !== esp_ver) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] janela %0d: rotulo verdadeiro no painel deu %0d, esperado %0d",
                             j, hw_ver, esp_ver);
                end

                if (esp_mod === esp_ver) acertos_modelo = acertos_modelo + 1;
                if (hw_arv  === esp_ver) acertos_hw     = acertos_hw + 1;
                if (hw_cnn  === esp_ver) concordam_cnn  = concordam_cnn + 1;

                // os LEDs de comparacao tem de contar a mesma historia que os displays
                if (LEDR[4] !== (hw_arv === esp_ver)) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] janela %0d: LEDR[4] contradiz os displays", j);
                end

                // (4) modulo MDC: SW[8] mostra f0 em Hz nos HEX3..HEX0
                SW[8] = 1'b1; @(negedge CLOCK_50);
                f0_lido = (HEX3 === 7'b1111111 ? 0 : le_seg7(HEX3)*1000)
                        + (HEX2 === 7'b1111111 ? 0 : le_seg7(HEX2)*100)
                        + (HEX1 === 7'b1111111 ? 0 : le_seg7(HEX1)*10)
                        +  le_seg7(HEX0);
                if (f0_lido == 50) f0_ok = f0_ok + 1;
                else $display("[FAIL] janela %0d: f0 no painel = %0d Hz, esperado 50 Hz", j, f0_lido);
                SW[8] = 1'b0; @(negedge CLOCK_50);
                if (le_seg7(HEX0) !== hw_arv) begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] janela %0d: painel nao voltou ao modo padrao", j);
                end
            end

            // deixa o sistema voltar sozinho ao repouso
            repeat (20) @(negedge CLOCK_50);
        end

        $display(" ---------------------------------------------------------------------");

        if (casam_modelo === N_JANELAS) begin
            success_count = success_count + 1;
            $display("\n[PASS] A arvore em hardware reproduz o modelo nas %0d janelas",
                     N_JANELAS);
        end

        if (acertos_hw === acertos_modelo) begin
            success_count = success_count + 1;
            $display("[PASS] Acuracia do hardware = do modelo: %0d/%0d",
                     acertos_hw, N_JANELAS);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Hardware %0d/%0d, modelo %0d/%0d",
                     acertos_hw, N_JANELAS, acertos_modelo, N_JANELAS);
        end

        $display("       (a CNN, no mesmo espectrograma, acertou %0d/%0d)",
                 concordam_cnn, N_JANELAS);

        if (f0_ok === N_JANELAS) begin
            success_count = success_count + 1;
            $display("[PASS] MDC: f0 = 50 Hz no painel nas %0d janelas (rotacao de 3010 rpm)",
                     N_JANELAS);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] MDC: f0 correto em %0d/%0d janelas", f0_ok, N_JANELAS);
        end

        // reexecucao sem reset ja foi exercitada 12 vezes acima; aqui so se
        // confirma que o sistema terminou em repouso e aceitaria outra
        if (LEDR[8] === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Terminou em repouso, pronto para outra janela sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Ficou ocupado no fim");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" SISTEMA COMPLETO VERIFICADO PONTA A PONTA COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO SISTEMA COMPLETO.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #40_000_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
