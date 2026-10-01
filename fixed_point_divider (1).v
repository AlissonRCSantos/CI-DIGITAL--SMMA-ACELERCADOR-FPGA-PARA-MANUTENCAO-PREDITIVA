// ============================================================================
// fixed_point_divider.v
// Divisor sequencial (restoring division, 1 bit/ciclo) em ponto fixo Qm.f.
// Calcula quotient = numerator / denominator, ambos em formato Qm.f.
// O "numerator" já deve chegar pré-deslocado (numerator_real << FRAC) para
// que o resultado saia corretamente escalado em Qm.f.
// Usado pelo módulo de inversão para calcular o RECIPROCO do pivô: 1/pivo.
// ============================================================================
module fixed_point_divider #(
    parameter WIDTH = 16,   // largura do dado em Qm.f (ex: 16 bits)
    parameter FRAC  = 12    // bits fracionarios
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire                         start,
    input  wire signed [2*WIDTH-1:0]    numerator,    // ja pre-deslocado
    input  wire signed [WIDTH-1:0]      denominator,
    output reg  signed [WIDTH-1:0]      quotient,
    output reg                          done,
    output reg                          div_by_zero
);

    localparam IDLE   = 2'd0;
    localparam DIVIDE = 2'd1;

    localparam integer COUNT_WIDTH = $clog2(2*WIDTH) + 2;
    localparam [COUNT_WIDTH-1:0] DIV_ITERATIONS = 2*WIDTH;
    reg [1:0]              state;
    reg [COUNT_WIDTH-1:0]  count;
    reg                     sign_result;
    reg [2*WIDTH-1:0]       abs_num;
    reg [WIDTH-1:0]         abs_denom;
    // O resto sempre e menor que o denominador; WIDTH+1 bits sao suficientes.
    // Isto reduz registradores, comparador e subtrator do divisor.
    reg [WIDTH:0]           remainder;
    reg [WIDTH-1:0]         quot_unsigned;
    wire [WIDTH:0]          trial_rem = {remainder[WIDTH-1:0], abs_num[2*WIDTH-1]};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= IDLE;
            done          <= 1'b0;
            div_by_zero   <= 1'b0;
            quotient      <= {WIDTH{1'b0}};
        end else if (enable) begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (denominator == 0) begin
                            div_by_zero <= 1'b1;
                            done        <= 1'b1;
                            quotient    <= {WIDTH{1'b0}};
                        end else begin
                            div_by_zero   <= 1'b0;
                            sign_result   <= numerator[2*WIDTH-1] ^ denominator[WIDTH-1];
                            abs_num       <= numerator[2*WIDTH-1]   ? (~numerator + 1'b1)   : numerator;
                            abs_denom     <= denominator[WIDTH-1]   ? (~denominator + 1'b1) : denominator;
                            remainder     <= {(WIDTH+1){1'b0}};
                            quot_unsigned <= {WIDTH{1'b0}};
                            count         <= DIV_ITERATIONS;
                            state         <= DIVIDE;
                        end
                    end
                end

                DIVIDE: begin
                    if (count == 0) begin
                        quotient <= sign_result ? (~quot_unsigned + 1'b1) : quot_unsigned;
                        done     <= 1'b1;
                        state    <= IDLE;
                    end else begin
                        if (trial_rem >= {1'b0, abs_denom}) begin
                            remainder     <= trial_rem - {1'b0, abs_denom};
                            quot_unsigned <= (quot_unsigned << 1) | 1'b1;
                        end else begin
                            remainder     <= trial_rem;
                            quot_unsigned <= (quot_unsigned << 1);
                        end
                        abs_num <= abs_num << 1;
                        count   <= count - 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
