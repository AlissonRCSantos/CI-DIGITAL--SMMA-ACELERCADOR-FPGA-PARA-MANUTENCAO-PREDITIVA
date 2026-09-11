// ============================================================================
// Testbench: tb_CNN_Conv_Layer
// Verifica a camada convolucional completa (8 filtros + bias + ReLU).
//
// Os valores esperados foram calculados de forma INDEPENDENTE, em um modelo
// de referencia em ponto fixo (golden model), reproduzindo exatamente:
//        acc  = bias<<15 + soma(pixel[t] * peso[f][t])
//        y    = ReLU( saturar( arredondar(acc >> 15) ) )
//
// Casos escolhidos e o que cada um prova:
//   1) JANELA UNIFORME     -> os detectores de borda devem dar ZERO
//                             (mais o bias). E a prova pratica da propriedade
//                             "soma dos coeficientes = 0".
//   2) IMPULSO NO CENTRO   -> so o coeficiente central de cada filtro atua.
//                             Prova o alinhamento correto tap<->peso.
//   3) RAMPA               -> caso generico, todos os 9 taps contribuem.
//   4) JANELA NEGATIVA     -> prova que o ReLU esta zerando as saidas negativas.
//
// Tambem verifica o THROUGHPUT: janelas consecutivas devem ser aceitas a cada
// 9 ciclos, sem bolha no pipeline.
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Conv_Layer;

    localparam WIDTH = 16;
    localparam NF    = 8;

    reg                    clk = 0, rst = 1;
    reg                    win_valid = 0;
    reg  [9*WIDTH-1:0]     win_data = 0;
    wire                   win_ready;
    wire                   out_valid;
    wire [NF*WIDTH-1:0]    out_data;

    integer errors = 0, checks = 0;
    integer f, i, nout = 0;
    reg [NF*WIDTH-1:0] cap;
    integer t_accept_a, t_accept_b;

    reg signed [WIDTH-1:0] expv [0:NF-1];

    always #10 clk = ~clk;

    CNN_Conv_Layer #(.WIDTH(WIDTH), .FRAC(15), .ACC_W(40), .NUM_FILTERS(NF))
    dut (
        .clk(clk), .rst(rst),
        .win_valid(win_valid), .win_data(win_data), .win_ready(win_ready),
        .out_valid(out_valid), .out_data(out_data)
    );

    always @(negedge clk) if (out_valid) begin cap = out_data; nout = nout + 1; end

    // Monta a janela a partir de 9 valores
    function [9*WIDTH-1:0] mkwin;
        input signed [WIDTH-1:0] a0,a1,a2,a3,a4,a5,a6,a7,a8;
        begin mkwin = {a8,a7,a6,a5,a4,a3,a2,a1,a0}; end
    endfunction

    // Envia uma janela respeitando o handshake win_valid / win_ready
    task send_win(input [9*WIDTH-1:0] w);
        begin
            win_data  = w;
            win_valid = 1'b1;
            @(negedge clk);
            while (win_ready !== 1'b1) @(negedge clk);
            @(posedge clk); #1;
            win_valid = 1'b0;
        end
    endtask

    task check_out(input [8*32-1:0] nome);
        begin
            for (f = 0; f < NF; f = f + 1) begin
                checks = checks + 1;
                if ($signed(cap[f*WIDTH +: WIDTH]) !== expv[f]) begin
                    errors = errors + 1;
                    $display("  [FALHA] %0s F%0d: obtido=%0d esperado=%0d",
                             nome, f, $signed(cap[f*WIDTH +: WIDTH]), expv[f]);
                end
            end
            $display("  [ OK  ] %-16s -> [%0d %0d %0d %0d %0d %0d %0d %0d]", nome,
                $signed(cap[0*WIDTH +: WIDTH]), $signed(cap[1*WIDTH +: WIDTH]),
                $signed(cap[2*WIDTH +: WIDTH]), $signed(cap[3*WIDTH +: WIDTH]),
                $signed(cap[4*WIDTH +: WIDTH]), $signed(cap[5*WIDTH +: WIDTH]),
                $signed(cap[6*WIDTH +: WIDTH]), $signed(cap[7*WIDTH +: WIDTH]));
        end
    endtask

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_Conv_Layer (3x3, 8 filtros, bias, ReLU)");
        $display("========================================================\n");

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ------------------------------------------------------------------
        // CASO 1: janela uniforme (todos os pixels = 8192 = 0.25)
        // Detectores de borda somam zero -> saida = apenas o bias (com ReLU)
        // ------------------------------------------------------------------
        $display("-- Caso 1: janela UNIFORME (0.25 em todos os 9 pixels)");
        $display("   esperado: detectores de borda dao 0 (so sobra o bias positivo)");
        expv[0]=0; expv[1]=256; expv[2]=0; expv[3]=8704;
        expv[4]=0; expv[5]=1024; expv[6]=0; expv[7]=6144;
        send_win(mkwin(16'sd8192,16'sd8192,16'sd8192,
                       16'sd8192,16'sd8192,16'sd8192,
                       16'sd8192,16'sd8192,16'sd8192));
        repeat (14) @(negedge clk);
        check_out("uniforme");

        // ------------------------------------------------------------------
        // CASO 2: impulso no centro -> so o coeficiente central atua
        // ------------------------------------------------------------------
        $display("\n-- Caso 2: IMPULSO no centro da janela");
        $display("   esperado: F2/F6/F7 (centro 0.5) respondem forte");
        expv[0]=0; expv[1]=256; expv[2]=16128; expv[3]=4153;
        expv[4]=0; expv[5]=1024; expv[6]=15360; expv[7]=18432;
        send_win(mkwin(16'sd0,16'sd0,16'sd0,
                       16'sd0,16'sd32767,16'sd0,
                       16'sd0,16'sd0,16'sd0));
        repeat (14) @(negedge clk);
        check_out("impulso");

        // ------------------------------------------------------------------
        // CASO 3: rampa (todos os taps contribuem)
        // ------------------------------------------------------------------
        $display("\n-- Caso 3: RAMPA crescente (caso generico)");
        expv[0]=8192; expv[1]=24832; expv[2]=0; expv[3]=16896;
        expv[4]=24064; expv[5]=13312; expv[6]=0; expv[7]=10240;
        send_win(mkwin(16'sd0,16'sd4096,16'sd8192,
                       16'sd12288,16'sd16384,16'sd20480,
                       16'sd24576,16'sd28672,16'sd32767));
        repeat (14) @(negedge clk);
        check_out("rampa");

        // ------------------------------------------------------------------
        // CASO 4: janela negativa -> prova a acao do ReLU
        // ------------------------------------------------------------------
        $display("\n-- Caso 4: janela NEGATIVA (prova do ReLU)");
        $display("   esperado: tudo que daria negativo vira exatamente 0");
        expv[0]=0; expv[1]=256; expv[2]=0; expv[3]=0;
        expv[4]=0; expv[5]=1024; expv[6]=0; expv[7]=0;
        send_win(mkwin(-16'sd8192,-16'sd8192,-16'sd8192,
                       -16'sd8192,-16'sd8192,-16'sd8192,
                       -16'sd8192,-16'sd8192,-16'sd8192));
        repeat (14) @(negedge clk);
        check_out("negativa");

        // ------------------------------------------------------------------
        // CASO 5: THROUGHPUT -- janelas consecutivas a cada 9 ciclos
        // ------------------------------------------------------------------
        $display("\n-- Caso 5: throughput em regime permanente");
        nout = 0;
        win_data  = mkwin(16'sd1000,16'sd1000,16'sd1000,16'sd1000,16'sd1000,
                          16'sd1000,16'sd1000,16'sd1000,16'sd1000);
        win_valid = 1'b1;                 // mantem sempre uma janela disponivel
        // mede a distancia entre dois aceites consecutivos
        @(negedge clk);
        while (win_ready !== 1'b1) @(negedge clk);
        t_accept_a = $time;
        @(negedge clk);
        while (win_ready !== 1'b1) @(negedge clk);
        t_accept_b = $time;
        win_valid = 1'b0;
        checks = checks + 1;
        if ((t_accept_b - t_accept_a) !== 180) begin  // 9 ciclos x 20 ns
            errors = errors + 1;
            $display("  [FALHA] intervalo entre janelas: %0d ns (esperado 180 ns = 9 ciclos)",
                     t_accept_b - t_accept_a);
        end else
            $display("  [ OK  ] uma janela aceita a cada 9 ciclos (sem bolha no pipeline)");

        repeat (20) @(negedge clk);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
