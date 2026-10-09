// ============================================================================
// Module: ML_Tree_Classifier
// Description: Classificador de Machine Learning do SMMA (enunciado 3.5).
//              Arvore de decisao quantizada em Q1.15, percorrida 1 no por
//              ciclo a partir de uma ROM de nos.
//
// ----------------------------------------------------------------------------
// POR QUE ARVORE DE DECISAO (justificativa pedida na secao 3.5)
// ----------------------------------------------------------------------------
//   O passo 07 do fluxo Python mede as duas alternativas sugeridas pelo
//   enunciado nas MESMAS janelas de teste:
//
//     modelo       acuracia   balanceada   mult/decisao   memoria
//     arvore         0.9331      0.9117            0        612 B
//     SVM-RBF        0.9647      0.9620       22.104     44.208 B
//
//   A SVM acerta ~3 pontos a mais, mas exige 22 mil multiplicacoes e 44 kB de
//   vetores de suporte POR DECISAO, alem de uma unidade exp(). O enunciado
//   lista "quantidade limitada de multiplicadores DSP" entre as restricoes
//   (secao 5), e no mesmo FPGA a CNN ja consome 8 DSPs e a FFT outros 4.
//
//   A arvore nao usa NENHUM multiplicador: a inferencia e uma sequencia de
//   COMPARACOES. Custa 612 bytes de ROM e 9 ciclos (180 ns @ 50 MHz) -- cerca
//   de 55 mil vezes menos que o orcamento de 10 ms por janela.
//
// ----------------------------------------------------------------------------
// ENTRADAS: 12 caracteristicas em Q1.15 (especificacao em smma/features.py)
// ----------------------------------------------------------------------------
//   Da FFT (8)              : r_1x, r_2x, r_3x (harmonicos 1x/2x/3x da
//                             rotacao), 3 energias de banda, log2 da energia
//                             total e centroide espectral
//   Do filtro LMS (1)       : r_lms, energia residual do preditor linear
//   Da estimacao matricial  : a1, a2, a3 -- coeficientes AR(3) obtidos de
//   (3)                       autocorrelacao_yw + gauss_jordan_inv
//
//   Isso atende a exigencia do enunciado de que o classificador receba
//   caracteristicas "extraidas da FFT, do filtro LMS e da etapa de estimacao
//   matricial".
//
// ----------------------------------------------------------------------------
// FORMATO DA ROM (32 bits por no) -- gerada por 08_exportar_classificador.py
// ----------------------------------------------------------------------------
//   bit  31     : 1 = folha
//   folha   -> bits [1:0]   classe (0..3)
//   interno -> bits [30:27] indice da feature (0..11)
//              bits [26:11] limiar em Q1.15 (16 bits, complemento de dois)
//              bits [10:3]  indice do filho DIREITO
//
//   O filho ESQUERDO nao e armazenado: a arvore do sklearn e construida em
//   profundidade, entao ele e sempre o no seguinte (indice + 1). O script de
//   exportacao VERIFICA essa propriedade antes de gravar, em vez de supor.
//
//   Regra de decisao (identica a do sklearn e a do modelo Python):
//       feature <= limiar  ->  filho esquerdo (indice + 1)
//       feature >  limiar  ->  filho direito
//   A comparacao e COM SINAL: as features sao Q1.15 com sinal.
//
// Latencia: 12 ciclos para carregar as features + ate PROF_MAX para percorrer.
// Recursos: 0 DSP, 0 somadores de dado; 1 comparador de 16 bits, 1 ROM.
// ============================================================================

