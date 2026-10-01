// ============================================================================
// Testbench: tb_CNN_Line_Buffer
// Verifica o gerador de janelas 3x3 com zero-padding.
//
// Estrategia: usa uma imagem PEQUENA (4x4) com valores unicos e conhecidos
// (100, 200, ... 1600) e compara CADA UM dos 9 taps de CADA janela emitida
// contra um modelo de referencia escrito como funcao Verilog. Assim o teste
// cobre, de forma exaustiva:
//
//   * as 4 bordas (padding superior, inferior, esquerda e direita)
//   * os 4 cantos (dois lados de padding ao mesmo tempo)
//   * o interior (nenhum padding)
//   * a ordem de emissao (raster), que e o que o max pooling assume adiante
//   * a contagem: devem sair EXATAMENTE 16 janelas (mesmo tamanho da entrada,
//     que e o efeito do padding = 1)
//
// A mesma logica escala para 32x32 sem alteracao: o modulo e parametrizavel.
// ============================================================================

`timescale 1ns / 1ps

module tb_CNN_Line_Buffer;

    localparam WIDTH = 16;
    localparam IMG_W = 4;
    localparam IMG_H = 4;
    localparam CNT_W = 4;

    reg                     clk = 0, rst = 1;
    reg                     start = 0, push_en = 0;
    reg  signed [WIDTH-1:0] in_pixel = 0;
    wire                    need_pixel, last_push;
    wire [9*WIDTH-1:0]      out_win;
    wire                    win_valid;
    wire [CNT_W-1:0]        out_row, out_col;

    integer errors = 0, checks = 0;
    integer nwin   = 0;
    integer k, m, n, rr, cc, step;
    reg signed [WIDTH-1:0] got, exp;

    always #10 clk = ~clk;

    // Consumidor "sempre pronto": aceita toda janela imediatamente
    wire win_ack = win_valid;

    CNN_Line_Buffer #(.WIDTH(WIDTH), .IMG_W(IMG_W), .IMG_H(IMG_H), .CNT_W(CNT_W))
    dut (
        .clk(clk), .rst(rst), .start(start), .push_en(push_en), .win_ack(win_ack),
        .in_pixel(in_pixel), .need_pixel(need_pixel), .last_push(last_push),
        .out_win(out_win), .win_valid(win_valid),
        .out_row(out_row), .out_col(out_col)
    );

    // ---- Modelo de referencia: pixel da imagem COM zero-padding ----
    function signed [WIDTH-1:0] ref_px(input integer r, input integer c);
        begin
            if (r < 0 || r >= IMG_H || c < 0 || c >= IMG_W)
                ref_px = 0;                        // zona de padding
            else
                ref_px = (r*IMG_W + c + 1) * 100;  // pixel real
        end
    endfunction

    // ---- Confere uma janela inteira contra o modelo ----
    task check_window;
        begin
            nwin = nwin + 1;
            for (m = 0; m < 3; m = m + 1) begin
                for (n = 0; n < 3; n = n + 1) begin
                    rr = out_row; rr = rr + m - 1;   // linha absoluta do tap
                    cc = out_col; cc = cc + n - 1;   // coluna absoluta do tap
                    got = out_win[(m*3+n)*WIDTH +: WIDTH];
                    exp = ref_px(rr, cc);
                    checks = checks + 1;
                    if (got !== exp) begin
                        errors = errors + 1;
                        $display("  [FALHA] janela(%0d,%0d) tap[%0d][%0d]: obtido=%0d esperado=%0d",
                                 out_row, out_col, m, n, got, exp);
                    end
                end
            end
            $display("  [ OK  ] janela(%0d,%0d) = [%0d %0d %0d | %0d %0d %0d | %0d %0d %0d]",
                out_row, out_col,
                $signed(out_win[0*WIDTH +: WIDTH]), $signed(out_win[1*WIDTH +: WIDTH]),
                $signed(out_win[2*WIDTH +: WIDTH]), $signed(out_win[3*WIDTH +: WIDTH]),
                $signed(out_win[4*WIDTH +: WIDTH]), $signed(out_win[5*WIDTH +: WIDTH]),
                $signed(out_win[6*WIDTH +: WIDTH]), $signed(out_win[7*WIDTH +: WIDTH]),
                $signed(out_win[8*WIDTH +: WIDTH]));
        end
    endtask

    // Monitor: a cada ciclo com janela valida, confere
    always @(negedge clk) if (win_valid && !rst) check_window;

    initial begin
        $display("========================================================");
        $display(" TESTBENCH: CNN_Line_Buffer (janela 3x3, padding=1)");
        $display(" Imagem de teste 4x4 com pixels 100..1600");
        $display("========================================================\n");

        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;

        // Varredura completa: (IMG_H+1) x (IMG_W+1) = 25 passos
        k = 0;
        for (step = 0; step < (IMG_H+1)*(IMG_W+1); step = step + 1) begin
            @(negedge clk);
            push_en  = 1'b1;
            // Fornece o proximo pixel real quando o modulo pedir
            in_pixel = need_pixel ? ((k+1)*100) : 16'sd0;
            @(posedge clk); #1;
            if (need_pixel) k = k + 1;
        end
        @(negedge clk); push_en = 1'b0;
        repeat (3) @(negedge clk);

        // ---- Verificacoes globais ----
        $display("");
        checks = checks + 1;
        if (nwin !== IMG_W*IMG_H) begin
            errors = errors + 1;
            $display("  [FALHA] numero de janelas: obtido=%0d esperado=%0d", nwin, IMG_W*IMG_H);
        end else
            $display("  [ OK  ] %0d janelas emitidas (padding preserva o tamanho 4x4)", nwin);

        checks = checks + 1;
        if (k !== IMG_W*IMG_H) begin
            errors = errors + 1;
            $display("  [FALHA] pixels consumidos: obtido=%0d esperado=%0d", k, IMG_W*IMG_H);
        end else
            $display("  [ OK  ] %0d pixels lidos UMA UNICA VEZ cada (reuso via line buffer)", k);

        $display("\n========================================================");
        if (errors == 0)
            $display(" RESULTADO: TODOS OS %0d TESTES PASSARAM", checks);
        else
            $display(" RESULTADO: %0d FALHAS em %0d testes", errors, checks);
        $display("========================================================");
        $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
