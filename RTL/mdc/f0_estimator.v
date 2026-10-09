module f0_estimator #(
    parameter integer FFT_N     = 64,  
    parameter integer IDX_WIDTH = 6,   
    parameter integer FS_WIDTH  = 20  
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  start,
    output reg                   busy,
    output reg                   done,

    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [IDX_WIDTH-1:0]  in_data,

    input  wire [FS_WIDTH-1:0]   cfg_fs,

    output reg                   out_valid,
    input  wire                  out_ready,
    output reg  [FS_WIDTH-1:0]           f0_int,  
    output reg  [IDX_WIDTH-1:0]          f0_frac  
);

    initial begin
        if ((FFT_N & (FFT_N - 1)) != 0) begin
            $display("ERRO f0_estimator: FFT_N=%0d nao e potencia de 2 - a divisao deixa de ser gratuita.", FFT_N);
            $finish;
        end
    end

    localparam [1:0]
        S_IDLE     = 2'd0,
        S_MUL      = 2'd1,
        S_FINALIZE = 2'd2,
        S_OUT      = 2'd3;

    reg [1:0] state;

    reg [IDX_WIDTH-1:0] k0_reg;
    reg [FS_WIDTH-1:0]  fs_reg;
    reg [IDX_WIDTH+FS_WIDTH-1:0] product; 

    assign in_ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            out_valid <= 1'b0;
            k0_reg    <= {IDX_WIDTH{1'b0}};
            fs_reg    <= {FS_WIDTH{1'b0}};
            product   <= {(IDX_WIDTH+FS_WIDTH){1'b0}};
            f0_int    <= {FS_WIDTH{1'b0}};
            f0_frac   <= {IDX_WIDTH{1'b0}};
        end else begin
            done <= 1'b0; // pulso de 1 ciclo

            case (state)

            // -----------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (in_valid && in_ready) begin
                    k0_reg <= in_data;
                    fs_reg <= cfg_fs;
                    busy   <= 1'b1;
                    state  <= S_MUL;
                end
            end


            S_MUL: begin
                product <= k0_reg * fs_reg;
                state   <= S_FINALIZE;
            end


            S_FINALIZE: begin
                f0_int    <= product[IDX_WIDTH+FS_WIDTH-1:IDX_WIDTH];
                f0_frac   <= product[IDX_WIDTH-1:0];
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
