// ============================================================================
// Module: SMMA_Top
// Description: Top level do SMMA -- Smart Machine Monitoring Accelerator.
//              Acelerador em FPGA para manutencao preditiva de motores
//              industriais (PBL de Circuitos Digitais IV).
//
//              Alvo: DE0-CV, Cyclone V 5CEBA4F23C7N, 50 MHz.
//
// ============================================================================
// CADEIA DE DADOS
// ============================================================================
//
//   Sample_Source            dataset em ROM, 25,6 kHz, Q1.15 (+-32 g)
//        |
//   FIR_Decimator            63 taps @1,4 kHz, decimacao /8 -> 3,2 kHz
//        |
//        +---------------------------------+
//        |                                 |
//   Frame_Builder                    Feature_Temporal
//   (64 pts, salto 32)               (1056 amostras)
//        |                                 |
//    FFT_Top (64 pts, /16)                 | r_lms, rho1..rho3
//        | |X[k]|, bins 0..31              |
//        +-----------------+               |
//        |                 |               |
//  Feature_Spectral   FFT_Log2_Compress    |
//   (32x32 -> 8)           |               |
//        |          Spectrogram_Buffer     |
//        |           (32x32, transposto)   |
//        |                 |               |
//        |             CNN_Top             |
//        |                 |               |
//        +-----> ML_Tree_Classifier <------+
//                    12 features
//
//   Os DOIS classificadores rodam sobre a MESMA janela, o que e o ponto da
//   demonstracao: a arvore e a referencia numerica e a CNN o caminho de
//   aprendizado profundo, e o painel mostra as duas lado a lado contra o
//   rotulo verdadeiro.
//
//   Medido na particao de teste, a arvore ganha em todas as cargas
//   (0,9725 / 0,9354 / 0,8832 contra 0,893 / 0,862 / 0,738 da CNN). A media
//   da CNN (83,2%) esconde que ela degrada muito com a carga; as features da
//   arvore sao em sua maioria RAZOES pela energia total, e por isso nao
//   dependem do nivel absoluto do sinal.
//
// ============================================================================
// SINCRONIZACAO: por que os fan-outs sao "join" e nao simples derivacoes
// ============================================================================
//   Ha dois pontos onde um fluxo alimenta dois consumidores:
//
//     (a) o sinal decimado -> Frame_Builder + Feature_Temporal
//     (b) |X[k]| dos bins 0..31 -> Feature_Spectral + log2/espectrograma
//
//   Em ambos o dado so avanca quando os DOIS consumidores aceitam
//   (ready = AND, valid replicado). Entregar a um e nao ao outro dessincroniza
//   os dois classificadores de forma silenciosa -- eles passariam a decidir
//   sobre janelas diferentes.
//
//   O acoplamento nao gera impasse: nenhum dos consumidores espera pelo outro
//   para liberar in_ready, e todos terminam em tempo finito. E nao e caro: a
//   3,2 kHz chega uma amostra decimada a cada 15.625 ciclos de 50 MHz, tres
//   ordens de grandeza acima do custo de qualquer bloco por amostra.
//
// ============================================================================
// PAINEL (DE0-CV)
// ============================================================================
//   KEY[0]   reset (ativo em baixo na placa, invertido aqui)
//   KEY[1]   dispara uma janela
//   SW[3:0]  escolhe a janela do dataset (0..11)
//   SW[9]    1 = mostra os scores da CNN nos LEDs em vez do estado
//
//   HEX0     classe da ARVORE        HEX1  classe da CNN
//   HEX2     classe VERDADEIRA       HEX3  'E' se houve erro de percurso
//   HEX5:4   indice da janela (decimal)
//
//   LEDR[3:0] classe da arvore em one-hot    LEDR[4] arvore == verdadeira
//   LEDR[5]   CNN == verdadeira              LEDR[6] as duas concordam
//   LEDR[8]   ocupado                        LEDR[9] resultado valido
// ============================================================================

