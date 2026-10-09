// ============================================================================
// Module: FFT_Top
// Description: Modulo FFT de 64 pontos do acelerador SMMA - topo de integracao.
//
//   Transforma uma janela de 64 amostras de vibracao do dominio do tempo para
//   o dominio da frequencia, entregando parte real, parte imaginaria e uma
//   estimativa de magnitude por bin espectral. A saida alimenta o detector de
//   picos, que por sua vez alimenta o modulo MDC (estimativa da frequencia
//   fundamental) e o classificador de Machine Learning.
//
// ----------------------------------------------------------------------------
// 1. ALGORITMO
// ----------------------------------------------------------------------------
//   FFT Cooley-Tukey radix-2 por DECIMACAO NO TEMPO (DIT), iterativa e
//   in-place, com entrada em ordem de bits invertidos e saida em ordem natural
//   de frequencia.
//
//   Pseudocodigo:
//       bit_reverse_copy(x -> X)
//       para s = 1 .. 6:                       // log2(64) estagios
//           para b = 0 .. 31:                  // 32 butterflies por estagio
//               (p, q, k) = addr_gen(s, b)
//               t    = W_64^k * X[q]
//               X[p] = (X[p] + t) / 2
//               X[q] = (X[p] - t) / 2
//
//   Por que radix-2 DIT iterativo:
//     - e o que exige MENOS multiplicadores por butterfly (4 reais);
//     - permite computacao in-place, cabendo em 1 unica memoria;
//     - o padrao de enderecos e gerado por deslocamentos e mascaras,
//       dispensando qualquer multiplicador no caminho de controle;
//     - radix-4 reduziria os estagios de 6 para 3, mas exigiria memoria de 4
//       portas e butterflies muito maiores - desnecessario, dado que o
//       orcamento de tempo ja e cumprido com folga de ~800x.
//
// ----------------------------------------------------------------------------
// 2. RECURSOS (resposta aos itens exigidos na secao 3.2 do enunciado)
// ----------------------------------------------------------------------------
//   Multiplicadores : 4  (uma unica unidade butterfly reutilizada 192 vezes)
//   Somadores       : 6  no butterfly + logica de enderecos
//   Memorias        : 1  RAM true dual-port 64 x 32 bits (1 M10K)
//                     1  ROM de 32 x 32 bits para os fatores de rotacao
//   Registradores   : ~250 (pipeline do butterfly, linha de atraso de
//                     enderecos de escrita, contadores do FSM)
//   Butterflies     : 6 estagios x 32 = 192 execucoes na mesma unidade fisica
//
//   Alternativas de paralelismo avaliadas:
//     (a) 1 butterfly reutilizado  -> 4 DSPs, ~627 ciclos  [ADOTADA]
//     (b) 2 butterflies paralelos  -> 8 DSPs, ~300 ciclos (exigiria 4 portas
//         de memoria ou divisao do vetor em 2 bancos)
//     (c) totalmente paralela      -> 192 butterflies, 768 DSPs: inviavel no
//         dispositivo alvo e desnecessaria para o requisito de 10 ms.
//   A opcao (a) foi escolhida porque o gargalo do sistema NAO e a FFT, e os
//   DSPs economizados ficam disponiveis para a CNN e para o filtro LMS.
//
// ----------------------------------------------------------------------------
// 3. FORMATO NUMERICO
// ----------------------------------------------------------------------------
//   Amostras de entrada   : Q1.15 com sinal (16 bits) - faixa [-1, +1)
//   Fatores de rotacao    : Q1.15 com sinal (16 bits)
//   Produtos internos     : Q2.15 (17 bits) apos a combinacao complexa
//   Somas do butterfly    : Q3.15 (18 bits) antes do escalonamento
//   Saida real/imaginaria : Q1.15 com sinal (16 bits)
//   Magnitude             : Q1.15 SEM sinal (16 bits), faixa [0, 2)
//
//   Escalonamento CONFIGURAVEL por estagio (parametro SCALE_MASK, detalhado
//   logo abaixo). O padrao escala 4 dos 6 estagios -> a saida e X[k]/16, que
//   e a escala com que a CNN foi treinada. O fator e constante para todos os
//   bins, portanto nao afeta o detector de picos nem o MDC, que comparam bins
//   entre si; mas afeta a CNN, cujos pesos foram ajustados nesta escala.
//
// ----------------------------------------------------------------------------
// 4. PROTOCOLO DE COMUNICACAO
// ----------------------------------------------------------------------------
//   Entrada : stream de 64 amostras com handshake in_valid / in_ready.
//   Saida   : stream de 64 bins com handshake out_valid / out_ready, cada um
//             acompanhado do seu indice (out_index), pronto para o detector
//             de picos. out_ready baixo congela o pipeline de saida e a
//             memoria mantem o dado, impedindo perda ou sobrescrita.
//   Estado  : ready (aceita nova janela), busy (processando), done (pulso).
// ============================================================================

