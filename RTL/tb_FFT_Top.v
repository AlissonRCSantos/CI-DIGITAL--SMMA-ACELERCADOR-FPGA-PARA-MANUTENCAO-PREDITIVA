// ============================================================================
// Module: tb_FFT_Top
// Description: Testbench auto-verificavel do modulo FFT de 64 pontos do SMMA.
//
// Estrategia de verificacao:
//   O testbench NAO reimplementa a aritmetica de ponto fixo do DUT. Em vez
//   disso, calcula a DFT IDEAL em ponto flutuante (via $cos/$sin) e compara o
//   resultado do hardware com essa referencia, dentro de uma tolerancia
//   derivada da analise de quantizacao feita em golden_model.py
//   (erro maximo medido: 2 LSB). Isso valida simultaneamente o algoritmo, o
//   escalonamento por estagio, os fatores de rotacao, a inversao de bits e o
//   escalonamento das portas de memoria.
//
// Casos de teste:
//   1. Impulso unitario   -> espectro plano (valida todos os twiddles)
//   2. Nivel DC           -> toda energia no bin 0
//   3. Tom puro no bin 4  -> valida a ordem natural de saida (bit-reversal)
//   4. Tom puro no bin 13 -> bin impar, fase nao nula
//   5. Vibracao de motor  -> fundamental no bin 6 + harmonicas em 12 e 18,
//                            exatamente o exemplo do enunciado (MDC = 6)
//   6. Contrapressao      -> repete o caso 5 com out_ready intermitente,
//                            provando que o handshake nao perde nem
//                            sobrescreve dados
//   7. Reset no meio      -> reset durante o calculo e nova transformada
//
// Entregavel 6.6: o testbench imprime entradas, resultados esperados, obtidos
// e a analise das diferencas numericas (erro maximo e RMS em LSB).
// ============================================================================

