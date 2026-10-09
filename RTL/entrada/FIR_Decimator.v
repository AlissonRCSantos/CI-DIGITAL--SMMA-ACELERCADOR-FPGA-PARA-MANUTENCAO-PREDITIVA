// ============================================================================
// Module: FIR_Decimator
// Description: Filtro FIR anti-aliasing de 63 taps seguido de decimacao por 8.
//              E a INTERFACE DE ENTRADA DOS SENSORES do SMMA (enunciado 4).
//
// ----------------------------------------------------------------------------
// POR QUE ESTE BLOCO EXISTE (medido no dataset)
// ----------------------------------------------------------------------------
//   O acelerometro amostra a 25,6 kHz. Uma FFT de 64 pontos aplicada DIRETO
//   nessa taxa da 25600/64 = 400 Hz por bin -- e TODAS as frequencias de
//   diagnostico da maquina caem dentro do bin 0:
//
//       eixo 1x   50,17 Hz -> bin 0,13      BPFO  179,43 Hz -> bin 0,45
//       2x       100,34 Hz -> bin 0,25      BSF   234,19 Hz -> bin 0,59
//       3x       150,51 Hz -> bin 0,38      BPFI  272,07 Hz -> bin 0,68
//
//   Ou seja, sem decimacao e impossivel distinguir desbalanceamento (1x) de
//   desalinhamento (2x) ou de falha de rolamento: todas moram no mesmo bin.
//
//   Decimando por 8 (25,6 kHz -> 3,2 kHz) a resolucao vira 50 Hz/bin e as
//   mesmas frequencias se separam em bins distintos (1,00 / 2,01 / 3,01 /
//   3,59 / 4,68 / 5,44), que e o que torna a classificacao possivel.
//
//   O FIR passa-baixa (corte 1,4 kHz) e OBRIGATORIO antes de decimar: sem
//   ele, todo o conteudo acima de 1,6 kHz -- que no sinal bruto carrega a
//   maior parte da energia -- rebateria por aliasing para dentro da banda
//   util e corromperia justamente os bins de diagnostico.
//
// ----------------------------------------------------------------------------
// ARQUITETURA: 1 multiplicador reutilizado 63 vezes
// ----------------------------------------------------------------------------
//   Uma saida e produzida a cada 8 amostras de entrada, ou seja a cada
//   8/25600 s = 312,5 us = 15.625 ciclos de 50 MHz. O MAC precisa de apenas
//   63 ciclos, entao UM unico multiplicador basta -- ocupa 0,4% do tempo
//   disponivel. Gastar mais DSPs aqui seria desperdicio: eles fazem falta na
//   CNN (8) e na FFT (4).
//
//   Os coeficientes sao simetricos (fase linear), o que permitiria somar os
//   pares antes de multiplicar e cair para 32 multiplicacoes. Nao foi feito
//   porque exigiria leitura dupla do buffer para ganhar tempo que ja sobra.
//
// Formato: entrada e saida em Q1.15; acumulador de 40 bits (63 produtos de
// 32 bits exigem 32 + ceil(log2 63) = 38 bits; 40 da margem).
// Arredondamento meio-para-cima, igual ao resto do projeto, e saturacao.
// ============================================================================