`timescale 1ns / 1ps

module FFT_Top #(
    parameter WIDTH = 16,   // Largura da palavra de dados (Q1.15)
    parameter FRAC  = 15,   // Bits fracionarios
    parameter LOG2N = 6,    // N = 2^LOG2N = 64 pontos

    // ------------------------------------------------------------------------
    // ESCALONAMENTO POR ESTAGIO (bit i = 1 -> estagio i+1 divide por 2)
    // ------------------------------------------------------------------------
    //   Este parametro define o GANHO TOTAL da FFT: 2^-(numero de bits em 1).
    //
    //   6'b111111 -> divide por 64 (X[k]/N): impossivel estourar, mas perde
    //                ~1 bit de SNR por estagio.
    //   6'b001111 -> divide por 16  [PADRAO]: escala apenas os estagios 1..4.
    //
    //   O padrao e 1/16 porque ESSA e a especificacao do caminho
    //   FFT -> espectrograma com que a CNN foi TREINADA
    //   (python/smma/espectrograma.py: "ESCALA_FFT = 16", e o comentario
    //   "escala 1/2 em 4 dos 6 estagios radix-2; margem medida no dataset:
    //   pico maximo ~50% do fundo de escala").
    //
    //   Se a FFT dividisse por 64, as magnitudes entregues ao detector de
    //   picos e a CNN sairiam 4x menores do que as usadas no treino - o que,
    //   depois da compressao log2 do espectrograma, desloca TODOS os pixels
    //   em 2 niveis de expoente (~4096 de 32767) e degrada a classificacao.
    //
    //   Os dois estagios sem escala sao os DOIS ULTIMOS de proposito: assim
    //   os valores intermediarios permanecem no menor nivel possivel pelo
    //   maior tempo possivel, e o crescimento de 4x so ocorre no fim, onde a
    //   margem de 50% medida no dataset garante que nao ha saturacao.
    parameter [5:0] SCALE_MASK = 6'b001111
)(
    input  wire                     clk,        // Clock do sistema (50 MHz)
    input  wire                     rst,        // Reset sincrono ativo em alto

    // ---- Controle ----
    input  wire                     start,      // Pulso de 1 ciclo: inicia a transformada
    input  wire                     enable,     // Habilitacao global
    output wire                     ready,      // Pronto para aceitar nova janela
    output wire                     busy,       // Transformada em andamento
    output wire                     done,       // Pulso de 1 ciclo ao concluir

    // ---- Entrada de amostras (dominio do tempo) ----
    input  wire                     in_valid,   // Amostra valida
    output wire                     in_ready,   // Modulo pronto para receber
    input  wire signed [WIDTH-1:0]  in_real,    // Amostra x[n] (Q1.15)
    input  wire signed [WIDTH-1:0]  in_imag,    // Parte imaginaria (0 para sinal real)

    // ---- Saida do espectro (dominio da frequencia) ----
    input  wire                     out_ready,  // Consumidor pronto (detector de picos)
    output wire                     out_valid,  // Bin valido
    output wire [LOG2N-1:0]         out_index,  // Indice k do bin (0..63)
    output wire signed [WIDTH-1:0]  out_real,   // Re{X[k]}/16 (Q1.15, ver SCALE_MASK)
    output wire signed [WIDTH-1:0]  out_imag,   // Im{X[k]}/16 (Q1.15, ver SCALE_MASK)
    output wire [WIDTH-1:0]         out_mag,    // |X[k]|/16 aproximado (Q1.15 sem sinal)

    // ---- Observabilidade ----
    output wire [2:0]               stage_dbg   // Estagio corrente (1..6)
);

    localparam N      = (1 << LOG2N);   // 64 pontos
    localparam DATA_W = 2 * WIDTH;      // 32 bits: {imag, real}

    // ========================================================================
    // SINAIS DE INTERLIGACAO
    // ========================================================================
    // Controle da memoria
    wire [LOG2N-1:0]  mem_a_addr, mem_b_addr;
    wire              mem_a_we,   mem_b_we;
    wire              mem_sel_load;
    wire [DATA_W-1:0] mem_a_dout, mem_b_dout;

    // Fatores de rotacao
    wire [LOG2N-2:0]        tw_addr;
    wire                    tw_rd_en;
    wire signed [WIDTH-1:0] w_real, w_imag;

    // Butterfly
    wire                    bf_in_valid;
    wire                    bf_scale_en;
    wire                    bf_out_valid;
    wire signed [WIDTH-1:0] bf_p_real, bf_p_imag;
    wire signed [WIDTH-1:0] bf_q_real, bf_q_imag;

    // Descarga
    wire             unload_rd;
    wire [LOG2N-1:0] unload_index;
    wire             out_pipe_adv;

    // ========================================================================
    // 1. UNIDADE DE CONTROLE
    // ========================================================================
    FFT_Control_FSM #(
        .LOG2N(LOG2N),
        .BF_PIPE(7),         // 1 ciclo de RAM + 6 ciclos do butterfly
        .SCALE_MASK(SCALE_MASK)
    ) u_control (
        .clk(clk),
        .rst(rst),
        .start(start),
        .enable(enable),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_ready(out_ready),
        .busy(busy),
        .done(done),
        .ready(ready),
        .mem_a_addr(mem_a_addr),
        .mem_a_we(mem_a_we),
        .mem_b_addr(mem_b_addr),
        .mem_b_we(mem_b_we),
        .mem_sel_load(mem_sel_load),
        .tw_addr(tw_addr),
        .tw_rd_en(tw_rd_en),
        .bf_in_valid(bf_in_valid),
        .bf_scale_en(bf_scale_en),
        .unload_rd(unload_rd),
        .unload_index(unload_index),
        .out_pipe_adv(out_pipe_adv),
        .stage_out(stage_dbg)
    );

    // ========================================================================
    // 2. MEMORIA DE DADOS (in-place, true dual-port)
    // ========================================================================
    // Porta A recebe ou a amostra de entrada (carga) ou o resultado P do
    // butterfly (calculo). Porta B recebe sempre o resultado Q.
    wire [DATA_W-1:0] mem_a_din = mem_sel_load ? {in_imag,   in_real}
                                               : {bf_p_imag, bf_p_real};
    wire [DATA_W-1:0] mem_b_din = {bf_q_imag, bf_q_real};

    FFT_Memory #(
        .DATA_W(DATA_W),
        .ADDR_W(LOG2N),
        .DEPTH(N)
    ) u_memory (
        .clk(clk),
        .rst(rst),
        .a_addr(mem_a_addr),
        .a_we(mem_a_we),
        .a_din(mem_a_din),
        .a_dout(mem_a_dout),
        .b_addr(mem_b_addr),
        .b_we(mem_b_we),
        .b_din(mem_b_din),
        .b_dout(mem_b_dout)
    );

    // ========================================================================
    // 3. ROM DOS FATORES DE ROTACAO
    // ========================================================================
    FFT_Twiddle_ROM #(
        .WIDTH(WIDTH),
        .ADDR_W(LOG2N-1)
    ) u_twiddle (
        .clk(clk),
        .rst(rst),
        .rd_en(tw_rd_en),
        .rd_addr(tw_addr),
        .w_real(w_real),
        .w_imag(w_imag)
    );

    // ========================================================================
    // 4. UNIDADE BUTTERFLY (reutilizada 192 vezes)
    // ========================================================================
    // Operando A vem da porta A, operando B vem da porta B, ambos disponiveis
    // 1 ciclo apos a emissao da leitura - exatamente quando bf_in_valid sobe.
    FFT_Butterfly #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) u_butterfly (
        .clk(clk),
        .rst(rst),
        .in_valid(bf_in_valid),
        .scale_en(bf_scale_en),
        .a_real(mem_a_dout[WIDTH-1:0]),
        .a_imag(mem_a_dout[DATA_W-1:WIDTH]),
        .b_real(mem_b_dout[WIDTH-1:0]),
        .b_imag(mem_b_dout[DATA_W-1:WIDTH]),
        .w_real(w_real),
        .w_imag(w_imag),
        .out_valid(bf_out_valid),
        .p_real(bf_p_real),
        .p_imag(bf_p_imag),
        .q_real(bf_q_real),
        .q_imag(bf_q_imag)
    );

    // ========================================================================
    // 5. PIPELINE DE SAIDA (descarga do espectro)
    // ========================================================================
    // ATENCAO - BUG HISTORICO E CORRECAO:
    //   'mem_a_dout' e a propria saida registrada da memoria: ela se atualiza
    //   em TODO ciclo de clock, SEM clock-enable (a FFT_Memory nao tem porta
    //   de enable). Ja 'unload_index'/'unload_rd' sao sinais COMBINACIONAIS,
    //   derivados diretamente de 'unload_cnt' no MESMO ciclo em que o endereco
    //   e apresentado - ou seja, tem 0 ciclos de atraso em relacao ao proprio
    //   endereco, enquanto 'mem_a_dout' ja tem 1 ciclo de atraso (a leitura
    //   registrada da memoria) em relacao a esse MESMO endereco.
    //
    //   A versao original desta logica carregava 'idx_d1' diretamente de
    //   'unload_index' (0 ciclos de atraso) dentro do MESMO bloco que carrega
    //   're_d1' a partir de 'mem_a_dout' (que JA tem 1 ciclo de atraso) - os
    //   dois caminhos tinham profundidades de pipeline DIFERENTES (3 estagios
    //   com clock-enable para o indice, contra 1 estagio sem enable + 2 com
    //   enable para o dado). Em velocidade plena (out_ready sempre alto) os
    //   dois totais coincidem numericamente e tudo funciona - mas sob
    //   contrapressao IRREGULAR o estagio SEM enable da memoria continua
    //   avancando (ou melhor, continua re-apresentando o mesmo endereco)
    //   independente das paradas, enquanto os estagios COM enable ficam
    //   congelados durante elas; a equivalencia dos totais se rompe e o MESMO
    //   dado pode aparecer colado em dois indices consecutivos na saida
    //   (confirmado em simulacao: o bin 6 vazava tambem para o indice 5).
    //
    //   A CORRECAO cria um espelho de 'unload_index' com a MESMA latencia de
    //   1 ciclo SEM clock-enable que 'mem_a_dout' ja tem (addr_mirror). A
    //   partir dai, o caminho do indice e o caminho do dado passam a ter
    //   EXATAMENTE a mesma estrutura (1 estagio sem enable + 2 estagios com
    //   enable via out_pipe_adv), o que os mantem sincronizados sob
    //   qualquer padrao de out_ready.
    //
    //   SEGUNDO BUG (relacionado) E CORRECAO: a validade usada como
    //   'in_valid' do estimador de magnitude originalmente espelhava
    //   'unload_rd', que e um PULSO de apenas 1 ciclo (so fica alto no
    //   ciclo exato em que um novo endereco e apresentado). Um pulso de 1
    //   ciclo, espelhado sem gating, tambem fica visivel por apenas 1 ciclo
    //   absoluto - e, sob um padrao de out_ready suficientemente irregular,
    //   esse unico ciclo podia nao coincidir com nenhum tick de
    //   out_pipe_adv, fazendo o estagio interno de validade do
    //   FFT_Magnitude NUNCA capturar aquele pulso: o bin correspondente
    //   saia com magnitude/validade zeradas (confirmado em simulacao com um
    //   padrao pseudo-aleatorio de out_ready). 'unload_index' nao sofre
    //   disso porque e um NIVEL estavel (fica no mesmo valor por 2+ ciclos
    //   inteiros), nunca um pulso efemero.
    //
    //   A CORRECAO troca o espelho de validade para acompanhar 'busy' (um
    //   NIVEL que fica alto por centenas de ciclos, ao longo de toda a
    //   transformada) em vez de 'unload_rd'. Isso elimina o risco de perda
    //   por transiencia E automaticamente "pre-prepara" o estagio de
    //   validade do FFT_Magnitude (que ja esta em 1 havia muito tempo antes
    //   da descarga comecar), fazendo-o alcancar o regime permanente
    //   exatamente nos mesmos 2 ciclos de enable que idx_d1/idx_d2
    //   precisam - sem atraso extra de "priming".
    reg             busy_mirror;         // espelha busy,         SEM enable
    reg [LOG2N-1:0] addr_mirror;         // espelha unload_index, SEM enable

    always @(posedge clk) begin
        if (rst) begin
            busy_mirror <= 1'b0;
            addr_mirror <= {LOG2N{1'b0}};
        end else begin
            busy_mirror <= busy;
            addr_mirror <= unload_index;
        end
    end

    reg [LOG2N-1:0]        idx_d1, idx_d2;
    reg signed [WIDTH-1:0] re_d1, re_d2;
    reg signed [WIDTH-1:0] im_d1, im_d2;

    always @(posedge clk) begin
        if (rst) begin
            idx_d1 <= {LOG2N{1'b0}};
            idx_d2 <= {LOG2N{1'b0}};
            re_d1  <= {WIDTH{1'b0}};
            re_d2  <= {WIDTH{1'b0}};
            im_d1  <= {WIDTH{1'b0}};
            im_d2  <= {WIDTH{1'b0}};
        end else if (out_pipe_adv) begin
            idx_d1 <= addr_mirror;
            idx_d2 <= idx_d1;
            re_d1  <= mem_a_dout[WIDTH-1:0];
            re_d2  <= re_d1;
            im_d1  <= mem_a_dout[DATA_W-1:WIDTH];
            im_d2  <= im_d1;
        end
    end

    // ========================================================================
    // 6. ESTIMADOR DE MAGNITUDE (alimenta o detector de picos)
    // ========================================================================
    // 'in_valid'/'in_real'/'in_imag' usam os sinais na MESMA profundidade de
    // 'mem_a_dout' (0 estagios com enable ainda aplicados) - os 2 estagios
    // internos do FFT_Magnitude, gated pelo mesmo 'en', desempenham o papel
    // de re_d1/re_d2, mantendo magnitude e real/imaginario exatamente
    // alinhados em qualquer ciclo.
    wire mag_valid;

    FFT_Magnitude #(
        .WIDTH(WIDTH)
    ) u_magnitude (
        .clk(clk),
        .rst(rst),
        .en(out_pipe_adv),
        .in_valid(busy_mirror),
        .in_real(mem_a_dout[WIDTH-1:0]),
        .in_imag(mem_a_dout[DATA_W-1:WIDTH]),
        .out_valid(mag_valid),
        .out_mag(out_mag)
    );

    // ------------------------------------------------------------------------
    // SUPRESSAO DE REPETICOES: compara o indice contra o ULTIMO INDICE
    // REALMENTE ENTREGUE, em vez de tentar contar ciclos.
    //
    //   Duas tentativas anteriores de resolver isto por contagem de ciclos
    //   fracassaram:
    //     1) Um registrador extra "out_valid_q" adicionava 1 estagio de
    //        atraso ao sinal de validade, desalinhando-o de idx_d2/re_d2.
    //     2) Contar "ticks de out_pipe_adv associados a um endereco novo"
    //        (exatamente N=64) tambem falha: o endereco de um bin e emitido
    //        2 ticks ANTES do dado desse bin chegar a idx_d2/re_d2 (1 ciclo
    //        de memoria sem enable + 1 estagio com enable). Logo os ultimos
    //        2 ticks que entregam dado novo acontecem DEPOIS que a contagem
    //        de "enderecos emitidos" ja chegou a 64 (durante o esvaziamento
    //        em S_FLUSH, que nao tem endereco novo algum) - o proprio bin 63
    //        era bloqueado por sua propria contagem.
    //
    //   A solucao robusta nao tenta prever QUANDO um dado novo chega: ela
    //   apenas lembra QUAL foi o ultimo indice entregue e bloqueia qualquer
    //   repeticao exata dele, seja por que motivo for (held por falta de
    //   out_ready, ou revalidacao espuria durante o esvaziamento de
    //   S_FLUSH).
    //
    //   IMPORTANTE: 'last_idx'/'last_idx_valid' NAO sao zerados no inicio
    //   de uma transformada nova. Entre o fim de uma transformada e o
    //   inicio da proxima (S_DONE/S_IDLE/S_LOAD/S_COMPUTE/S_DRAIN), nao ha
    //   nenhum 'out_pipe_adv', entao 'idx_d2'/'mag_valid' permanecem
    //   PARADOS mostrando o ultimo bin (63) da transformada anterior - e e
    //   exatamente essa mesma memoria (last_idx==63) que continua
    //   suprimindo essa repeticao durante toda a espera. Zerar
    //   'last_idx_valid' nesse meio tempo reabriria a porta para esse
    //   valor obsoleto escapar como uma entrega fantasma. A unica vez em
    //   que 'idx_d2' muda de novo e quando a NOVA transformada emite seu
    //   proprio bin 0, que e sempre DIFERENTE de 63 - logo nunca e
    //   confundido com o valor antigo, sem necessidade de reset explicito.
    reg [LOG2N-1:0] last_idx;
    reg             last_idx_valid;

    wire out_valid_raw = mag_valid
                        && !(last_idx_valid && (idx_d2 == last_idx));

    always @(posedge clk) begin
        if (rst) begin
            last_idx       <= {LOG2N{1'b0}};
            last_idx_valid <= 1'b0;
        end else if (out_valid_raw && out_ready) begin
            last_idx       <= idx_d2;
            last_idx_valid <= 1'b1;
        end
    end

    assign out_valid = out_valid_raw;
    assign out_index = idx_d2;
    assign out_real  = re_d2;
    assign out_imag  = im_d2;

endmodule
