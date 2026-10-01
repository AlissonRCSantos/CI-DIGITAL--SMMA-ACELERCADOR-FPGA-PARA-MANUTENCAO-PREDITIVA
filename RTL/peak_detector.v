module peak_detector #(
    parameter integer FFT_N        = 64,        
    parameter integer IDX_WIDTH    = 6,         
    parameter integer MAG_WIDTH    = 16,        
    parameter integer NUM_PEAKS    = 3,        
    parameter integer SEARCH_START = 1,         
    parameter integer SEARCH_END   = (FFT_N/2) - 1 
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   start,
    output reg                    busy,
    output reg                    done,

    input  wire                   mag_valid,
    output wire                   mag_ready,
    input  wire [MAG_WIDTH-1:0]   mag_data,   

    input  wire [MAG_WIDTH-1:0]   cfg_threshold,

    output wire                   out_valid,
    input  wire                   out_ready,
    output wire [IDX_WIDTH-1:0]   out_data
);

    localparam [1:0]
        S_IDLE   = 2'd0,
        S_SCAN   = 2'd1,
        S_OUTPUT = 2'd2;

    reg [1:0] state;


    reg [IDX_WIDTH-1:0] bin_counter;      
    reg [MAG_WIDTH-1:0] mag_prev2;        
    reg [MAG_WIDTH-1:0] mag_prev1;        

 
    reg [MAG_WIDTH-1:0] mag_top0, mag_top1, mag_top2;
    reg [IDX_WIDTH-1:0] idx_top0, idx_top1, idx_top2;

    reg [1:0] out_ptr; 


    wire [IDX_WIDTH-1:0] cand_idx = bin_counter - 1'b1;

    wire is_local_max = (mag_prev1 >= mag_prev2) && (mag_prev1 >= mag_data);
    wire above_thr    = (mag_prev1 > cfg_threshold);
    wire in_range     = (cand_idx >= SEARCH_START) && (cand_idx <= SEARCH_END);
    wire accept_now   = mag_valid && mag_ready && (state == S_SCAN);
    wire is_candidate = accept_now && (bin_counter >= 1) &&
                        is_local_max && above_thr && in_range;

    assign mag_ready = (state == S_SCAN);
    assign out_valid = (state == S_OUTPUT);
    assign out_data  = (out_ptr == 2'd0) ? idx_top0 :
                        (out_ptr == 2'd1) ? idx_top1 : idx_top2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            bin_counter <= {IDX_WIDTH{1'b0}};
            mag_prev1   <= {MAG_WIDTH{1'b0}};
            mag_prev2   <= {MAG_WIDTH{1'b0}};
            mag_top0 <= {MAG_WIDTH{1'b0}}; idx_top0 <= {IDX_WIDTH{1'b0}};
            mag_top1 <= {MAG_WIDTH{1'b0}}; idx_top1 <= {IDX_WIDTH{1'b0}};
            mag_top2 <= {MAG_WIDTH{1'b0}}; idx_top2 <= {IDX_WIDTH{1'b0}};
            out_ptr  <= 2'd0;
        end else begin
            done <= 1'b0; 

            case (state)

            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy        <= 1'b1;
                    bin_counter <= {IDX_WIDTH{1'b0}};
                    mag_prev1   <= {MAG_WIDTH{1'b0}};
                    mag_prev2   <= {MAG_WIDTH{1'b0}};
                    mag_top0 <= {MAG_WIDTH{1'b0}}; idx_top0 <= {IDX_WIDTH{1'b0}};
                    mag_top1 <= {MAG_WIDTH{1'b0}}; idx_top1 <= {IDX_WIDTH{1'b0}};
                    mag_top2 <= {MAG_WIDTH{1'b0}}; idx_top2 <= {IDX_WIDTH{1'b0}};
                    out_ptr     <= 2'd0;
                    state       <= S_SCAN;
                end
            end

            // consome 1 amostra/ciclo; atualiza a janela deslizante;
            // se o bin do meio da janela (mag_prev1) for candidato,
            // insere-o na cascata top-3 (mux/comparadores em cadeia)
            S_SCAN: begin
                busy <= 1'b1;
                if (mag_valid && mag_ready) begin

                    if (is_candidate) begin
                        if (mag_prev1 > mag_top0) begin
                            mag_top2 <= mag_top1; idx_top2 <= idx_top1;
                            mag_top1 <= mag_top0; idx_top1 <= idx_top0;
                            mag_top0 <= mag_prev1; idx_top0 <= cand_idx;
                        end else if (mag_prev1 > mag_top1) begin
                            mag_top2 <= mag_top1; idx_top2 <= idx_top1;
                            mag_top1 <= mag_prev1; idx_top1 <= cand_idx;
                        end else if (mag_prev1 > mag_top2) begin
                            mag_top2 <= mag_prev1; idx_top2 <= cand_idx;
                        end
                    end

                    mag_prev2   <= mag_prev1;
                    mag_prev1   <= mag_data;
                    bin_counter <= bin_counter + 1'b1;

                    if (bin_counter == FFT_N-1) begin
                        state   <= S_OUTPUT;
                        out_ptr <= 2'd0;
                    end
                end
            end

            S_OUTPUT: begin
                if (out_valid && out_ready) begin
                    if (out_ptr == NUM_PEAKS-1) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        out_ptr <= out_ptr + 1'b1;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
