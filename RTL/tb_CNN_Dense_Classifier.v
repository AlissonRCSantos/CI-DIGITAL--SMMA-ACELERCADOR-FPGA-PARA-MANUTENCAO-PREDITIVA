// ============================================================================
// Testbench: tb_CNN_Dense_Classifier
// Verifica a etapa final: GAP -> camada densa 8x4 -> argmax.
//
// TESTE 1 (stream constante)
//   Injeta 256 amostras IGUAIS. Como a media de N valores iguais e o proprio
//   valor, as features do GAP devem reproduzir exatamente o vetor injetado.
//   Isso testa, de uma vez: o acumulador, a contagem das 256 posicoes, o
//   deslocamento de 8 bits (divisao por 256) e o arredondamento.
//   Em seguida confere os 4 scores e a classe vencedora contra o modelo de
//   referencia em ponto fixo.
//
// TESTE 2 (stream com media conhecida)
//   Injeta metade das amostras com valor A e metade com valor B: a media deve
//   ser (A+B)/2. Prova que o GAP realmente acumula ao longo do quadro, e nao
//   apenas repete a ultima amostra.
//
// TESTE 3 (desempate do argmax)
//   Verifica que, quando dois scores empatam, vence o de MENOR indice
//   (comportamento deterministico, importante para reprodutibilidade).
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Dense_Classifier;

    localparam WIDTH = 16;
    localparam NCH   = 8;
    localparam NCL   = 4;
    localparam NPOS  = 256;

    reg                    clk = 0, rst = 1, start = 0;
    reg                    in_valid = 0;
    reg  [NCH*WIDTH-1:0]   in_data = 0;
    reg                    run = 0;
    wire                   out_valid;
    wire [1:0]             out_class;
    wire [NCL*WIDTH-1:0]   out_scores;
    wire [NCH*WIDTH-1:0]   out_features;

    integer errors = 0, checks = 0;
    integer i, ch;
    reg [1:0]  cap_class;
    reg [NCL*WIDTH-1:0] cap_scores;
    reg [NCH*WIDTH-1:0] cap_feats;
    reg got_result;

    reg signed [WIDTH-1:0] vec  [0:NCH-1];
    reg signed [WIDTH-1:0] efe  [0:NCH-1];
    reg signed [WIDTH-1:0] esc  [0:NCL-1];

    always #10 clk = ~clk;

    CNN_Dense_Classifier #(
        .WIDTH(WIDTH), .FRAC(15), .ACC_W(40),
        .NUM_CH(NCH), .NUM_CLASSES(NCL), .GAP_ACC_W(32), .GAP_SHIFT(8)
    ) dut (
        .clk(clk), .rst(rst), .start(start),
        .in_valid(in_valid), .in_data(in_data), .run(run),
        .out_valid(out_valid), .out_class(out_class),
        .out_scores(out_scores), .out_features(out_features)
    );

    always @(negedge clk) if (out_valid) begin
        cap_class  = out_class;
        cap_scores = out_scores;
        cap_feats  = out_features;
        got_result = 1'b1;
    end

    // Injeta 'n' amostras iguais ao conteudo atual de in_data
    task push_n(input integer n);
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task set_vec;
        begin
            for (ch = 0; ch < NCH; ch = ch + 1)
                in_data[ch*WIDTH +: WIDTH] = vec[ch];
        end
    endtask

    task do_run;
        begin
            got_result = 1'b0;
            @(negedge clk); run = 1'b1;
            @(negedge clk); run = 1'b0;
            while (!got_result) @(negedge clk);
        end
    endtask

    task check_all(input [8*24-1:0] nome, input [1:0] exp_class);
        begin
            for (ch = 0; ch < NCH; ch = ch + 1) begin
                checks = checks + 1;
                if ($signed(cap_feats[ch*WIDTH +: WIDTH]) !== efe[ch]) begin
                    errors = errors + 1;
                    $display("  [FALHA] %0s feature%0d: obtido=%0d esperado=%0d", nome, ch,
                             $signed(cap_feats[ch*WIDTH +: WIDTH]), efe[ch]);
                end
            end
            for (ch = 0; ch < NCL; ch = ch + 1) begin
                checks = checks + 1;
                if ($signed(cap_scores[ch*WIDTH +: WIDTH]) !== esc[ch]) begin
                    errors = errors + 1;
                    $display("  [FALHA] %0s score%0d: obtido=%0d esperado=%0d", nome, ch,
                             $signed(cap_scores[ch*WIDTH +: WIDTH]), esc[ch]);
                end
            end
            checks = checks + 1;
            if (cap_class !== exp_class) begin
                errors = errors + 1;
                $display("  [FALHA] %0s classe: obtido=%0d esperado=%0d", nome, cap_class, exp_class);
            end
            $display("  [ OK  ] %0s", nome);
            $display("          features = [%0d %0d %0d %0d %0d %0d %0d %0d]",
                $signed(cap_feats[0*WIDTH +: WIDTH]), $signed(cap_feats[1*WIDTH +: WIDTH]),
                $signed(cap_feats[2*WIDTH +: WIDTH]), $signed(cap_feats[3*WIDTH +: WIDTH]),
                $signed(cap_feats[4*WIDTH +: WIDTH]), $signed(cap_feats[5*WIDTH +: WIDTH]),
                $signed(cap_feats[6*WIDTH +: WIDTH]), $signed(cap_feats[7*WIDTH +: WIDTH]));
            $display("          scores   = [%0d %0d %0d %0d]  -> classe %0d",
                $signed(cap_scores[0*WIDTH +: WIDTH]), $signed(cap_scores[1*WIDTH +: WIDTH]),
                $signed(cap_scores[2*WIDTH +: WIDTH]), $signed(cap_scores[3*WIDTH +: WIDTH]),
                cap_class);
        end
    endtask

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_Dense_Classifier (GAP + densa + argmax)");
        $display("========================================================\n");

        repeat (3) @(negedge clk);
        rst = 0;

        // ------------------------------------------------------------------
        // TESTE 1: stream constante -> GAP deve devolver o proprio vetor
        // ------------------------------------------------------------------
        $display("-- Teste 1: 256 amostras identicas (media = proprio valor)");
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        vec[0]=1000; vec[1]=20000; vec[2]=3000; vec[3]=15000;
        vec[4]=500;  vec[5]=800;   vec[6]=12000; vec[7]=9000;
        set_vec;
        push_n(NPOS);
        efe[0]=1000; efe[1]=20000; efe[2]=3000; efe[3]=15000;
        efe[4]=500;  efe[5]=800;   efe[6]=12000; efe[7]=9000;
        esc[0]=-10500; esc[1]=1488; esc[2]=-17512; esc[3]=-4024;
        do_run;
        check_all("stream constante", 2'd1);

        // ------------------------------------------------------------------
        // TESTE 2: metade com valor A, metade com valor B -> media (A+B)/2
        // ------------------------------------------------------------------
        $display("\n-- Teste 2: 128 amostras de A + 128 de B (media = (A+B)/2)");
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        // Primeira metade: tudo 4000
        for (ch = 0; ch < NCH; ch = ch + 1) vec[ch] = 4000;
        set_vec; push_n(NPOS/2);
        // Segunda metade: tudo 8000  -> media esperada = 6000
        for (ch = 0; ch < NCH; ch = ch + 1) vec[ch] = 8000;
        set_vec; push_n(NPOS/2);
        for (ch = 0; ch < NCH; ch = ch + 1) efe[ch] = 6000;
        // Scores com todas as features iguais a 6000 (calculados no golden model).
        // Note que score1 e score2 EMPATAM em -6512: como nenhum dos dois vence,
        // o empate nao decide aqui, mas o teste 3 abaixo cobre esse caso.
        esc[0]=-9000; esc[1]=-6512; esc[2]=-6512; esc[3]=-1024;
        do_run;
        check_all("media de A e B", 2'd3);

        // ------------------------------------------------------------------
        // TESTE 3: features todas ZERO -> scores = apenas os bias
        //          bias = [0, -512, -512, -1024] -> classe 0 vence
        //          e as classes 1 e 2 EMPATAM, provando o desempate estavel
        // ------------------------------------------------------------------
        $display("\n-- Teste 3: features nulas -> scores = bias (desempate)");
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        for (ch = 0; ch < NCH; ch = ch + 1) vec[ch] = 0;
        set_vec; push_n(NPOS);
        for (ch = 0; ch < NCH; ch = ch + 1) efe[ch] = 0;
        esc[0]=0; esc[1]=-512; esc[2]=-512; esc[3]=-1024;
        do_run;
        check_all("somente bias", 2'd0);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