`timescale 1ns / 1ps

module ML_Tree_Classifier #(
    parameter WIDTH      = 16,                 // Q1.15
    parameter N_FEATURES = 12,                 // entradas do classificador
    parameter N_NOS      = 153,                // nos da ROM
    parameter IDX_W      = 8,                  // bits do indice de no
    parameter PROF_MAX   = 9,                  // profundidade da arvore
    parameter ARQ_ROM    = "vetores/arvore.hex"
)(
    input  wire                   clk,         // Clock do sistema (50 MHz)
    input  wire                   rst,         // Reset sincrono ativo em alto

    // ---- Controle ----
    input  wire                   start,       // Pulso: inicia uma classificacao
    input  wire                   enable,      // Habilitacao global
    output wire                   ready,       // Pronto para nova classificacao
    output reg                    busy,        // Classificando
    output reg                    done,        // Pulso de conclusao

    // ---- Entrada das features (stream de N_FEATURES palavras) ----
    input  wire                   in_valid,    // Feature valida
    output wire                   in_ready,    // Pronto para receber
    input  wire signed [WIDTH-1:0] in_feature, // Caracteristica em Q1.15

    // ---- Saida da classificacao ----
    input  wire                   out_ready,   // Consumidor pronto
    output wire                   out_valid,   // Classe valida
    output wire [1:0]             out_class,   // 0=normal 1=desbal 2=desalin 3=rolam
    output wire                   out_error    // 1 = percurso nao terminou em folha
);

    // ------------------------------------------------------------------------
    // ROM dos nos (inferida como M10K pelo Quartus; leitura registrada)
    // ------------------------------------------------------------------------
    reg [31:0] rom [0:N_NOS-1];
    initial $readmemh(ARQ_ROM, rom);

    reg [31:0]      no_atual;
    reg [IDX_W-1:0] no_addr;   // endereco APRESENTADO a ROM neste ciclo
    reg [IDX_W-1:0] no_cur;    // endereco do no que esta em 'no_atual'

    // A ROM tem leitura registrada, entao 'no_atual' sempre corresponde ao
    // endereco do ciclo ANTERIOR. 'no_cur' acompanha esse atraso: sem ele, o
    // filho esquerdo (indice + 1) seria calculado a partir do endereco ja
    // avancado, pulando um nivel da arvore.
    always @(posedge clk) begin
        no_atual <= rom[no_addr];
        no_cur   <= no_addr;
    end

    // Decodificacao do no lido
    wire                   eh_folha = no_atual[31];
    wire [3:0]             feat_idx = no_atual[30:27];
    wire signed [WIDTH-1:0] limiar  = no_atual[26:11];
    wire [IDX_W-1:0]       filho_d  = no_atual[10:3];
    wire [1:0]             classe   = no_atual[1:0];

    // ------------------------------------------------------------------------
    // Banco de features
    // ------------------------------------------------------------------------
    reg signed [WIDTH-1:0] feat [0:N_FEATURES-1];
    reg [3:0]              feat_cnt;

    wire signed [WIDTH-1:0] feat_sel = feat[feat_idx];

    // ------------------------------------------------------------------------
    // Maquina de estados
    //   S_IDLE  -> espera start
    //   S_LOAD  -> recebe as N_FEATURES caracteristicas (handshake)
    //   S_FETCH -> 1 ciclo de latencia da ROM antes do primeiro no
    //   S_WALK  -> percorre 1 no por ciclo ate chegar a uma folha
    //   S_OUT   -> apresenta a classe ate o consumidor aceitar
    // ------------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_LOAD  = 3'd1,
                     S_FETCH = 3'd2,
                     S_WALK  = 3'd3,
                     S_OUT   = 3'd4;

    reg [2:0] state;
    reg [3:0] passos;          // guarda contra arvore malformada (ciclo na ROM)
    reg [1:0] classe_reg;
    reg       erro_reg;

    assign ready     = (state == S_IDLE);
    assign in_ready  = (state == S_LOAD) && enable;
    assign out_valid = (state == S_OUT);
    assign out_class = classe_reg;
    assign out_error = erro_reg;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            no_addr    <= {IDX_W{1'b0}};
            // no_cur NAO e resetado aqui: ele ja e escrito no always da ROM
            // (linha 110). Dois always no mesmo reg = erro 10028 no Quartus.
            feat_cnt   <= 4'd0;
            passos     <= 4'd0;
            classe_reg <= 2'd0;
            erro_reg   <= 1'b0;
            for (i = 0; i < N_FEATURES; i = i + 1)
                feat[i] <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;                       // pulso de 1 ciclo

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    busy     <= 1'b0;
                    feat_cnt <= 4'd0;
                    if (start && enable) begin
                        state    <= S_LOAD;
                        busy     <= 1'b1;
                        erro_reg <= 1'b0;
                    end
                end

                // ------------------------------------------------------
                // Carrega as 12 features. O handshake impede que uma nova
                // sobrescreva a anterior se a origem adiantar o envio.
                // ------------------------------------------------------
                S_LOAD: begin
                    if (in_valid && in_ready) begin
                        feat[feat_cnt] <= in_feature;
                        if (feat_cnt == N_FEATURES - 1) begin
                            no_addr <= {IDX_W{1'b0}};   // raiz
                            passos  <= 4'd0;
                            state   <= S_FETCH;
                        end else begin
                            feat_cnt <= feat_cnt + 1'b1;
                        end
                    end
                end

                // ------------------------------------------------------
                // A ROM tem leitura registrada: espera o no da raiz chegar.
                // ------------------------------------------------------
                S_FETCH: state <= S_WALK;

                // ------------------------------------------------------
                // Decide UM no e volta a S_FETCH.
                //
                // A ida e volta S_FETCH <-> S_WALK e necessaria porque a ROM
                // tem leitura registrada: o endereco escrito aqui so produz o
                // no correspondente no ciclo SEGUINTE. Sem esse ciclo de
                // espera, 'no_atual' ainda seria o no anterior e a FSM
                // decidiria DUAS vezes sobre o mesmo no -- contando 'passos'
                // em dobro e estourando o watchdog em caminhos profundos.
                //
                // Custa 2 ciclos por nivel (18 ciclos para profundidade 9),
                // irrelevante frente aos 500.000 ciclos da janela de 10 ms.
                // ------------------------------------------------------
                S_WALK: begin
                    if (eh_folha) begin
                        classe_reg <= classe;
                        state      <= S_OUT;
                    end else if (passos >= PROF_MAX[3:0]) begin
                        // Nunca deveria ocorrer com uma ROM bem formada;
                        // evita travar o acelerador se a ROM for corrompida.
                        erro_reg   <= 1'b1;
                        classe_reg <= 2'd0;
                        state      <= S_OUT;
                    end else begin
                        // filho esquerdo = no ATUAL + 1; 'no_cur' acompanha o
                        // atraso da ROM e aponta para o no que esta em uso.
                        no_addr <= (feat_sel <= limiar) ? (no_cur + 1'b1)
                                                        : filho_d;
                        passos  <= passos + 1'b1;
                        state   <= S_FETCH;
                    end
                end

                // ------------------------------------------------------
                S_OUT: begin
                    if (out_ready) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
