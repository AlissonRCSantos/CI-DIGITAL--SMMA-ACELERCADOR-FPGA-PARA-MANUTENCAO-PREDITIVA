// ============================================================================
// tb_latencia -- testbench: latencia de cada bloco numa janela
// ============================================================================

`timescale 1ns / 1ps
module tb_latencia;
    parameter FAST = 0;
    parameter DIV  = 100;
    parameter JAN  = 3;

    reg CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;          // 50 MHz

    reg  [1:0] KEY = 2'b11;
    reg  [9:0] SW  = JAN;
    wire [9:0] LEDR;
    wire [6:0] H0, H1, H2, H3, H4, H5;

    SMMA_Top #(.MODO_RAPIDO(FAST), .N_NOS(141)) uut (
        .CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(H0), .HEX1(H1), .HEX2(H2), .HEX3(H3), .HEX4(H4), .HEX5(H5));
    defparam uut.u_src.DIV_TAXA = DIV;

    integer cyc = 0;
    always @(posedge CLOCK_50) cyc <= cyc + 1;

    // ---------------- carimbos ----------------
    integer t_start = -1, t_valid = -1;
    integer n_src = 0, t_src_first = -1, t_src_last = -1;
    integer n_dec = 0;
    integer t_dec [0:1100];
    integer fir_lat_min = 1<<30, fir_lat_max = 0;
    reg     dec_valid_q = 0;

    integer nf_start = 0, nf_done = 0, nf_b31 = 0;
    integer t_fft_start [0:40], t_fft_done [0:40], t_b31 [0:40];

    integer t_sa_first = -1, t_sa_last = -1;
    integer t_fs_out = -1, t_pk_out = -1, t_mdc = -1, t_f0 = -1;
    integer lms_busy = 0, lms_busy_max = 0, lms_busy_sum = 0, lms_n = 0;
    reg     lms_contando = 0;
    integer t_lr_out = -1, t_ac_out = -1, t_inv_start = -1, t_inv_done = -1, t_yw_out = -1;
    integer t_col_out = -1, t_tree = -1;
    integer n_sb = 0, t_sb_first = -1, t_sb_last = -1, t_cnn = -1;
    reg     valid_q = 0, inv_busy_q = 0;

    always @(posedge CLOCK_50) begin
        if (uut.arranca && t_start < 0) t_start <= cyc;

        // fonte -> FIR
        if (uut.src_valid && uut.src_ready) begin
            n_src <= n_src + 1;
            if (t_src_first < 0) t_src_first <= cyc;
            t_src_last <= cyc;
        end
        dec_valid_q <= uut.dec_valid;
        if (uut.dec_valid && !dec_valid_q && t_src_last >= 0) begin
            if (cyc - t_src_last < fir_lat_min) fir_lat_min <= cyc - t_src_last;
            if (cyc - t_src_last > fir_lat_max) fir_lat_max <= cyc - t_src_last;
        end
        if (uut.dec_valid && uut.dec_ready) begin
            t_dec[n_dec] <= cyc;
            n_dec <= n_dec + 1;
        end

        // FFT
        if (uut.fft_start) begin t_fft_start[nf_start] <= cyc; nf_start <= nf_start + 1; end
        if (uut.fft_done)  begin t_fft_done[nf_done]   <= cyc; nf_done  <= nf_done  + 1; end
        if (uut.sa_in_valid && uut.fft_out_index == 6'd31) begin
            t_b31[nf_b31] <= cyc; nf_b31 <= nf_b31 + 1;
        end

        // espectro medio -> features espectrais + MDC
        if (uut.sa_out_valid && uut.sa_out_ready) begin
            if (t_sa_first < 0) t_sa_first <= cyc;
            t_sa_last <= cyc;
        end
        if (uut.fs_out_valid && t_fs_out < 0)  t_fs_out <= cyc;
        if (uut.pk_out_valid && t_pk_out < 0)  t_pk_out <= cyc;
        if (uut.mdc_out_valid && t_mdc < 0)    t_mdc    <= cyc;
        if (uut.f0_out_valid && t_f0 < 0)      t_f0     <= cyc;

        // LMS em serie: da amostra aceita pelo estagio ate ela sair no barramento
        if (uut.dec_valid && uut.dec_ready) begin
            lms_contando <= 1'b1; lms_busy <= 0;
        end else if (lms_contando) begin
            if (uut.ls_out_valid) begin
                lms_contando <= 1'b0;
                lms_n <= lms_n + 1; lms_busy_sum <= lms_busy_sum + lms_busy;
                if (lms_busy > lms_busy_max) lms_busy_max <= lms_busy;
            end else lms_busy <= lms_busy + 1;
        end
        if (uut.ls_feat_valid && t_lr_out < 0) t_lr_out <= cyc;

        // estimacao matricial
        if (uut.ac_r_valid && t_ac_out < 0)  t_ac_out <= cyc;
        if (uut.inv_start && t_inv_start < 0) t_inv_start <= cyc;
        inv_busy_q <= uut.inv_busy;
        if (inv_busy_q && !uut.inv_busy && t_inv_done < 0 && t_inv_start >= 0) t_inv_done <= cyc;
        if (uut.yw_out_valid && t_yw_out < 0) t_yw_out <= cyc;

        // vetor de features -> arvore
        if (uut.col_out_valid && t_col_out < 0) t_col_out <= cyc;
        if (uut.tree_out_valid && t_tree < 0)   t_tree <= cyc;

        // espectrograma -> CNN
        if (uut.sb_out_valid && uut.sb_out_ready) begin
            n_sb <= n_sb + 1;
            if (t_sb_first < 0) t_sb_first <= cyc;
            t_sb_last <= cyc;
        end
        if (uut.cnn_valid && t_cnn < 0) t_cnn <= cyc;

        valid_q <= LEDR[9];
        if (LEDR[9] && !valid_q && t_valid < 0) t_valid <= cyc;
    end

    function real us; input integer c; begin us = c * 0.02; end endfunction
    function real ms; input integer c; begin ms = c * 0.00002; end endfunction

    integer f, d, dmin, dmax, dsum, ult_dec;
    initial begin
        #100 KEY[0] = 1'b0;  #200 KEY[0] = 1'b1;     // reset
        #400 KEY[1] = 1'b0;  #200 KEY[1] = 1'b1;     // dispara a janela
        wait (t_valid >= 0);
        #2000;
        ult_dec = t_dec[1055];

        $display("==================================================================");
        $display(" LATENCIA MEDIDA  (FAST=%0d, DIV=%0d, janela %0d)  ciclos @ 50 MHz", FAST, DIV, JAN);
        $display("==================================================================");
        $display("amostras brutas: %0d   decimadas: %0d   quadros FFT: %0d", n_src, n_dec, nf_start);
        $display("arranque -> ultima amostra bruta : %0d ciclos (%.3f ms)", t_src_last - t_start, ms(t_src_last - t_start));
        $display("arranque -> resultado (LEDR9)    : %0d ciclos (%.3f ms)", t_valid - t_start, ms(t_valid - t_start));
        $display("RABO: ultima amostra bruta -> resultado : %0d ciclos (%.2f us)", t_valid - t_src_last, us(t_valid - t_src_last));
        $display("");
        $display("FIR_Decimator: amostra que fecha o grupo -> saida : %0d .. %0d ciclos", fir_lat_min, fir_lat_max);
        dmin = 1<<30; dmax = 0; dsum = 0;
        for (f = 0; f < nf_done; f = f + 1) begin
            d = t_fft_done[f] - t_fft_start[f];
            if (d < dmin) dmin = d; if (d > dmax) dmax = d; dsum = dsum + d;
        end
        $display("FFT_Top start -> done (carga + calculo + descarga) : %0d .. %0d ciclos (media %0d)", dmin, dmax, dsum/(nf_done > 0 ? nf_done : 1));
        $display("  intervalo entre amostras decimadas               : %0d ciclos", t_dec[101] - t_dec[100]);
        $display("");
        $display("Spectrum_Accumulator: ultimo bin -> espectro medio : %0d ciclos (+%0d de saida)", t_sa_first - t_b31[31], t_sa_last - t_sa_first);
        $display("Feature_Spectral: fim do espectro -> 1a feature    : %0d ciclos", t_fs_out - t_sa_last);
        $display("MDC: fim do espectro -> picos / k0 / f0            : %0d / %0d / %0d ciclos", t_pk_out - t_sa_last, t_mdc - t_sa_last, t_f0 - t_sa_last);
        $display("LMS em serie: entrada -> barramento, por amostra  : media %0d, max %0d ciclos (%0d amostras)",
                 lms_busy_sum / (lms_n > 0 ? lms_n : 1), lms_busy_max, lms_n);
        $display("LMS: ultima amostra -> r_lms                       : %0d ciclos", t_lr_out - ult_dec);
        $display("autocorrelacao: ultima amostra -> rho              : %0d ciclos", t_ac_out - ult_dec);
        $display("Gauss-Jordan 3x3 (start -> fim)                    : %0d ciclos", t_inv_done - t_inv_start);
        $display("Yule-Walker: rho -> a1..a3                         : %0d ciclos", t_yw_out - t_ac_out);
        $display("Vetor de 16 features completo -> classe (arvore)   : %0d ciclos", t_tree - t_col_out);
        $display("Caminho ARVORE: ultima amostra decimada -> classe  : %0d ciclos (%.2f us)", t_tree - ult_dec, us(t_tree - ult_dec));
        $display("");
        $display("Leitura dos 1024 pixels pela CNN (1o -> ultimo)    : %0d ciclos", t_sb_last - t_sb_first);
        $display("CNN: ultimo pixel -> classe                        : %0d ciclos", t_cnn - t_sb_last);
        $display("Caminho CNN: ultimo bin (quadro 31) -> classe      : %0d ciclos (%.2f us)", t_cnn - t_b31[31], us(t_cnn - t_b31[31]));
        $display("==================================================================");
        if (n_dec == 1056 && nf_start == 32 && nf_b31 == 32 && t_tree > 0 && t_cnn > 0)
            $display("[PASS] janela completa medida -- MEDICAO CONCLUIDA COM SUCESSO");
        else
            $display("[FAIL] janela incompleta: dec=%0d quadros=%0d", n_dec, nf_start);
        $finish;
    end

    initial begin #2_000_000_000; $display("[FAIL] TIMEOUT"); $finish; end
endmodule
