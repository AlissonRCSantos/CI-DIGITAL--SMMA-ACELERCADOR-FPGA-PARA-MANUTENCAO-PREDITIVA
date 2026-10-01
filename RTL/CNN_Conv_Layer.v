// ============================================================================
// Module: CNN_Conv_Layer
// Description: Camada convolucional 3x3 com 8 filtros, stride 1, padding 1,
//              seguida de bias e ativacao ReLU.
//
// DECISAO DE ARQUITETURA (o coracao da avaliacao "nivel de paralelismo")
// -----------------------------------------------------------------------
// Uma convolucao completa 32x32 com 8 filtros 3x3 exige
//        32 * 32 * 9 * 8 = 73.728 multiplicacoes.
//
// Tres opcoes classicas de mapeamento:
//   (a) Totalmente paralelo : 72 multiplicadores (8 filtros x 9 taps).
//                             1 janela por ciclo, ~1024 ciclos (20 us),
//                             mas estoura o orcamento de DSPs da Cyclone V.
//   (b) Totalmente serial   : 1 multiplicador reutilizado 73.728 vezes.
//                             1 DSP apenas, mas ~1,47 ms.
//   (c) PARALELO NO FILTRO, SERIAL NO TAP  <-- ESCOLHIDO
//                             8 multiplicadores (1 por filtro), cada um
//                             reutilizado 9 vezes (1 por tap da janela).
//
// Por que (c) e a melhor escolha aqui:
//   * Os 8 filtros LEEM A MESMA JANELA 3x3. Processa-los em paralelo
//     reaproveita o dado ja lido -- reuso espacial "de graca", sem custo
//     nenhum de memoria adicional.
//   * Serializar os 9 taps mantem o uso de DSPs em apenas 8 (viavel),
//     e ainda assim entrega 9 ciclos por janela:
//         1024 janelas x 9 ciclos ~= 9.216 ciclos ~= 184 us @ 50 MHz,
//     muito abaixo do limite de 10 ms por janela exigido no enunciado.
//   * E exatamente a mesma filosofia "folded / recurso compartilhado" que ja
//     foi usada no filtro LMS (1 PE reutilizado 16 vezes por amostra).
//
// PIPELINE E THROUGHPUT
// ---------------------
// A FSM interna emite 1 tap por ciclo. Ao emitir o tap 8 (ultimo) ela ja
// aceita a proxima janela, de modo que os taps fluem sem bolha: o regime
// permanente e de exatamente 9 ciclos por janela.
// A latencia do MAC (3 ciclos) e absorvida pelo pipeline -- os flags
// first/last viajam junto com o dado, entao a acumulacao da janela N termina
// enquanto a janela N+1 ja esta entrando. Nao ha conflito porque o
// acumulador so e recarregado quando o produto marcado com 'first' chega.
//
// Interface de fluxo (handshake):
//   win_valid / win_ready  -> impede que uma janela nova sobrescreva a atual
//   out_valid              -> strobe de 1 ciclo com os 8 canais prontos
// ============================================================================

