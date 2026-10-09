// ============================================================================
// tb_Feature_Spectral -- testbench: 8 caracteristicas espectrais bit a bit
// ============================================================================

`timescale 1ns / 1ps

module tb_Feature_Spectral;

    parameter WIDTH     = 16;
    parameter N_BINS    = 32;
    parameter N_QUADROS = 32;
    parameter N_FEAT    = 8;
    parameter TOTAL_MAG = N_BINS * N_QUADROS;
    parameter MAX_CASOS = 8;
    parameter CLK_PERIOD = 20;

    reg clk = 0, rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                      start;
    reg                      in_valid;
    reg  [WIDTH-1:0]         in_mag;
    wire                     in_ready, ready, busy, done, out_valid;
    wire signed [WIDTH-1:0]  out_feature;

    // contrapressao independente da saida
    reg       bp_enable;
    reg [1:0] bp_cnt;
    wire      out_ready = bp_enable ? (bp_cnt != 2'd0) : 1'b1;
    always @(negedge clk) bp_cnt <= (bp_cnt == 2'd2) ? 2'd0 : bp_cnt + 1'b1;

    // ---- memoria de espectros -> features espectrais ----
    wire                     sa_ready, sa_busy, sa_done;
    wire                     sa_out_valid, sa_out_ready;
    wire [5:0]               sa_out_bin;
    wire [WIDTH-1:0]         sa_out_mag;
    wire                     fs_ready, fs_busy;

    Spectrum_Accumulator #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .N_QUADROS(N_QUADROS)
    ) u_sa (
        .clk(clk), .rst(rst), .start(start),
        .ready(sa_ready), .busy(sa_busy), .done(sa_done),
        .in_valid(in_valid), .in_ready(in_ready), .in_mag(in_mag),
        .out_ready(sa_out_ready), .out_valid(sa_out_valid),
        .out_bin(sa_out_bin), .out_mag(sa_out_mag)
    );

    Feature_Spectral #(
        .WIDTH(WIDTH), .N_BINS(N_BINS), .ACC_W(24), .N_FEAT(N_FEAT)
    ) uut (
        .clk(clk), .rst(rst), .start(start),
        .ready(fs_ready), .busy(fs_busy), .done(done),
        .in_valid(sa_out_valid), .in_ready(sa_out_ready), .in_mag(sa_out_mag),
        .out_ready(out_ready), .out_valid(out_valid), .out_feature(out_feature)
    );

    assign ready = sa_ready && fs_ready;
    assign busy  = sa_busy  || fs_busy;

    // arquivo: [n_casos][caso 0: 1024 mags + 8 features][caso 1: ...]
    reg [15:0] arq [0:1 + MAX_CASOS*(TOTAL_MAG + N_FEAT) - 1];
    integer n_casos;

    integer success_count = 0;
    integer fail_count    = 0;

    // ---- produtor sincrono das magnitudes ----
    integer base_in, idx_in;
    reg     enviando;
    always @(posedge clk) begin
        if (rst || !enviando) begin
            in_valid <= 1'b0; in_mag <= {WIDTH{1'b0}}; idx_in <= 0;
        end else if (enviando) begin
            if (in_valid && in_ready) begin
                idx_in <= idx_in + 1;
                if (idx_in + 1 < TOTAL_MAG) begin
                    in_valid <= 1'b1;
                    in_mag   <= arq[base_in + idx_in + 1];
                end else begin
                    in_valid <= 1'b0;
                end
            end else if (!in_valid && idx_in < TOTAL_MAG) begin
                in_valid <= 1'b1;
                in_mag   <= arq[base_in + idx_in];
            end
        end
    end

    // ---- coletor das features ----
    reg signed [WIDTH-1:0] obtido [0:N_FEAT-1];
    integer n_out;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (n_out < N_FEAT) obtido[n_out] = out_feature;
            n_out = n_out + 1;
        end
    end

    integer c, f, base, erros, guarda, erros_caso, ciclos, ciclos_max;

    initial begin
        $display("======================================================================");
        $display("   EXTRATOR DAS 8 FEATURES ESPECTRAIS -- janelas reais do dataset     ");
        $display("======================================================================");

        $readmemh("vetores/feat_teste.hex", arq);
        n_casos = arq[0];
        $display("casos: %0d janelas de teste\n", n_casos);

        rst = 1; start = 0; enviando = 0; n_out = 0;
        bp_enable = 0; bp_cnt = 0; erros = 0; ciclos_max = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        if (ready === 1'b1 && busy === 1'b0) begin
            success_count = success_count + 1;
            $display("[PASS] Reset: ready=1, busy=0");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Reset: ready=%b busy=%b", ready, busy);
        end

        for (c = 0; c < n_casos; c = c + 1) begin
            base    = 1 + c*(TOTAL_MAG + N_FEAT);
            base_in = base;
            n_out   = 0;
            enviando = 1'b0;
            bp_enable = (c % 2);            // metade dos casos com contrapressao

            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            enviando = 1'b1;

            ciclos = 0;
            while (n_out < N_FEAT && ciclos < 100000) begin
                @(posedge clk);
                ciclos = ciclos + 1;
            end
            if (ciclos > ciclos_max) ciclos_max = ciclos;
            enviando = 1'b0;
            repeat (5) @(negedge clk);

            erros_caso = 0;
            for (f = 0; f < N_FEAT; f = f + 1) begin
                if (obtido[f] !== $signed(arq[base + TOTAL_MAG + f])) begin
                    erros_caso = erros_caso + 1;
                    if (erros < 12) begin
                        $display("[FAIL] caso %0d feature %0d: obtido %0d, esperado %0d",
                                 c, f, obtido[f], $signed(arq[base + TOTAL_MAG + f]));
                        erros = erros + 1;
                    end
                end
            end
            if (erros_caso == 0)
                $display("   caso %0d: 8/8 features corretas  [%0d ciclos]", c, ciclos);
            else
                erros = erros + 0;
            if (erros_caso != 0) fail_count = fail_count + 1;
        end

        if (fail_count == 0) begin
            success_count = success_count + 1;
            $display("\n[PASS] %0d janelas x 8 features batem BIT A BIT com o modelo Python",
                     n_casos);
        end

        if (ciclos_max < 5000) begin
            success_count = success_count + 1;
            $display("[PASS] Latencia maxima: %0d ciclos (%0d us @ 50 MHz)",
                     ciclos_max, ciclos_max*CLK_PERIOD/1000);
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Latencia de %0d ciclos", ciclos_max);
        end

        if (ready === 1'b1) begin
            success_count = success_count + 1;
            $display("[PASS] Reuso: pronto para nova janela sem reset");
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL] Nao voltou a IDLE");
        end

        $display("\n======================================================================");
        $display(" RESUMO: %0d verificacao(oes) OK, %0d com falha", success_count, fail_count);
        if (fail_count == 0)
            $display(" TODOS OS TESTES DO EXTRATOR ESPECTRAL PASSARAM COM SUCESSO!");
        else
            $display(" HOUVE FALHAS NO EXTRATOR ESPECTRAL.");
        $display("======================================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[FAIL] Timeout global da simulacao!");
        $finish;
    end

endmodule
