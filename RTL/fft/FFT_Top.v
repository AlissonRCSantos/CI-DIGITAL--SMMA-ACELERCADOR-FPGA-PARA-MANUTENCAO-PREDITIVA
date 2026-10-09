// ============================================================================
// FFT_Top -- FFT de 64 pontos, radix-2 DIT, Q1.15 (enunciado 3.2)
// ============================================================================

`timescale 1ns / 1ps

module FFT_Top #(
    parameter WIDTH = 16,   // Largura da palavra de dados (Q1.15)
    parameter FRAC  = 15,   // Bits fracionarios
    parameter LOG2N = 6,    // N = 2^LOG2N = 64 pontos

    // ESCALONAMENTO POR ESTAGIO (bit i = 1 -> estagio i+1 divide por 2)
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

    // SINAIS DE INTERLIGACAO
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

    // 1. UNIDADE DE CONTROLE
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

    // 2. MEMORIA DE DADOS (in-place, true dual-port)
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

    // 3. ROM DOS FATORES DE ROTACAO
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

    // 4. UNIDADE BUTTERFLY (reutilizada 192 vezes)
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

    // 5. PIPELINE DE SAIDA (descarga do espectro)
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

    // 6. ESTIMADOR DE MAGNITUDE (alimenta o detector de picos)
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

    // SUPRESSAO DE REPETICOES: compara o indice contra o ULTIMO INDICE
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