`timescale 1ns / 1ps

module CNN_Conv_Layer #(
    parameter WIDTH       = 16,   // Q1.15
    parameter FRAC        = 15,
    parameter ACC_W       = 40,
    parameter NUM_FILTERS = 8,
    parameter NUM_TAPS    = 9     // 3x3
)(
    input  wire                          clk,
    input  wire                          rst,

    // ---- Entrada: janela 3x3 vinda do CNN_Line_Buffer ----
    input  wire                          win_valid,
    input  wire [NUM_TAPS*WIDTH-1:0]     win_data,
    output wire                          win_ready,

    // ---- Saida: 8 mapas de caracteristicas (1 pixel de cada, em paralelo) ----
    output reg                           out_valid,
    output reg  [NUM_FILTERS*WIDTH-1:0]  out_data
);

    // ========================================================================
    // 1. Sequenciador de taps (mini-FSM baseada em contador, no mesmo estilo
    //    do LMS_Control_FSM)
    // ========================================================================
    reg                        active;    // Ha uma janela sendo processada
    reg [3:0]                  tap_cnt;   // 0..8
    reg [NUM_TAPS*WIDTH-1:0]   win_reg;   // Janela travada (estavel por 9 ciclos)

    // Pode aceitar nova janela: quando esta ocioso OU no ultimo tap da atual
    assign win_ready = (!active) || (tap_cnt == 4'd8);

    always @(posedge clk) begin
        if (rst) begin
            active  <= 1'b0;
            tap_cnt <= 4'd0;
            win_reg <= {(NUM_TAPS*WIDTH){1'b0}};
        end else begin
            if (!active) begin
                // Ocioso: engata a primeira janela que aparecer
                if (win_valid) begin
                    win_reg <= win_data;
                    active  <= 1'b1;
                    tap_cnt <= 4'd0;
                end
            end else if (tap_cnt == 4'd8) begin
                // Ultimo tap desta janela sendo emitido AGORA (usa win_reg antigo).
                // Se ja houver proxima janela, emenda sem bolha.
                if (win_valid) begin
                    win_reg <= win_data;
                    tap_cnt <= 4'd0;
                end else begin
                    active  <= 1'b0;
                end
            end else begin
                tap_cnt <= tap_cnt + 4'd1;
            end
        end
    end

    // Sinais de controle para os MACs
    wire mac_en    = active;
    wire mac_first = active && (tap_cnt == 4'd0);
    wire mac_last  = active && (tap_cnt == 4'd8);

    // ========================================================================
    // 2. Multiplexador do tap da janela
    //    'case' explicito em vez de indexacao vetorial variavel, seguindo o
    //    mesmo cuidado ja adotado no projeto do LMS para evitar problemas de
    //    interpretacao em ferramentas de sintese.
    // ========================================================================
    reg signed [WIDTH-1:0] win_tap;

    always @(*) begin
        case (tap_cnt)
            4'd0: win_tap = win_reg[0*WIDTH +: WIDTH];
            4'd1: win_tap = win_reg[1*WIDTH +: WIDTH];
            4'd2: win_tap = win_reg[2*WIDTH +: WIDTH];
            4'd3: win_tap = win_reg[3*WIDTH +: WIDTH];
            4'd4: win_tap = win_reg[4*WIDTH +: WIDTH];
            4'd5: win_tap = win_reg[5*WIDTH +: WIDTH];
            4'd6: win_tap = win_reg[6*WIDTH +: WIDTH];
            4'd7: win_tap = win_reg[7*WIDTH +: WIDTH];
            4'd8: win_tap = win_reg[8*WIDTH +: WIDTH];
            default: win_tap = {WIDTH{1'b0}};
        endcase
    end

    // ========================================================================
    // 3. ROM de pesos: entrega os 8 pesos do tap atual simultaneamente
    // ========================================================================
    wire [NUM_FILTERS*WIDTH-1:0] rom_conv_w;
    wire [NUM_FILTERS*WIDTH-1:0] rom_conv_bias;

    CNN_Weight_ROM #(
        .WIDTH(WIDTH),
        .NUM_FILTERS(NUM_FILTERS)
    ) u_rom (
        .tap_addr(tap_cnt),
        .conv_w(rom_conv_w),
        .conv_bias(rom_conv_bias),
        .dense_addr(5'd0),
        .dense_w(),
        .dense_bias_addr(2'd0),
        .dense_bias()
    );

    // ========================================================================
    // 4. Banco de MACs: um por filtro, todos compartilhando a MESMA janela
    // ========================================================================
    wire [NUM_FILTERS-1:0]       mac_valid;
    wire [NUM_FILTERS*WIDTH-1:0] relu_out;

    genvar f;
    generate
        for (f = 0; f < NUM_FILTERS; f = f + 1) begin : g_filter

            // Peso e bias deste filtro
            wire signed [WIDTH-1:0] w_f    = rom_conv_w[f*WIDTH +: WIDTH];
            wire signed [WIDTH-1:0] bias_f = rom_conv_bias[f*WIDTH +: WIDTH];

            // Bias alinhado ao formato do acumulador: bias << FRAC, com
            // extensao de sinal ate ACC_W bits.
            wire signed [ACC_W-1:0] init_f =
                { {(ACC_W-WIDTH-FRAC){bias_f[WIDTH-1]}}, bias_f, {FRAC{1'b0}} };

            wire signed [ACC_W-1:0] acc_f;

            CNN_MAC_Unit #(
                .WIDTH(WIDTH),
                .ACC_W(ACC_W)
            ) u_mac (
                .clk(clk),
                .rst(rst),
                .en(mac_en),
                .first(mac_first),
                .last(mac_last),
                .init_acc(init_f),
                .in_a(win_tap),      // pixel: o MESMO para todos os filtros
                .in_b(w_f),          // peso: especifico de cada filtro
                .out_acc(acc_f),
                .out_valid(mac_valid[f])
            );

            // Reescala Q?.30 -> Q1.15, satura e aplica ReLU
            CNN_ReLU #(
                .ACC_W(ACC_W),
                .WIDTH(WIDTH),
                .SHIFT(FRAC),
                .ENABLE_RELU(1)
            ) u_relu (
                .in_acc(acc_f),
                .out_y(relu_out[f*WIDTH +: WIDTH])
            );
        end
    endgenerate

    // ========================================================================
    // 5. Registro de saida
    //    Os 8 MACs terminam no mesmo ciclo (mesmo escalonamento), entao basta
    //    observar o valid do filtro 0. Registrar aqui garante que out_data
    //    fique estavel durante todo o ciclo em que out_valid esta alto.
    // ========================================================================
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_data  <= {(NUM_FILTERS*WIDTH){1'b0}};
        end else begin
            out_valid <= mac_valid[0];
            if (mac_valid[0])
                out_data <= relu_out;
        end
    end

endmodule