`timescale 1ns / 1ps

module tb_FFT_Top;

    // ------------------------------------------------------------------
    // Parametros
    // ------------------------------------------------------------------
    parameter WIDTH      = 16;
    parameter LOG2N      = 6;
    parameter N          = 64;
    parameter CLK_PERIOD = 20;       // 50 MHz
    parameter real PI    = 3.14159265358979323846;

    // Mascara de escalonamento repassada ao DUT. O ganho total da FFT e
    // 2^-(numero de bits em 1), calculado aqui para que estimulo, referencia
    // ideal e DUT fiquem SEMPRE coerentes ao se mudar a mascara.
    parameter [5:0] SCALE_MASK = 6'b001111;

    function integer escala_de;              // 2^(popcount(mask))
        input [5:0] mask;
        integer i;
        begin
            escala_de = 1;
            for (i = 0; i < 6; i = i + 1)
                if (mask[i]) escala_de = escala_de * 2;
        end
    endfunction

    parameter ESCALA_FFT = escala_de(SCALE_MASK);

    // Tolerancias (em LSB de Q1.15). O modelo de referencia em Python mediu
    // erro maximo de 2 LSB; 8 LSB oferece margem sem mascarar defeitos reais.
    parameter TOL_LSB     = 8;
    parameter TOL_MAG_LSB = 40;      // magnitude usa aproximacao de 6,8%

    // ------------------------------------------------------------------
    // Sinais do DUT
    // ------------------------------------------------------------------
    reg                     clk;
    reg                     rst;
    reg                     start;
    reg                     enable;
    reg                     in_valid;
    reg  signed [WIDTH-1:0] in_real;
    reg  signed [WIDTH-1:0] in_imag;

    // ------------------------------------------------------------------
    // Geradores de contrapressao:
    //   bp_enable  -> out_ready baixo em 1 de cada 3 ciclos (padrao fixo)
    //   bp_random  -> out_ready pseudo-aleatorio (LFSR de 8 bits), para
    //                 varrer padroes irregulares que o padrao fixo nao
    //                 cobre (ex.: varias paradas seguidas, 2 avancos
    //                 seguidos por multiplas paradas, etc.)
    // ------------------------------------------------------------------
    reg       bp_enable;
    reg [1:0] bp_cnt;
    reg       bp_random;
    reg [7:0] lfsr;
    wire      out_ready = bp_random ? lfsr[0]
                        : bp_enable ? (bp_cnt != 2'd0)
                        : 1'b1;

    always @(negedge clk) begin
        if (bp_cnt == 2'd2) bp_cnt <= 2'd0;
        else                bp_cnt <= bp_cnt + 1'b1;
        // LFSR Galois de 8 bits (polinomio x^8+x^6+x^5+x^4+1) - padrao
        // pseudo-aleatorio determinístico, suficiente para um teste de
        // handshake (nao precisa de qualidade criptografica).
        lfsr <= {lfsr[0], lfsr[7:1]} ^ (lfsr[0] ? 8'hB4 : 8'h00);
    end

    wire                    in_ready;
    wire                    ready;
    wire                    busy;
    wire                    done;
    wire                    out_valid;
    wire [LOG2N-1:0]        out_index;
    wire signed [WIDTH-1:0] out_real;
    wire signed [WIDTH-1:0] out_imag;
    wire [WIDTH-1:0]        out_mag;
    wire [2:0]              stage_dbg;

    // ------------------------------------------------------------------
    // Memorias do testbench
    // ------------------------------------------------------------------
    reg signed [WIDTH-1:0] stim_re  [0:N-1];
    reg signed [WIDTH-1:0] stim_im  [0:N-1];
    reg signed [WIDTH-1:0] got_re   [0:N-1];
    reg signed [WIDTH-1:0] got_im   [0:N-1];
    reg        [WIDTH-1:0] got_mag  [0:N-1];
    reg                    got_flag [0:N-1];

    real ideal_re [0:N-1];
    real ideal_im [0:N-1];

    integer success_count = 0;
    integer fail_count    = 0;
    integer n_collected   = 0;
    integer i, k;

    // ------------------------------------------------------------------
    // Instancia do DUT
    // ------------------------------------------------------------------
    FFT_Top #(
        .WIDTH(WIDTH),
        .FRAC(15),
        .LOG2N(LOG2N),
        .SCALE_MASK(SCALE_MASK)
    ) uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .ready(ready),
        .busy(busy),
        .done(done),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_real(in_real),
        .in_imag(in_imag),
        .out_ready(out_ready),
        .out_valid(out_valid),
        .out_index(out_index),
        .out_real(out_real),
        .out_imag(out_imag),
        .out_mag(out_mag),
        .stage_dbg(stage_dbg)
    );

    // ------------------------------------------------------------------
    // Gerador de clock (50 MHz)
    // ------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // Coletor dos bins de saida
    // ------------------------------------------------------------------
    // A transferencia so se completa quando out_valid E out_ready estao
    // altos no MESMO ciclo (handshake pronto/valido). Sob contrapressao
    // (out_ready baixo) o dado permanece "congelado" em out_valid=1 ate
    // ser consumido; contar apenas out_valid faria o mesmo bin ser
    // registrado mais de uma vez.
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            got_re[out_index]   <= out_real;
            got_im[out_index]   <= out_imag;
            got_mag[out_index]  <= out_mag;
            got_flag[out_index] <= 1'b1;
            n_collected          = n_collected + 1;
        end
    end

    // ==================================================================
    // TAREFAS AUXILIARES
    // ==================================================================

    // Limpa o buffer de coleta antes de cada transformada
    task clear_results;
        integer idx;
        begin
            for (idx = 0; idx < N; idx = idx + 1) begin
                got_re[idx]   = 16'sh0000;
                got_im[idx]   = 16'sh0000;
                got_mag[idx]  = 16'h0000;
                got_flag[idx] = 1'b0;
            end
            n_collected = 0;
        end
    endtask

    // Converte um valor real para Q1.15 com arredondamento e saturacao
    function signed [WIDTH-1:0] to_q15;
        input real value;
        real scaled;
        begin
            scaled = value * 32768.0;
            if (scaled >  32767.0) scaled =  32767.0;
            if (scaled < -32768.0) scaled = -32768.0;
            to_q15 = $rtoi(scaled + (scaled >= 0.0 ? 0.5 : -0.5));
        end
    endfunction

    // Calcula a DFT ideal do estimulo corrente, normalizada por N
    task compute_ideal;
        integer kk, nn;
        real acc_r, acc_i, xr, xi, ang, c, s;
        begin
            for (kk = 0; kk < N; kk = kk + 1) begin
                acc_r = 0.0;
                acc_i = 0.0;
                for (nn = 0; nn < N; nn = nn + 1) begin
                    xr  = $itor(stim_re[nn]) / 32768.0;
                    xi  = $itor(stim_im[nn]) / 32768.0;
                    ang = -2.0 * PI * kk * nn / (1.0 * N);
                    c   = $cos(ang);
                    s   = $sin(ang);
                    acc_r = acc_r + xr * c - xi * s;
                    acc_i = acc_i + xr * s + xi * c;
                end
                ideal_re[kk] = acc_r / (1.0 * ESCALA_FFT);
                ideal_im[kk] = acc_i / (1.0 * ESCALA_FFT);
            end
        end
    endtask

    // ---- Geradores de estimulo ----
    task gen_impulse;
        integer nn;
        begin
            for (nn = 0; nn < N; nn = nn + 1) begin
                stim_re[nn] = (nn == 0) ? 16'sh7FFF : 16'sh0000;
                stim_im[nn] = 16'sh0000;
            end
        end
    endtask

    task gen_dc;
        integer nn;
        begin
            for (nn = 0; nn < N; nn = nn + 1) begin
                stim_re[nn] = to_q15(0.125);
                stim_im[nn] = 16'sh0000;
            end
        end
    endtask

    task gen_tone;
        input integer bin_k;
        input real    amp;
        input real    phase;
        integer nn;
        begin
            for (nn = 0; nn < N; nn = nn + 1) begin
                stim_re[nn] = to_q15(amp * $cos(2.0*PI*bin_k*nn/(1.0*N) + phase));
                stim_im[nn] = 16'sh0000;
            end
        end
    endtask

    // Vibracao sintetica de motor: fundamental no bin 6 + harmonicas 12 e 18
    task gen_motor;
        integer nn;
        real v;
        begin
            for (nn = 0; nn < N; nn = nn + 1) begin
                v = 0.250 * $cos(2.0*PI*6.0*nn/(1.0*N))
                  + 0.125 * $cos(2.0*PI*12.0*nn/(1.0*N) + 0.7)
                  + 0.060 * $cos(2.0*PI*18.0*nn/(1.0*N) + 1.3);
                stim_re[nn] = to_q15(v);
                stim_im[nn] = 16'sh0000;
            end
        end
    endtask

    // Envia uma amostra respeitando o handshake in_valid / in_ready
    task send_sample;
        input signed [WIDTH-1:0] r;
        input signed [WIDTH-1:0] im;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_real  = r;
            in_imag  = im;
            while (in_ready !== 1'b1) @(negedge clk);
            @(posedge clk);   // transacao concluida neste flanco
        end
    endtask

    // Executa uma transformada completa
    task run_fft;
        integer nn;
        integer timeout;
        begin
            clear_results;

            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            for (nn = 0; nn < N; nn = nn + 1)
                send_sample(stim_re[nn], stim_im[nn]);

            @(negedge clk);
            in_valid = 1'b0;

            // Aguarda a conclusao (com timeout de seguranca)
            timeout = 0;
            while (done !== 1'b1 && timeout < 20000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (timeout >= 20000) begin
                fail_count = fail_count + 1;
                $display("[FAIL] TIMEOUT: sinal 'done' nunca foi ativado!");
            end
        end
    endtask

    // Compara o resultado obtido com a DFT ideal
    task check_spectrum;
        input [8*24:1] test_name;
        integer kk, diff, exp_int, worst, mag_diff, exp_mag;
        real    acc_sq, rms;
        integer local_fail;
        begin
            worst      = 0;
            acc_sq     = 0.0;
            local_fail = 0;

            if (n_collected != N) begin
                local_fail = local_fail + 1;
                $display("[FAIL] %0s: recebidos %0d bins, esperados %0d",
                         test_name, n_collected, N);
            end

            for (kk = 0; kk < N; kk = kk + 1) begin
                if (!got_flag[kk]) begin
                    local_fail = local_fail + 1;
                    $display("[FAIL] %0s: bin %0d nunca foi entregue", test_name, kk);
                end

                // ---- parte real ----
                exp_int = $rtoi(ideal_re[kk]*32768.0 +
                                (ideal_re[kk] >= 0.0 ? 0.5 : -0.5));
                diff    = got_re[kk] - exp_int;
                if (diff < 0) diff = -diff;
                acc_sq  = acc_sq + diff*diff;
                if (diff > worst) worst = diff;
                if (diff > TOL_LSB) begin
                    local_fail = local_fail + 1;
                    $display("[FAIL] %0s: Re[%0d] esperado %0d, obtido %0d (erro %0d LSB)",
                             test_name, kk, exp_int, got_re[kk], diff);
                end

                // ---- parte imaginaria ----
                exp_int = $rtoi(ideal_im[kk]*32768.0 +
                                (ideal_im[kk] >= 0.0 ? 0.5 : -0.5));
                diff    = got_im[kk] - exp_int;
                if (diff < 0) diff = -diff;
                acc_sq  = acc_sq + diff*diff;
                if (diff > worst) worst = diff;
                if (diff > TOL_LSB) begin
                    local_fail = local_fail + 1;
                    $display("[FAIL] %0s: Im[%0d] esperado %0d, obtido %0d (erro %0d LSB)",
                             test_name, kk, exp_int, got_im[kk], diff);
                end

                // ---- magnitude (aproximacao alpha-max plus beta-min) ----
                exp_mag  = $rtoi($sqrt(ideal_re[kk]*ideal_re[kk] +
                                       ideal_im[kk]*ideal_im[kk]) * 32768.0);
                mag_diff = got_mag[kk] - exp_mag;
                if (mag_diff < 0) mag_diff = -mag_diff;
                // 6,8% de erro do metodo + margem de quantizacao
                if (mag_diff > (exp_mag*7)/100 + TOL_MAG_LSB) begin
                    local_fail = local_fail + 1;
                    $display("[FAIL] %0s: |X[%0d]| esperado %0d, obtido %0d",
                             test_name, kk, exp_mag, got_mag[kk]);
                end
            end

            rms = $sqrt(acc_sq / (2.0*N));

            if (local_fail == 0) begin
                success_count = success_count + 1;
                $display("[PASS] %0s  -> erro maximo %0d LSB, RMS %.2f LSB",
                         test_name, worst, rms);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s  -> %0d discrepancias (erro maximo %0d LSB)",
                         test_name, local_fail, worst);
            end
        end
    endtask

    // Imprime os maiores bins: e exatamente o que o detector de picos ve
    task show_peaks;
        integer kk, p1, p2, p3;
        begin
            p1 = 0; p2 = 0; p3 = 0;
            for (kk = 1; kk < N/2; kk = kk + 1) begin
                if (got_mag[kk] > got_mag[p1]) begin
                    p3 = p2; p2 = p1; p1 = kk;
                end else if (got_mag[kk] > got_mag[p2]) begin
                    p3 = p2; p2 = kk;
                end else if (got_mag[kk] > got_mag[p3]) begin
                    p3 = kk;
                end
            end
            $display("       3 maiores bins (1..31): %0d, %0d, %0d  [magnitudes %0d, %0d, %0d]",
                     p1, p2, p3, got_mag[p1], got_mag[p2], got_mag[p3]);
        end
    endtask

    // ==================================================================
    // SEQUENCIA PRINCIPAL
    // ==================================================================
    initial begin
        clk       = 0;
        rst       = 1;
        start     = 0;
        enable    = 1;
        in_valid  = 0;
        in_real   = 0;
        in_imag   = 0;
        bp_enable = 0;
        bp_cnt    = 0;
        bp_random = 0;
        lfsr      = 8'hA5;   // semente nao-nula
        clear_results;

        $display("======================================================================");
        $display("      SIMULACAO DO MODULO FFT DE 64 PONTOS - ACELERADOR SMMA          ");
        $display("      Radix-2 DIT in-place, Q1.15, saida = X[k]/%0d                      ", ESCALA_FFT);
        $display("======================================================================");

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ---- Verificacao do estado inicial ----
        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reset: modulo em IDLE, ready=1, busy=0");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Reset: ready=%b busy=%b (esperado 1 e 0)", ready, busy);
        end

        // ================================================================
        $display("\n--- TESTE 1: Impulso unitario (espectro plano) ---");
        gen_impulse;
        compute_ideal;
        run_fft;
        check_spectrum("Impulso");

        // ---- Verificacao EXPLICITA do ganho da FFT ----
        // Para x[n] = delta[n] com x[0] = 1.0, a DFT vale X[k] = 1.0 em TODOS
        // os bins, logo a saida do hardware deve ser exatamente 1/ESCALA_FFT.
        // Este e o teste que trava a regressao do ganho: se alguem voltar a
        // escalar os 6 estagios (divisao por 64), a CNN - treinada com
        // ESCALA_FFT=16 - passa a receber magnitudes 4x menores.
        begin : check_ganho
            integer esperado_ganho, obtido_ganho, dif_ganho;
            esperado_ganho = 32767 / ESCALA_FFT;      // 1.0 em Q1.15 dividido pela escala
            obtido_ganho   = got_re[7];               // bin arbitrario: o espectro e plano
            dif_ganho      = obtido_ganho - esperado_ganho;
            if (dif_ganho < 0) dif_ganho = -dif_ganho;
            if (dif_ganho <= 4) begin
                success_count = success_count + 1;
                $display("[PASS] Ganho da FFT = 1/%0d (bin plano = %0d, esperado %0d)",
                         ESCALA_FFT, obtido_ganho, esperado_ganho);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] Ganho da FFT ERRADO: bin plano = %0d, esperado %0d (1/%0d)",
                         obtido_ganho, esperado_ganho, ESCALA_FFT);
                $display("       -> a CNN foi treinada com ESCALA_FFT=16; conferir SCALE_MASK");
            end
        end

        // ================================================================
        $display("\n--- TESTE 2: Nivel DC (energia concentrada no bin 0) ---");
        gen_dc;
        compute_ideal;
        run_fft;
        check_spectrum("Nivel DC");
        // Energia esperada no bin 0: x[n] = 0.125 constante -> X[0] = 0.125*N,
        // dividido pela escala da FFT. Calculado a partir de ESCALA_FFT para
        // que a checagem continue valida se a mascara de escala mudar.
        begin : check_dc
            integer mag0_esperado;
            mag0_esperado = (32768 / 8) * N / ESCALA_FFT;   // 0.125 * 64 / escala
            if ((got_mag[0] > (mag0_esperado * 9) / 10) && (got_mag[1] < 200)) begin
                success_count = success_count + 1;
                $display("[PASS] DC concentrado no bin 0 (mag[0]=%0d ~ %0d, mag[1]=%0d)",
                         got_mag[0], mag0_esperado, got_mag[1]);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] DC mal localizado (mag[0]=%0d, esperado ~%0d, mag[1]=%0d)",
                         got_mag[0], mag0_esperado, got_mag[1]);
            end
        end

        // ================================================================
        $display("\n--- TESTE 3: Tom puro no bin 4 ---");
        gen_tone(4, 0.25, 0.0);
        compute_ideal;
        run_fft;
        check_spectrum("Tom bin 4");
        show_peaks;
        if (got_mag[4] > got_mag[3] && got_mag[4] > got_mag[5]) begin
            success_count = success_count + 1;
            $display("[PASS] Pico corretamente localizado no bin 4 (ordem natural OK)");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Pico nao esta no bin 4 -> erro de bit-reversal!");
        end

        // ================================================================
        $display("\n--- TESTE 4: Tom puro no bin 13 com fase ---");
        gen_tone(13, 0.25, 0.4);
        compute_ideal;
        run_fft;
        check_spectrum("Tom bin 13");
        show_peaks;

        // ================================================================
        $display("\n--- TESTE 5: Vibracao de motor (fundamental 6 + harmonicas 12 e 18) ---");
        gen_motor;
        compute_ideal;
        run_fft;
        check_spectrum("Vibracao motor");
        show_peaks;
        $display("       -> Estes indices alimentam o modulo MDC: MDC(6,12,18) = 6");

        // ================================================================
        $display("\n--- TESTE 6: Contrapressao na saida (out_ready intermitente) ---");
        gen_motor;
        compute_ideal;
        bp_enable = 1'b1;   // out_ready cai 1 a cada 3 ciclos
        run_fft;
        bp_enable = 1'b0;
        check_spectrum("Contrapressao");

        // Variante com padrao PSEUDO-ALEATORIO (LFSR) de out_ready, para
        // cobrir sequencias irregulares (varias paradas seguidas, etc.)
        // que o padrao fixo de periodo 3 nao exercita.
        gen_motor;
        compute_ideal;
        bp_random = 1'b1;
        run_fft;
        bp_random = 1'b0;
        check_spectrum("Contrapressao aleatoria");
        $display("       -> Nenhum bin perdido nem sobrescrito com out_ready intermitente");

        // ================================================================
        $display("\n--- TESTE 7: Reset assincrono no meio do calculo ---");
        gen_tone(8, 0.25, 0.0);
        compute_ideal;
        clear_results;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        for (i = 0; i < 20; i = i + 1)
            send_sample(stim_re[i], stim_im[i]);
        @(negedge clk);
        in_valid = 1'b0;
        repeat (10) @(negedge clk);

        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reset no meio do calculo retornou o modulo para IDLE");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Modulo nao voltou para IDLE apos reset (ready=%b busy=%b)",
                     ready, busy);
        end

        // Nova transformada completa apos o reset
        run_fft;
        check_spectrum("Pos-reset");

        // ================================================================
        $display("\n======================================================================");
        $display(" RESUMO: %0d teste(s) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO MODULO FFT PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NA SIMULACAO DO MODULO FFT.");
        $display("======================================================================");
        $finish;
    end

    // Guarda global contra travamento da simulacao
    initial begin
        #20_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