`timescale 1ns / 1ps

module FIR_Decimator #(
    parameter WIDTH    = 16,                  // Q1.15
    parameter FRAC     = 15,
    parameter N_TAPS   = 63,
    parameter DECIM    = 8,
    parameter ACC_W    = 40,
    parameter ARQ_COEF = "vetores/fir_coef.hex"
)(
    input  wire                     clk,        // Clock do sistema (50 MHz)
    input  wire                     rst,        // Reset sincrono ativo em alto
    input  wire                     limpa,      // Pulso: zera a linha e a fase

    // ---- Entrada: amostras do acelerometro a 25,6 kHz ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [WIDTH-1:0]  in_sample,  // Q1.15 (fundo de escala +-32 g)

    // ---- Saida: sinal decimado a 3,2 kHz ----
    input  wire                     out_ready,
    output reg                      out_valid,
    output reg  signed [WIDTH-1:0]  out_sample  // Q1.15

    , output wire                   overflow    // 1 = uma saida saturou
);

    localparam signed [ACC_W-1:0] SAT_MAX =  (1 << (WIDTH-1)) - 1;   // +32767
    localparam signed [ACC_W-1:0] SAT_MIN = -(1 << (WIDTH-1));       // -32768
    localparam CNT_W = 7;                                            // ate 63
    // A convolucao 'valid' produz a primeira saida quando a linha de atraso
    // enche, isto e, na amostra de indice N_TAPS-1 (62). Como a decimacao
    // toma uma a cada DECIM amostras a partir dai, a fase de disparo e
    // (N_TAPS-1) % DECIM = 6 -- e NAO DECIM-1. Derivado dos parametros para
    // continuar correto se N_TAPS ou DECIM mudarem.
    localparam [3:0] FASE_DISPARO = (N_TAPS - 1) % DECIM;

    // ------------------------------------------------------------------------
    // ROM de coeficientes e linha de atraso
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] coef [0:N_TAPS-1];
    initial $readmemh(ARQ_COEF, coef);

    reg signed [WIDTH-1:0] linha [0:N_TAPS-1];   // linha[0] = amostra mais nova

    // ------------------------------------------------------------------------
    // Controle
    // ------------------------------------------------------------------------
    reg [CNT_W-1:0]        tap;          // indice do tap no MAC
    reg [3:0]              fase;         // conta amostras para a decimacao
    reg [CNT_W-1:0]        preench;      // amostras ja recebidas (satura)
    reg signed [ACC_W-1:0] acc;
    reg                    calculando;
    reg                    sat_flag;

    assign overflow = sat_flag;
    // Aceita nova amostra enquanto nao estiver no meio de um MAC e a saida
    // anterior ja tiver sido consumida -- e o que impede sobrescrita.
    assign in_ready = !calculando && !(out_valid && !out_ready);

    wire cheia      = (preench >= N_TAPS - 1);
    wire aceita     = in_valid && in_ready;
    // A convolucao 'valid' do modelo Python produz saida quando a linha esta
    // cheia; a partir dai, uma a cada DECIM amostras.
    wire dispara    = aceita && cheia && (fase == FASE_DISPARO);

    wire signed [ACC_W-1:0] prod = linha[tap] * coef[tap];

    // ATENCAO: no ULTIMO tap a saida precisa sair de (acc + prod), e nao de
    // 'acc'. O produto do tap 62 e somado no MESMO flanco em que a saida e
    // publicada, entao usar 'acc' deixaria o ultimo tap de fora. Por ser um
    // tap de borda (coeficiente pequeno) o erro era de poucos LSB -- e
    // algumas saidas ate coincidiam por arredondamento, o que mascararia o
    // defeito em uma verificacao por tolerancia em vez de bit-exata.
    wire signed [ACC_W-1:0] acc_next  = acc + prod;
    wire signed [ACC_W-1:0] acc_round = acc_next + (1 << (FRAC - 1));
    wire signed [ACC_W-1:0] acc_shift = acc_round >>> FRAC;

    integer i;

    // 'limpa' faz o mesmo que o reset, e e OBRIGATORIO entre janelas.
    //
    // Duas razoes. A primeira e de equivalencia: o modelo Python convolve cada
    // janela de forma independente (mode="valid"), entao comecar com a linha de
    // atraso carregada com a cauda da janela anterior produz amostras
    // decimadas diferentes das treinadas.
    //
    // A segunda e pior, porque trava. Uma janela tem 8503 amostras cruas, e
    // 8503 mod 8 = 7: sem limpar, cada janela desloca a FASE da decimacao em 7
    // e o numero de saidas deixa de ser 1056. Com 1055 o LMS/autocorrelacao
    // nunca completa a janela, nunca termina, e o sistema
    // inteiro para esperando as 12 features. Foi exatamente o que aconteceu na
    // terceira janela do teste ponta a ponta.
    always @(posedge clk) begin
        if (rst || limpa) begin
            tap        <= {CNT_W{1'b0}};
            fase       <= 4'd0;
            preench    <= {CNT_W{1'b0}};
            acc        <= {ACC_W{1'b0}};
            calculando <= 1'b0;
            out_valid  <= 1'b0;
            out_sample <= {WIDTH{1'b0}};
            sat_flag   <= 1'b0;
            for (i = 0; i < N_TAPS; i = i + 1)
                linha[i] <= {WIDTH{1'b0}};
        end else begin
            // saida consumida
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (!calculando) begin
                if (aceita) begin
                    // desloca a linha de atraso e insere a nova amostra
                    for (i = N_TAPS - 1; i > 0; i = i - 1)
                        linha[i] <= linha[i-1];
                    linha[0] <= in_sample;

                    if (!cheia)
                        preench <= preench + 1'b1;

                    fase <= (fase == DECIM - 1) ? 4'd0 : (fase + 1'b1);

                    if (dispara) begin
                        // inicia o MAC: tap 0 ja usa a amostra recem-inserida,
                        // por isso o produto do tap 0 e feito aqui.
                        acc        <= $signed(in_sample) * coef[0];
                        tap        <= 7'd1;
                        calculando <= 1'b1;
                    end
                end
            end else begin
                // um tap por ciclo
                acc <= acc + prod;
                if (tap == N_TAPS - 1) begin
                    calculando <= 1'b0;
                    // arredonda, satura e publica
                    if (acc_shift > SAT_MAX) begin
                        out_sample <= SAT_MAX[WIDTH-1:0];
                        sat_flag   <= 1'b1;
                    end else if (acc_shift < SAT_MIN) begin
                        out_sample <= SAT_MIN[WIDTH-1:0];
                        sat_flag   <= 1'b1;
                    end else begin
                        out_sample <= acc_shift[WIDTH-1:0];
                    end
                    out_valid <= 1'b1;
                end else begin
                    tap <= tap + 1'b1;
                end
            end
        end
    end

endmodule
