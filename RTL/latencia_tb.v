// ============================================================================
// tb_latencia -- mede a latencia de cada bloco DENTRO do SMMA_Top, numa janela
// real (janela 3). Nao verifica funcionalidade (isso e o tb_SMMA_Top); so
// carimba o ciclo de cada evento do fluxo de dados.
//
//   FAST = 0 : fonte em tempo real, com DIV_TAXA reduzido para DIV (o pipeline
//              nunca e o gargalo, entao o "rabo" depois da ultima amostra e o
//              mesmo da placa). Latencia real = 8503*1953 + rabo.
//
// Uso (da pasta RTL/, fica fora do run_regressao.sh de proposito):
//   iverilog -g2005 -s tb_latencia -P tb_latencia.FAST=1 -o lat.vvp latencia_tb.v \
//       $(ls *.v | grep -v '^tb_' | grep -v '_tb\.v$' | grep -v ' ')
//   vvp lat.vvp
//   FAST = 1 : MODO_RAPIDO, a fonte entrega o mais rapido possivel -> mede a
//              capacidade de processamento (janela limitada so por computacao).
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

    integer nf_start = 0, nf_done = 0, nf_load = 0, nf_b31 = 0;
    integer t_fft_start [0:40], t_fft_done [0:40], t_fload [0:40], t_b31 [0:40];

    integer t_fs_out = -1, t_fs_done = -1;
    integer t_ft_last = -1, t_ft_out = -1;
    integer ft_busy = 0, ft_busy_max = 0, ft_busy_sum = 0, ft_n = 0;
    reg     ft_contando = 0;
    integer n_tree_in = 0, t_tree_in12 = -1, t_tree = -1;
    integer n_sb = 0, t_sb_first = -1, t_sb_last = -1, t_cnn = -1;
    reg     valid_q = 0;

    always @(posedge CLOCK_50) begin
        if (uut.r_arranca && t_start < 0) t_start <= cyc;

        // fonte -> FIR
        if (uut.src_valid && uut.src_ready) begin
            n_src <= n_src + 1;
            if (t_src_first < 0) t_src_first <= cyc;
            t_src_last <= cyc;
        end

        // FIR: latencia = da amostra que fecha o grupo ate a saida decimada
        dec_valid_q <= uut.dec_valid;
        if (uut.dec_valid && !dec_valid_q && t_src_last >= 0) begin
            if (cyc - t_src_last < fir_lat_min) fir_lat_min <= cyc - t_src_last;
            if (cyc - t_src_last > fir_lat_max) fir_lat_max <= cyc - t_src_last;
        end
        if (uut.dec_valid && uut.dec_ready) begin
            t_dec[n_dec] <= cyc;
            n_dec <= n_dec + 1;
        end

        // FFT e montador de quadros
        if (uut.fft_start) begin t_fft_start[nf_start] <= cyc; nf_start <= nf_start + 1; end
        if (uut.fft_done)  begin t_fft_done[nf_done]   <= cyc; nf_done  <= nf_done  + 1; end
        if (uut.fb_out_valid && uut.fb_out_ready && uut.fb_frame_fim) begin
            t_fload[nf_load] <= cyc; nf_load <= nf_load + 1;
        end
        if (uut.bin_aceito && uut.fft_out_index == 6'd31) begin
            t_b31[nf_b31] <= cyc; nf_b31 <= nf_b31 + 1;
        end

        // features espectrais
        if (uut.fs_out_valid && t_fs_out < 0) t_fs_out <= cyc;
        if (uut.fs_done && t_fs_done < 0)     t_fs_done <= cyc;

        // features temporais (LMS + autocorrelacao)
        if (uut.ft_in_valid && uut.ft_in_ready) begin
            ft_contando <= 1'b1; ft_busy <= 0;
            if (uut.ft_in_last) t_ft_last <= cyc;
        end else if (ft_contando) begin
            if (uut.ft_in_ready) begin
                ft_contando <= 1'b0;
                ft_n <= ft_n + 1; ft_busy_sum <= ft_busy_sum + ft_busy;
                if (ft_busy > ft_busy_max) ft_busy_max <= ft_busy;
            end else ft_busy <= ft_busy + 1;
        end
        if (uut.ft_out_valid && t_ft_out < 0) t_ft_out <= cyc;

        // arvore
        if (uut.tree_in_valid && uut.tree_in_ready) begin
            n_tree_in <= n_tree_in + 1;
            if (n_tree_in == 11) t_tree_in12 <= cyc;
        end
        if (uut.tree_out_valid && t_tree < 0) t_tree <= cyc;

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

    integer f, d, dmin, dmax, dsum, lmin, lmax, lsum, a;
    initial begin
        #100 KEY[0] = 1'b0;  #200 KEY[0] = 1'b1;     // reset
        #400 KEY[1] = 1'b0;  #200 KEY[1] = 1'b1;     // dispara a janela
        wait (t_valid >= 0);
        #2000;

        $display("==================================================================");
        $display(" LATENCIA MEDIDA  (FAST=%0d, DIV=%0d, janela %0d)  ciclos @ 50 MHz", FAST, DIV, JAN);
        $display("==================================================================");
        $display("amostras brutas aceitas : %0d   decimadas: %0d   quadros FFT: %0d", n_src, n_dec, nf_done);
        $display("arranque -> 1a amostra  : %0d ciclos", t_src_first - t_start);
        $display("arranque -> ultima amostra bruta : %0d ciclos (%.3f ms)", t_src_last - t_start, ms(t_src_last - t_start));
        $display("arranque -> resultado (LEDR9)    : %0d ciclos (%.3f ms)", t_valid - t_start, ms(t_valid - t_start));
        $display("RABO: ultima amostra bruta -> resultado : %0d ciclos (%.2f us)", t_valid - t_src_last, us(t_valid - t_src_last));
        $display("");
        $display("FIR: amostra que fecha o grupo -> saida decimada : %0d .. %0d ciclos", fir_lat_min, fir_lat_max);

        dmin = 1<<30; dmax = 0; dsum = 0; lmin = 1<<30; lmax = 0; lsum = 0;
        for (f = 0; f < 32; f = f + 1) begin
            d = t_fft_done[f] - t_fft_start[f];
            if (d < dmin) dmin = d; if (d > dmax) dmax = d; dsum = dsum + d;
            a = 63 + 32*f;                                // ultima amostra do quadro f
            d = t_b31[f] - t_dec[a];
            if (d < lmin) lmin = d; if (d > lmax) lmax = d; lsum = lsum + d;
        end
        $display("FFT_Top start -> done (carga 64 + calculo + descarga 64): %0d .. %0d ciclos (media %0d) = %.2f us",
                 dmin, dmax, dsum/32, us(dsum/32));
        $display("  quadro carregado -> done                  : %0d ciclos (quadro 0)", t_fft_done[0] - t_fload[0]);
        $display("QUADRO DE 64 AMOSTRAS: ultima amostra decimada -> bin 31 entregue as features: %0d .. %0d ciclos (media %0d) = %.2f us",
                 lmin, lmax, lsum/32, us(lsum/32));
        $display("  intervalo entre quadros (salto de 32 amostras) : %0d ciclos", t_dec[63+32] - t_dec[63]);
        $display("");
        $display("Feature_Temporal por amostra (LMS+autocorr), ocupado : media %0d, max %0d ciclos  (%0d amostras)",
                 ft_busy_sum / (ft_n > 0 ? ft_n : 1), ft_busy_max, ft_n);
        $display("  intervalo entre amostras decimadas          : %0d ciclos", t_dec[101] - t_dec[100]);
        $display("Feature_Temporal: ultima amostra -> 1a feature  : %0d ciclos", t_ft_out - t_ft_last);
        $display("Feature_Spectral: ultimo bin -> 1a feature      : %0d ciclos", t_fs_out - t_b31[31]);
        $display("Arvore: 12a feature -> classe                   : %0d ciclos", t_tree - t_tree_in12);
        $display("Caminho ARVORE: ultimo bin (quadro 31) -> classe : %0d ciclos (%.2f us)", t_tree - t_b31[31], us(t_tree - t_b31[31]));
        $display("");
        $display("Spectrogram_Buffer: ultimo bin -> 1o pixel p/ CNN: %0d ciclos", t_sb_first - t_b31[31]);
        $display("Leitura dos 1024 pixels pela CNN (1o -> ultimo) : %0d ciclos", t_sb_last - t_sb_first);
        $display("CNN: ultimo pixel -> classe                     : %0d ciclos", t_cnn - t_sb_last);
        $display("CNN: 1o pixel -> classe                         : %0d ciclos (%.2f us)", t_cnn - t_sb_first, us(t_cnn - t_sb_first));
        $display("Caminho CNN: ultimo bin (quadro 31) -> classe    : %0d ciclos (%.2f us)", t_cnn - t_b31[31], us(t_cnn - t_b31[31]));
        $display("Painel: ultima classe -> LEDR9                  : %0d ciclos", t_valid - (t_cnn > t_tree ? t_cnn : t_tree));
        $display("==================================================================");
        $finish;
    end

    initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