`timescale 1ns / 1ps

module SMMA_Top #(
    parameter WIDTH       = 16,
    parameter FRAC        = 15,
    parameter NFFT        = 64,
    parameter HOP         = 32,
    parameter N_BINS      = 32,
    parameter N_QUADROS   = 32,
    parameter N_FEATURES  = 12,
    parameter N_NOS       = 141,     // nos em vetores/arvore.hex
    parameter MODO_RAPIDO = 0        // 1 = ignora a taxa de 25,6 kHz (simulacao)
)(
    input  wire        CLOCK_50,
    input  wire [1:0]  KEY,          // ativo em BAIXO na placa
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);

    wire clk = CLOCK_50;

    // ------------------------------------------------------------------------
    // Reset e disparo
    //
    // Os botoes da DE0-CV sao ativos em baixo; o projeto todo usa reset
    // sincrono ativo em ALTO, entao a inversao acontece aqui, uma unica vez.
    // Os dois botoes passam por dois registradores: KEY e assincrono ao
    // CLOCK_50 e amostra-lo direto numa FSM e convite a metaestabilidade.
    // ------------------------------------------------------------------------
    reg [1:0] key_s0, key_s1, key_s2;
    always @(posedge clk) begin
        key_s0 <= ~KEY;          // ativo em alto a partir daqui
        key_s1 <= key_s0;
        key_s2 <= key_s1;
    end
    wire rst       = key_s1[0];
    wire disparo   = key_s1[1] && !key_s2[1];   // borda de subida, 1 ciclo

    // ------------------------------------------------------------------------
    // Fonte de amostras (dataset em ROM, 25,6 kHz)
    // ------------------------------------------------------------------------
    wire                     src_start;
    wire                     src_busy, src_done, src_valid;
    wire signed [WIDTH-1:0]  src_sample;
    wire                     src_ready;
    wire [1:0]               classe_verdadeira, classe_modelo;

    Sample_Source #(
        .WIDTH(WIDTH), .MODO_RAPIDO(MODO_RAPIDO)
    ) u_src (
        .clk(clk), .rst(rst), .start(src_start), .janela(SW[3:0]),
        .busy(src_busy), .done(src_done),
        .out_ready(src_ready), .out_valid(src_valid), .out_sample(src_sample),
        .classe_verdadeira(classe_verdadeira),
        .classe_esperada(classe_modelo)
    );

    // ------------------------------------------------------------------------
    // FIR anti-alias + decimacao /8  ->  3,2 kHz
    // ------------------------------------------------------------------------
    wire                     dec_valid;
    wire signed [WIDTH-1:0]  dec_sample;
    wire                     dec_ready;
    wire                     fir_overflow;

    FIR_Decimator #(
        .WIDTH(WIDTH), .FRAC(FRAC)
    ) u_fir (
        .clk(clk), .rst(rst), .limpa(r_arranca),
        .in_valid(src_valid), .in_ready(src_ready), .in_sample(src_sample),
        .out_ready(dec_ready), .out_valid(dec_valid), .out_sample(dec_sample),
        .overflow(fir_overflow)
    );

    // ------------------------------------------------------------------------
    // Fan-out (a): sinal decimado -> montador de quadros + features temporais
    // ------------------------------------------------------------------------
    wire fb_in_ready, ft_in_ready;
    wire dec_ambos = fb_in_ready && ft_in_ready;

    assign dec_ready = dec_ambos;
    wire fb_in_valid = dec_valid && dec_ambos;
    wire ft_in_valid = dec_valid && dec_ambos;

    // ------------------------------------------------------------------------
    // Montador de quadros (64 pontos, salto 32)
    // ------------------------------------------------------------------------
    wire                     fb_start, fb_ready, fb_busy, fb_done;
    wire                     fb_out_valid, fb_out_ready;
    wire signed [WIDTH-1:0]  fb_out_sample;
    wire                     fb_frame_ini, fb_frame_fim;

    Frame_Builder #(
        .WIDTH(WIDTH), .NFFT(NFFT), .HOP(HOP), .N_QUADROS(N_QUADROS)
    ) u_fb (
        .clk(clk), .rst(rst), .start(fb_start),
        .ready(fb_ready), .busy(fb_busy), .done(fb_done),
        .in_valid(fb_in_valid), .in_ready(fb_in_ready), .in_sample(dec_sample),
        .out_ready(fb_out_ready), .out_valid(fb_out_valid),
        .out_sample(fb_out_sample),
        .out_frame_ini(fb_frame_ini), .out_frame_fim(fb_frame_fim)
    );

    // ------------------------------------------------------------------------
    // FFT de 64 pontos
    //
    // A FFT_Top so levanta in_ready em S_LOAD, isto e, DEPOIS do pulso de
    // start. O quadro fica portanto retido ate a transformada estar armada --
    // 'fft_armada' existe so para isso. Sem ela a primeira amostra de cada
    // quadro seria oferecida um ciclo antes da hora e se perderia.
    // ------------------------------------------------------------------------
    wire                     fft_ready, fft_busy, fft_done;
    wire                     fft_in_ready;
    wire                     fft_out_valid;
    wire [5:0]               fft_out_index;
    wire [WIDTH-1:0]         fft_out_mag;
    wire                     fft_out_ready;

    reg fft_armada;
    wire fft_start = fb_out_valid && fb_frame_ini && fft_ready && !fft_armada;

    always @(posedge clk) begin
        if (rst)                fft_armada <= 1'b0;
        else if (fft_start)     fft_armada <= 1'b1;
        else if (fb_out_valid && fb_out_ready && fb_frame_fim)
                                fft_armada <= 1'b0;
    end

    assign fb_out_ready = fft_armada && fft_in_ready;

    FFT_Top #(
        .WIDTH(WIDTH), .FRAC(FRAC), .LOG2N(6), .SCALE_MASK(6'b001111)
    ) u_fft (
        .clk(clk), .rst(rst), .start(fft_start), .enable(1'b1),
        .ready(fft_ready), .busy(fft_busy), .done(fft_done),
        .in_valid(fb_out_valid && fft_armada), .in_ready(fft_in_ready),
        .in_real(fb_out_sample), .in_imag({WIDTH{1'b0}}),
        .out_ready(fft_out_ready), .out_valid(fft_out_valid),
        .out_index(fft_out_index),
        .out_real(), .out_imag(), .out_mag(fft_out_mag), .stage_dbg()
    );

    // ------------------------------------------------------------------------
    // Fan-out (b): |X[k]| dos bins uteis -> features espectrais + espectrograma
    //
    // Para um sinal real o espectro e simetrico, entao so os bins 0..31
    // carregam informacao. Os bins 32..63 sao ACEITOS e descartados: deixar de
    // aceita-los travaria a FFT no despejo.
    // ------------------------------------------------------------------------
    wire bin_util = (fft_out_index < N_BINS);
    wire fs_in_ready, sb_in_ready;
    wire cons_ambos = fs_in_ready && sb_in_ready;

    assign fft_out_ready = bin_util ? cons_ambos : 1'b1;
    wire bin_aceito = fft_out_valid && bin_util && cons_ambos;

    // ------------------------------------------------------------------------
    // Features espectrais (8)
    // ------------------------------------------------------------------------
    wire                     fs_start, fs_ready, fs_busy, fs_done;
    wire                     fs_out_valid, fs_out_ready;
    wire signed [WIDTH-1:0]  fs_out_feature;

    Feature_Spectral #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) u_fs (
        .clk(clk), .rst(rst), .start(fs_start),
        .ready(fs_ready), .busy(fs_busy), .done(fs_done),
        .in_valid(bin_aceito), .in_ready(fs_in_ready), .in_mag(fft_out_mag),
        .out_ready(fs_out_ready), .out_valid(fs_out_valid),
        .out_feature(fs_out_feature)
    );

    // ------------------------------------------------------------------------
    // Compressao log2 + buffer do espectrograma
    //
    // O 'en' do compressor serve de skid de um nivel: com en = sb_in_ready, o
    // pixel registrado so e substituido quando o buffer puder receber, e
    // out_valid permanece alto enquanto nao puder.
    // ------------------------------------------------------------------------
    wire             log2_valid;
    wire [WIDTH-1:0] log2_pixel;

    FFT_Log2_Compress #(.WIDTH(WIDTH)) u_log2 (
        .clk(clk), .rst(rst), .en(sb_in_ready),
        .in_valid(bin_aceito), .in_mag(fft_out_mag),
        .out_valid(log2_valid), .out_pixel(log2_pixel)
    );

    wire             sb_start, sb_ready, sb_busy, sb_done;
    wire             sb_out_valid, sb_out_ready;
    wire [WIDTH-1:0] sb_out_pixel;

    Spectrogram_Buffer #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) u_sb (
        .clk(clk), .rst(rst), .start(sb_start),
        .ready(sb_ready), .busy(sb_busy), .done(sb_done),
        .in_valid(log2_valid), .in_ready(sb_in_ready), .in_pixel(log2_pixel),
        .out_ready(sb_out_ready), .out_valid(sb_out_valid),
        .out_pixel(sb_out_pixel)
    );

    // ------------------------------------------------------------------------
    // Features temporais (4)
    // ------------------------------------------------------------------------
    wire                     ft_start, ft_ready, ft_busy, ft_done;
    wire                     ft_out_valid, ft_out_ready;
    wire signed [WIDTH-1:0]  ft_out_feature;

    // A ultima das 1056 amostras decimadas da janela fecha o calculo. O
    // contador vive aqui porque o FIR nao tem como saber onde a janela acaba.
    reg [11:0] n_dec;
    localparam L_JANELA = (N_QUADROS-1)*HOP + NFFT;      // 1056
    wire ft_in_last = (n_dec == L_JANELA - 1);

    Feature_Temporal #(
        .WIDTH(WIDTH), .FRAC(FRAC), .N_TAPS(8), .MU_SHIFT(3), .N_LAGS(3)
    ) u_ft (
        .clk(clk), .rst(rst), .start(ft_start),
        .ready(ft_ready), .busy(ft_busy), .done(ft_done),
        .in_valid(ft_in_valid), .in_ready(ft_in_ready),
        .in_sample(dec_sample), .in_last(ft_in_last),
        .out_ready(ft_out_ready), .out_valid(ft_out_valid),
        .out_feature(ft_out_feature)
    );

    // ------------------------------------------------------------------------
    // Multiplexador das 12 features -> arvore
    //
    // A ordem e a do treinamento: as 8 espectrais, depois r_lms e rho1..rho3.
    // Trocar a ordem nao da erro em lugar nenhum -- so uma classificacao
    // errada, silenciosa. Por isso o indice vem de um contador unico.
    // ------------------------------------------------------------------------
    wire                     tree_start, tree_ready, tree_busy, tree_done;
    wire                     tree_in_ready;
    wire                     tree_out_valid, tree_out_error;
    wire [1:0]               tree_class;

    reg [3:0] feat_idx;
    wire      fase_esp = (feat_idx < 4'd8);

    assign fs_out_ready = tree_in_ready &&  fase_esp;
    assign ft_out_ready = tree_in_ready && !fase_esp;

    wire                     tree_in_valid   = fase_esp ? fs_out_valid : ft_out_valid;
    wire signed [WIDTH-1:0]  tree_in_feature = fase_esp ? fs_out_feature : ft_out_feature;

    always @(posedge clk) begin
        if (rst || tree_start)                       feat_idx <= 4'd0;
        else if (tree_in_valid && tree_in_ready)     feat_idx <= feat_idx + 1'b1;
    end

    ML_Tree_Classifier #(
        .WIDTH(WIDTH), .N_FEATURES(N_FEATURES), .N_NOS(N_NOS)
    ) u_tree (
        .clk(clk), .rst(rst), .start(tree_start), .enable(1'b1),
        .ready(tree_ready), .busy(tree_busy), .done(tree_done),
        .in_valid(tree_in_valid), .in_ready(tree_in_ready),
        .in_feature(tree_in_feature),
        .out_ready(1'b1), .out_valid(tree_out_valid),
        .out_class(tree_class), .out_error(tree_out_error)
    );

    // ------------------------------------------------------------------------
    // CNN sobre o mesmo espectrograma
    // ------------------------------------------------------------------------
    wire        cnn_start, cnn_ready, cnn_busy, cnn_done, cnn_valid;
    wire        cnn_in_ready;
    wire [1:0]  cnn_class;
    wire [4*WIDTH-1:0] cnn_scores;

    assign sb_out_ready = cnn_in_ready;

    CNN_Top #(
        .WIDTH(WIDTH), .FRAC(FRAC), .IMG_W(N_QUADROS), .IMG_H(N_BINS)
    ) u_cnn (
        .clk(clk), .rst(rst), .start(cnn_start), .enable(1'b1),
        .in_valid(sb_out_valid), .in_ready(cnn_in_ready),
        .in_pixel($signed(sb_out_pixel)),
        .busy(cnn_busy), .ready(cnn_ready), .done(cnn_done),
        .valid_out(cnn_valid),
        .out_class(cnn_class), .out_scores(cnn_scores), .out_features()
    );

    // ========================================================================
    // UNIDADE DE CONTROLE GLOBAL
    // ========================================================================
    //   Uma janela completa, do dataset ao veredito, em cinco estados. O
    //   caminho da arvore e o da CNN correm EM PARALELO depois da aquisicao:
    //   os dois consomem produtos da mesma janela e nenhum depende do outro.
    // ========================================================================
    localparam [2:0] E_PARADO  = 3'd0,
                     E_ARRANCA = 3'd1,   // pulso de start em todos os blocos
                     E_ADQUIRE = 3'd2,   // 1056 amostras -> 32 quadros
                     E_DECIDE  = 3'd3,   // 12 features -> arvore; CNN em paralelo
                     E_PRONTO  = 3'd4;
    reg [2:0] est;

    reg        r_arranca;
    reg [1:0]  r_tree_class, r_cnn_class, r_verdadeira;
    reg        r_tree_err, r_valido;
    reg        tree_ok, cnn_ok;

    // Pulsos de start: um unico registrador alimenta todos os blocos da
    // aquisicao, para que eles comecem no MESMO ciclo. Comecar a janela do
    // Feature_Temporal um ciclo depois da do Frame_Builder desalinharia as
    // duas metades do vetor de features.
    assign src_start  = r_arranca;
    assign fb_start   = r_arranca;
    assign fs_start   = r_arranca;
    assign ft_start   = r_arranca;
    assign sb_start   = r_arranca;
    assign tree_start = (est == E_ARRANCA);
    // A CNN tambem arranca aqui, e nao quando o espectrograma fecha. O 'done'
    // do Spectrogram_Buffer sobe apenas depois de a imagem ter sido DRENADA --
    // usa-lo para disparar a CNN seria tarde demais, pois os pixels ja teriam
    // passado. Arrancando junto, a CNN simplesmente espera no handshake de
    // carga os ~500 mil ciclos ate o buffer encher, o que lhe e indiferente.
    assign cnn_start  = r_arranca;

    always @(posedge clk) begin
        if (rst) begin
            est          <= E_PARADO;
            r_arranca    <= 1'b0;
            r_valido     <= 1'b0;
            r_tree_class <= 2'd0;
            r_cnn_class  <= 2'd0;
            r_verdadeira <= 2'd0;
            r_tree_err   <= 1'b0;
            tree_ok      <= 1'b0;
            cnn_ok       <= 1'b0;
            n_dec        <= 12'd0;
        end else begin
            r_arranca <= 1'b0;

            // conta as amostras decimadas da janela para marcar in_last
            if (est == E_ARRANCA)                      n_dec <= 12'd0;
            else if (dec_valid && dec_ready)           n_dec <= n_dec + 1'b1;

            case (est)
                E_PARADO: begin
                    if (disparo && fb_ready && ft_ready && fs_ready
                                && sb_ready && tree_ready && cnn_ready) begin
                        r_arranca <= 1'b1;
                        r_valido  <= 1'b0;
                        tree_ok   <= 1'b0;
                        cnn_ok    <= 1'b0;
                        est       <= E_ARRANCA;
                    end
                end

                // A arvore comeca a receber features ja aqui: ela fica retida
                // no handshake ate o Feature_Spectral ter a primeira pronta.
                E_ARRANCA: est <= E_ADQUIRE;

                E_ADQUIRE: if (fb_done) est <= E_DECIDE;

                E_DECIDE: begin
                    if (tree_out_valid && !tree_ok) begin
                        r_tree_class <= tree_class;
                        r_tree_err   <= tree_out_error;
                        tree_ok      <= 1'b1;
                    end
                    if (cnn_valid && !cnn_ok) begin
                        r_cnn_class <= cnn_class;
                        cnn_ok      <= 1'b1;
                    end
                    if ((tree_ok || tree_out_valid) && (cnn_ok || cnn_valid)) begin
                        r_verdadeira <= classe_verdadeira;
                        r_valido     <= 1'b1;
                        est          <= E_PRONTO;
                    end
                end

                // Volta sozinho: uma tecla por medida. O painel nao apaga,
                // porque r_valido e os registradores do veredito so sao
                // limpos no proximo arranque.
                E_PRONTO: est <= E_PARADO;

                default: est <= E_PARADO;
            endcase
        end
    end

    wire ocupado = (est != E_PARADO) && (est != E_PRONTO);

    // ------------------------------------------------------------------------
    // Painel
    // ------------------------------------------------------------------------
    function [6:0] seg7;                // ativo em BAIXO na DE0-CV
        input [3:0] v;
        begin
            case (v)
                4'h0: seg7 = 7'b1000000;  4'h1: seg7 = 7'b1111001;
                4'h2: seg7 = 7'b0100100;  4'h3: seg7 = 7'b0110000;
                4'h4: seg7 = 7'b0011001;  4'h5: seg7 = 7'b0010010;
                4'h6: seg7 = 7'b0000010;  4'h7: seg7 = 7'b1111000;
                4'h8: seg7 = 7'b0000000;  4'h9: seg7 = 7'b0010000;
                4'hE: seg7 = 7'b0000110;  // 'E' de erro
                default: seg7 = 7'b1111111;   // apagado
            endcase
        end
    endfunction

    wire [3:0] jan_dez = SW[3:0] / 4'd10;
    wire [3:0] jan_uni = SW[3:0] % 4'd10;

    assign HEX0 = r_valido ? seg7({2'b00, r_tree_class}) : 7'b1111111;
    assign HEX1 = r_valido ? seg7({2'b00, r_cnn_class})  : 7'b1111111;
    assign HEX2 = r_valido ? seg7({2'b00, r_verdadeira}) : 7'b1111111;
    assign HEX3 = (r_valido && (r_tree_err || fir_overflow)) ? seg7(4'hE)
                                                            : 7'b1111111;
    assign HEX4 = seg7(jan_uni);
    assign HEX5 = seg7(jan_dez);

    // SW[9] troca o significado dos LEDs baixos: estado do veredito ou os
    // scores da CNN, uteis para ver o quanto ela hesitou.
    wire [3:0] arv_onehot = r_valido ? (4'b0001 << r_tree_class) : 4'b0000;

    assign LEDR[3:0] = SW[9] ? cnn_scores[3:0] : arv_onehot;
    assign LEDR[4]   = r_valido && (r_tree_class == r_verdadeira);
    assign LEDR[5]   = r_valido && (r_cnn_class  == r_verdadeira);
    assign LEDR[6]   = r_valido && (r_tree_class == r_cnn_class);
    assign LEDR[7]   = (classe_modelo == r_verdadeira) && r_valido;
    assign LEDR[8]   = ocupado;
    assign LEDR[9]   = r_valido;

endmodule
