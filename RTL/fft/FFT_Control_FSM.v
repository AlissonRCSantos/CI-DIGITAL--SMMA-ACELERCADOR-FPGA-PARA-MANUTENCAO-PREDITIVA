// ============================================================================
// FFT_Control_FSM -- maquina de estados da FFT (carga, 6 estagios, saida)
// ============================================================================

`timescale 1ns / 1ps

module FFT_Control_FSM #(
    parameter LOG2N   = 6,   // N = 64 pontos
    parameter BF_PIPE = 7,   // Latencia leitura->escrita (1 RAM + 6 butterfly)

    parameter [5:0] SCALE_MASK = 6'b001111
)(
    input  wire                  clk,           // Clock do sistema (50 MHz)
    input  wire                  rst,           // Reset sincrono ativo em alto

    // ---- Handshake externo ----
    input  wire                  start,         // Pulso que inicia a transformada
    input  wire                  enable,        // Habilitacao global
    input  wire                  in_valid,      // Amostra de entrada valida
    output wire                  in_ready,      // Modulo pronto para receber amostra
    input  wire                  out_ready,     // Consumidor pronto para receber bin
    output reg                   busy,          // Transformada em andamento
    output reg                   done,          // Pulso de conclusao (1 ciclo)
    output wire                  ready,         // Pronto para uma nova janela

    // ---- Controle da memoria de dados ----
    output reg  [LOG2N-1:0]      mem_a_addr,    // Endereco da porta A
    output reg                   mem_a_we,      // Write enable da porta A
    output reg  [LOG2N-1:0]      mem_b_addr,    // Endereco da porta B
    output reg                   mem_b_we,      // Write enable da porta B
    output wire                  mem_sel_load,  // 1: grava amostra ; 0: grava butterfly

    // ---- Controle da ROM de fatores de rotacao ----
    output wire [LOG2N-2:0]      tw_addr,       // Indice k do fator W_64^k
    output wire                  tw_rd_en,      // Habilita leitura da ROM

    // ---- Controle do butterfly ----
    output reg                   bf_in_valid,   // Operandos validos na entrada do butterfly
    output wire                  bf_scale_en,   // 1: este estagio divide por 2

    // ---- Controle da descarga ----
    output wire                  unload_rd,     // Leitura de um bin sendo emitida
    output wire [LOG2N-1:0]      unload_index,  // Indice do bin lido
    output wire                  out_pipe_adv,  // Clock-enable do pipeline de saida

    // ---- Observabilidade ----
    output wire [2:0]            stage_out      // Estagio corrente (1..6), para depuracao
);

    localparam N        = (1 << LOG2N);      // 64 pontos
    localparam NBFLY    = (N >> 1);          // 32 butterflies por estagio
    localparam OUT_PIPE = 3;                 // 1 ciclo de RAM + 2 do modulo de magnitude

    // Codificacao dos estados
    localparam [2:0] S_IDLE    = 3'd0,
                     S_LOAD    = 3'd1,
                     S_COMPUTE = 3'd2,
                     S_DRAIN   = 3'd3,
                     S_UNLOAD  = 3'd4,
                     S_FLUSH   = 3'd5,
                     S_DONE    = 3'd6;

    reg [2:0]        state;
    reg [LOG2N:0]    load_cnt;    // 0..64
    reg [2:0]        stage_r;     // Estagio corrente: 1..6
    reg [LOG2N-1:0]  bfly_cnt;    // 0..32
    reg              phase;       // 0: ciclo de leitura ; 1: ciclo de escrita
    reg [3:0]        drain_cnt;   // Esvaziamento do pipeline entre estagios
    reg [LOG2N:0]    unload_cnt;  // 0..64
    reg              unload_phase;// 0: endereco recem-apresentado ; 1: estavel (pode capturar)
    reg [1:0]        flush_cnt;   // Esvaziamento do pipeline de saida

    assign stage_out = stage_r;
    assign ready     = (state == S_IDLE);
    assign in_ready  = (state == S_LOAD) && enable;

    // Amostra efetivamente consumida (handshake completo)
    wire sample_taken = (state == S_LOAD) && in_valid && in_ready;

    // GERADOR DE ENDERECOS DOS BUTTERFLIES
    wire [LOG2N-1:0] addr_p;
    wire [LOG2N-1:0] addr_q;

    FFT_Addr_Gen #(
        .LOG2N(LOG2N)
    ) u_addr_gen (
        .stage(stage_r),
        .bfly_idx(bfly_cnt[LOG2N-2:0]),
        .addr_p(addr_p),
        .addr_q(addr_q),
        .tw_addr(tw_addr)
    );

    // INVERSAO DE BITS DO ENDERECO DE CARGA
    wire [LOG2N-1:0] load_addr_rev;

    FFT_Bit_Reverse #(
        .LOG2N(LOG2N)
    ) u_bit_rev (
        .index_in (load_cnt[LOG2N-1:0]),
        .index_out(load_addr_rev)
    );

    // EMISSAO DE LEITURA DE BUTTERFLY
    wire read_issue = (state == S_COMPUTE) && (phase == 1'b0) && (bfly_cnt < NBFLY);

    assign tw_rd_en     = 1'b1;                 // ROM lida continuamente (baixo custo)
    assign mem_sel_load = (state == S_LOAD);

    // Escala deste estagio (stage_r vale 1..LOG2N -> bit 0..LOG2N-1 da mascara).
    // O alinhamento fino com o dado e feito DENTRO do butterfly (scale_pipe).
    assign bf_scale_en  = SCALE_MASK[stage_r - 3'd1];

    // LINHA DE ATRASO DOS ENDERECOS DE ESCRITA (write-back)
    // Acompanha o dado pelos BF_PIPE = 7 ciclos do caminho leitura->butterfly.
    reg [BF_PIPE-1:0] wb_valid;
    reg [LOG2N-1:0]   wb_p [0:BF_PIPE-1];
    reg [LOG2N-1:0]   wb_q [0:BF_PIPE-1];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            wb_valid <= {BF_PIPE{1'b0}};
            for (i = 0; i < BF_PIPE; i = i + 1) begin
                wb_p[i] <= {LOG2N{1'b0}};
                wb_q[i] <= {LOG2N{1'b0}};
            end
        end else if (state == S_COMPUTE || state == S_DRAIN) begin
            wb_valid[0] <= read_issue;
            wb_p[0]     <= addr_p;
            wb_q[0]     <= addr_q;
            for (i = 1; i < BF_PIPE; i = i + 1) begin
                wb_valid[i] <= wb_valid[i-1];
                wb_p[i]     <= wb_p[i-1];
                wb_q[i]     <= wb_q[i-1];
            end
        end else begin
            wb_valid <= {BF_PIPE{1'b0}};
        end
    end

    // Sinal de escrita no final da linha de atraso
    wire             wb_fire = wb_valid[BF_PIPE-1];
    wire [LOG2N-1:0] wb_addr_p = wb_p[BF_PIPE-1];
    wire [LOG2N-1:0] wb_addr_q = wb_q[BF_PIPE-1];

    // Butterfly recebe os operandos 1 ciclo apos a emissao da leitura
    always @(posedge clk) begin
        if (rst)
            bf_in_valid <= 1'b0;
        else
            bf_in_valid <= read_issue;
    end

    // CONTROLE DA DESCARGA
    assign unload_rd     = (state == S_UNLOAD) && out_ready && (unload_phase == 1'b0);
    assign unload_index  = unload_cnt[LOG2N-1:0];
    assign out_pipe_adv  = ((state == S_UNLOAD) && out_ready && (unload_phase == 1'b1))
                         || ((state == S_FLUSH) && out_ready);

    // MAQUINA DE ESTADOS PRINCIPAL
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            load_cnt   <= {(LOG2N+1){1'b0}};
            stage_r    <= 3'd1;
            bfly_cnt   <= {LOG2N{1'b0}};
            phase      <= 1'b0;
            drain_cnt  <= 4'd0;
            unload_cnt <= {(LOG2N+1){1'b0}};
            unload_phase <= 1'b0;
            flush_cnt  <= 2'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;   // 'done' e um pulso de 1 ciclo

            case (state)
                S_IDLE: begin
                    busy       <= 1'b0;
                    load_cnt   <= {(LOG2N+1){1'b0}};
                    unload_cnt <= {(LOG2N+1){1'b0}};
                    flush_cnt  <= 2'd0;
                    if (start && enable) begin
                        state <= S_LOAD;
                        busy  <= 1'b1;
                    end
                end

                // Carga das 64 amostras, ja em ordem de bits invertidos
                S_LOAD: begin
                    if (sample_taken) begin
                        if (load_cnt == N - 1) begin
                            state     <= S_COMPUTE;
                            stage_r   <= 3'd1;
                            bfly_cnt  <= {LOG2N{1'b0}};
                            phase     <= 1'b0;
                            load_cnt  <= {(LOG2N+1){1'b0}};
                        end else begin
                            load_cnt <= load_cnt + 1'b1;
                        end
                    end
                end

                // 32 butterflies do estagio corrente, 2 ciclos cada
                S_COMPUTE: begin
                    phase <= ~phase;
                    if (read_issue) begin
                        bfly_cnt <= bfly_cnt + 1'b1;
                    end
                    if ((bfly_cnt >= NBFLY) && (phase == 1'b0)) begin
                        // Todos os butterflies do estagio foram emitidos
                        state     <= S_DRAIN;
                        drain_cnt <= 4'd0;
                    end
                end

                // Esvazia o pipeline antes de iniciar o proximo estagio
                S_DRAIN: begin
                    phase     <= ~phase;
                    drain_cnt <= drain_cnt + 1'b1;
                    if (drain_cnt == BF_PIPE[3:0]) begin
                        if (stage_r == LOG2N[2:0]) begin
                            // Ultimo estagio concluido -> entrega o espectro
                            state        <= S_UNLOAD;
                            unload_cnt   <= {(LOG2N+1){1'b0}};
                            unload_phase <= 1'b0;
                        end else begin
                            stage_r  <= stage_r + 1'b1;
                            bfly_cnt <= {LOG2N{1'b0}};
                            phase    <= 1'b0;
                            state    <= S_COMPUTE;
                        end
                    end
                end

                // Descarga dos 64 bins com contrapressao (out_ready).
                S_UNLOAD: begin
                    if (out_ready) begin
                        unload_phase <= ~unload_phase;
                        if (unload_phase == 1'b1) begin
                            if (unload_cnt == N - 1) begin
                                state     <= S_FLUSH;
                                flush_cnt <= 2'd0;
                            end else begin
                                unload_cnt <= unload_cnt + 1'b1;
                            end
                        end
                    end
                end

                // Esvazia o pipeline de saida (RAM + magnitude)
                S_FLUSH: begin
                    if (out_ready) begin
                        if (flush_cnt == OUT_PIPE[1:0]) begin
                            state <= S_DONE;
                        end else begin
                            flush_cnt <= flush_cnt + 1'b1;
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // MULTIPLEXACAO DAS PORTAS DA MEMORIA
    // Combinacional: define quem usa cada porta em cada ciclo.
    always @(*) begin
        // Valores padrao: memoria ociosa
        mem_a_addr = {LOG2N{1'b0}};
        mem_a_we   = 1'b0;
        mem_b_addr = {LOG2N{1'b0}};
        mem_b_we   = 1'b0;

        case (state)
            S_LOAD: begin
                // Escrita da amostra no endereco com bits invertidos
                mem_a_addr = load_addr_rev;
                mem_a_we   = sample_taken;
            end

            S_COMPUTE, S_DRAIN: begin
                if (phase == 1'b0) begin
                    // Ciclo de LEITURA dos operandos A e B
                    mem_a_addr = addr_p;
                    mem_b_addr = addr_q;
                end else begin
                    // Ciclo de ESCRITA dos resultados P e Q
                    mem_a_addr = wb_addr_p;
                    mem_a_we   = wb_fire;
                    mem_b_addr = wb_addr_q;
                    mem_b_we   = wb_fire;
                end
            end

            S_UNLOAD: begin
                // Leitura sequencial do espectro (ordem natural de frequencia)
                mem_a_addr = unload_cnt[LOG2N-1:0];
            end

            default: begin
                mem_a_addr = {LOG2N{1'b0}};
            end
        endcase
    end

endmodule
