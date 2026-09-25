// Inversor NxN (N=2,3,4) por Gauss-Jordan com pivotamento parcial.
// Interface pronta para integracao no acelerador da DE0-CV.
module gauss_jordan_inv #(
    parameter WIDTH = 16, parameter FRAC = 12, parameter N_MAX = 4,
    parameter signed [WIDTH-1:0] EPSILON = 16'sd8
)(
    input wire clk, input wire reset, input wire enable, input wire start,
    input wire [2:0] n,
    input wire valid_in, output wire ready,
    input wire [1:0] load_row, input wire [1:0] load_col,
    input wire signed [WIDTH-1:0] load_data,
    output reg valid_out, output reg busy, output reg singular,
    input wire [1:0] read_row, input wire [2:0] read_col,
    output wire signed [WIDTH-1:0] read_data
);
    localparam S_IDLE=4'd0, S_FIND_PIVOT=4'd2, S_CHECK_PIVOT=4'd3,
        S_SWAP=4'd4, S_RECIP_START=4'd5, S_RECIP_WAIT=4'd6,
        S_NORMALIZE=4'd7, S_ELIM_LOAD=4'd8, S_ELIM_STEP=4'd9,
        S_NEXT_K=4'd11, S_DONE=4'd12, S_ERROR=4'd13;
    // Constante 1,0 representada no mesmo tamanho dos dados Qm.f.
    localparam signed [WIDTH-1:0] FP_ONE = ({{(WIDTH-1){1'b0}},1'b1} << FRAC);

    // 4 x 8 x 16 = 512 bits; cabe com folga na DE0-CV.
    reg signed [WIDTH-1:0] mem [0:N_MAX-1][0:2*N_MAX-1];
    reg [1:0] row_ptr [0:N_MAX-1];
    reg [3:0] state;
    reg [2:0] k, row_i;
    reg [3:0] col_cnt;
    reg [1:0] best_row;
    reg signed [WIDTH-1:0] best_val, pivot_inv, factor;
    integer ii, jj;

    wire [3:0] n2 = {1'b0,n} << 1;
    reg div_start;
    reg signed [2*WIDTH-1:0] div_numerator;
    reg signed [WIDTH-1:0] div_denominator;
    wire signed [WIDTH-1:0] div_quotient;
    wire div_done, div_by_zero;

    // Um unico multiplicador compartilhado entre NORMALIZE e ELIM_STEP.
    // Como os dois estados nunca ocorrem ao mesmo tempo, esta descricao evita
    // que o sintetizador infira um DSP para cada caminho aritmetico.
    wire signed [WIDTH-1:0] mult_a = (state == S_NORMALIZE)
                                      ? mem[row_ptr[k[1:0]]][col_cnt] : factor;
    wire signed [WIDTH-1:0] mult_b = (state == S_NORMALIZE)
                                      ? pivot_inv : mem[row_ptr[k[1:0]]][col_cnt];
    wire signed [2*WIDTH-1:0] mult_full = mult_a * mult_b;
    wire signed [2*WIDTH-1:0] mult_round = mult_full + (1 <<< (FRAC-1));
    wire signed [WIDTH-1:0] mult_q = mult_round[WIDTH+FRAC-1:FRAC];

    // A carga e permitida somente antes do start. Isto protege [A|I].
    assign ready = ~busy;
    assign read_data = mem[row_ptr[read_row]][read_col];

    fixed_point_divider #(.WIDTH(WIDTH),.FRAC(FRAC)) u_div (
        .clk(clk), .rst(reset), .enable(enable), .start(div_start),
        .numerator(div_numerator), .denominator(div_denominator),
        .quotient(div_quotient), .done(div_done), .div_by_zero(div_by_zero)
    );

    function signed [WIDTH-1:0] fp_abs;
        input signed [WIDTH-1:0] value;
        begin
            // abs(-2^(WIDTH-1)) satura para evitar overflow de complemento de 2.
            if (value == {1'b1,{(WIDTH-1){1'b0}}}) fp_abs = {1'b0,{(WIDTH-1){1'b1}}};
            else fp_abs = value[WIDTH-1] ? -value : value;
        end
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE; busy <= 1'b0; valid_out <= 1'b0;
            singular <= 1'b0; div_start <= 1'b0;
            for (ii=0; ii<N_MAX; ii=ii+1) row_ptr[ii] <= ii[1:0];
        end else if (enable) begin
            div_start <= 1'b0;
            if (valid_in && ready && (load_row < N_MAX) && (load_col < N_MAX))
                mem[load_row][load_col] <= load_data;

            case (state)
                S_IDLE: if (start && ((n==2)||(n==3)||(n==4))) begin
                    busy <= 1'b1; valid_out <= 1'b0; singular <= 1'b0;
                    for (ii=0; ii<N_MAX; ii=ii+1) begin
                        row_ptr[ii] <= ii[1:0];
                        for (jj=0; jj<N_MAX; jj=jj+1)
                            if (jj<n) mem[ii][n+jj] <= (ii==jj) ? FP_ONE : {WIDTH{1'b0}};
                    end
                    k <= 0; state <= S_FIND_PIVOT;
                end
                S_FIND_PIVOT: begin
                    best_row <= k[1:0];
                    best_val <= fp_abs(mem[row_ptr[k[1:0]]][k]);
                    row_i <= k+1'b1;
                    // Tambem valida o ultimo pivo contra EPSILON.
                    state <= S_CHECK_PIVOT;
                end
                S_CHECK_PIVOT: begin
                    if (row_i < n) begin
                        if (fp_abs(mem[row_ptr[row_i[1:0]]][k]) > best_val) begin
                            best_val <= fp_abs(mem[row_ptr[row_i[1:0]]][k]);
                            best_row <= row_i[1:0];
                        end
                        row_i <= row_i+1'b1;
                    end else if (best_val < EPSILON) state <= S_ERROR;
                    else if (best_row != k[1:0]) state <= S_SWAP;
                    else state <= S_RECIP_START;
                end
                S_SWAP: begin
                    row_ptr[k[1:0]] <= row_ptr[best_row];
                    row_ptr[best_row] <= row_ptr[k[1:0]];
                    state <= S_RECIP_START;
                end
                S_RECIP_START: begin
                    div_numerator <= FP_ONE <<< FRAC;
                    div_denominator <= mem[row_ptr[k[1:0]]][k];
                    div_start <= 1'b1; state <= S_RECIP_WAIT;
                end
                S_RECIP_WAIT: if (div_done) begin
                    if (div_by_zero) state <= S_ERROR;
                    else begin pivot_inv <= div_quotient; col_cnt <= 0; state <= S_NORMALIZE; end
                end
                S_NORMALIZE: if (col_cnt < n2) begin
                    mem[row_ptr[k[1:0]]][col_cnt] <= mult_q;
                    col_cnt <= col_cnt+1'b1;
                end else begin row_i <= 0; state <= S_ELIM_LOAD; end
                S_ELIM_LOAD: begin
                    if (row_i >= n) state <= S_NEXT_K;
                    else if (row_i == k) row_i <= row_i+1'b1;
                    else begin factor <= mem[row_ptr[row_i[1:0]]][k]; col_cnt <= 0; state <= S_ELIM_STEP; end
                end
                S_ELIM_STEP: if (col_cnt < n2) begin
                    mem[row_ptr[row_i[1:0]]][col_cnt] <= mem[row_ptr[row_i[1:0]]][col_cnt]
                        - mult_q;
                    col_cnt <= col_cnt+1'b1;
                end else begin row_i <= row_i+1'b1; state <= S_ELIM_LOAD; end
                S_NEXT_K: if (k+1'b1 < n) begin k <= k+1'b1; state <= S_FIND_PIVOT; end
                          else state <= S_DONE;
                S_DONE: begin busy <= 1'b0; valid_out <= 1'b1; state <= S_IDLE; end
                S_ERROR: begin busy <= 1'b0; singular <= 1'b1; valid_out <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
