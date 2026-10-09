module mdc_gcd #(
    parameter integer IDX_WIDTH = 6,   

    parameter integer NUM_PEAKS = 3   
)(
    input  wire                   clk,
    input  wire                   rst_n,      

    input  wire                   start,      
    output reg                    busy,      
    output reg                    done,       


    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire [IDX_WIDTH-1:0]   in_data,    // indice do bin de um pico detectado

    input  wire [IDX_WIDTH-1:0]   cfg_min_valid, // k0 minimo aceitavel

    output reg                    out_valid,
    input  wire                   out_ready,
    output reg  [IDX_WIDTH-1:0]   out_data,   // k0 estimado
    output reg                    out_error   // 1 = resultado invalido
);


    localparam integer CNT_W  = (NUM_PEAKS <= 1) ? 1 : $clog2(NUM_PEAKS + 1);
    localparam integer ITER_W = IDX_WIDTH + 2;
    localparam [ITER_W-1:0] MAX_ITER = (1 << IDX_WIDTH) + 4; // margem de seguranca (watchdog)

    localparam [2:0]
        S_IDLE     = 3'd0,
        S_RECV     = 3'd1,
        S_GCD      = 3'd2,
        S_FINALIZE = 3'd3,
        S_OUT      = 3'd4;

    reg [2:0] state;

    reg [IDX_WIDTH-1:0] reg_a, reg_b;   
    reg [IDX_WIDTH-1:0] acc;           
    reg                 acc_valid;      
    reg [CNT_W-1:0]     peak_cnt;       
    reg [ITER_W-1:0]    iter_cnt;       
    reg                 timeout_err;    

    wire a_gt_b = (reg_a > reg_b);
    wire a_eq_b = (reg_a == reg_b);
    wire [IDX_WIDTH-1:0] diff_ab = reg_a - reg_b;  // subtrator: a-b
    wire [IDX_WIDTH-1:0] diff_ba = reg_b - reg_a;  // subtrator: b-a

    assign in_ready = (state == S_RECV);


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            out_valid   <= 1'b0;
            out_error   <= 1'b0;
            out_data    <= {IDX_WIDTH{1'b0}};
            acc         <= {IDX_WIDTH{1'b0}};
            acc_valid   <= 1'b0;
            peak_cnt    <= {CNT_W{1'b0}};
            iter_cnt    <= {ITER_W{1'b0}};
            timeout_err <= 1'b0;
            reg_a       <= {IDX_WIDTH{1'b0}};
            reg_b       <= {IDX_WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)

            // -----------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy        <= 1'b1;
                    acc_valid   <= 1'b0;
                    peak_cnt    <= {CNT_W{1'b0}};
                    timeout_err <= 1'b0;
                    out_valid   <= 1'b0;
                    state       <= S_RECV;
                end
            end

            S_RECV: begin
                busy <= 1'b1;
                if (in_valid && in_ready) begin
                    if (in_data == {IDX_WIDTH{1'b0}}) begin
                        peak_cnt <= peak_cnt + 1'b1;
                        if (peak_cnt + 1'b1 == NUM_PEAKS) state <= S_FINALIZE;
                    end else if (!acc_valid) begin
                        acc       <= in_data;
                        acc_valid <= 1'b1;
                        peak_cnt  <= peak_cnt + 1'b1;
                        if (peak_cnt + 1'b1 == NUM_PEAKS) state <= S_FINALIZE;
                    end else begin
                        reg_a    <= acc;
                        reg_b    <= in_data;
                        iter_cnt <= {ITER_W{1'b0}};
                        state    <= S_GCD;
                    end
                end
            end

            S_GCD: begin
                if (a_eq_b) begin
                    acc      <= reg_a;
                    peak_cnt <= peak_cnt + 1'b1;
                    state    <= (peak_cnt + 1'b1 == NUM_PEAKS) ? S_FINALIZE : S_RECV;
                end else if (iter_cnt == MAX_ITER) begin
                    timeout_err <= 1'b1;
                    acc         <= reg_a;
                    peak_cnt    <= peak_cnt + 1'b1;
                    state       <= (peak_cnt + 1'b1 == NUM_PEAKS) ? S_FINALIZE : S_RECV;
                end else begin
                    iter_cnt <= iter_cnt + 1'b1;
                    if (a_gt_b) reg_a <= diff_ab;
                    else        reg_b <= diff_ba;
                end
            end

            S_FINALIZE: begin
                out_data  <= acc_valid ? acc : {IDX_WIDTH{1'b0}};
                out_error <= (!acc_valid) || (acc < cfg_min_valid) || timeout_err;
                out_valid <= 1'b1;
                state     <= S_OUT;
            end
            
            S_OUT: begin
                if (out_valid && out_ready) begin
                    out_valid <= 1'b0;
                    done      <= 1'b1;
                    busy      <= 1'b0;
                    state     <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
