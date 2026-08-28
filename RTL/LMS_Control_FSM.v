// ============================================================================
// Module: LMS_Control_FSM_v2
// Description: Global Counter-Based Scheduler for a folded 8-tap LMS filter,
//              incorporating the counter-based coordination concept from Lms5.pdf.
//
// Features:
//   - Uses flat pipeline registers for 'wr_addr_pipe' to prevent compiler/EDA
//     interpretation bugs and ensure 100% fail-safe synthesis.
//   - Employs a single driver continuous assignment for the 'wr_addr' output 
//     to avoid multiple-driver conflicts in simulation.
// ============================================================================

`timescale 1ns / 1ps

module LMS_Control_FSM (
    input  wire         clk,          // System clock (50 MHz)
    input  wire         rst,          // Synchronous reset (active-high)
    input  wire         sample_valid, // Pulses high for 1 cycle when new sample arrives

    // Control to Input Delay Line
    output reg  [2:0]   rd_addr,      // Selects which tap x(n-1-k) to read

    // Control to Processing Element (PE)
    output reg          pe_sel,       // 0: Filtering (Fase 1), 1: Weight Update (Fase 2)
    output reg          pe_valid,     // Active high to enable processing inside PE

    // Control to Accumulator & Error Block
    output reg          clear_acc,    // Resets accumulator register before convolution starts

    // Control to Weight Storage
    output wire [2:0]   wr_addr,      // Write address for updated weight (driven continuously)
    output reg          wr_en_gate,   // Global gate for weight write-enable (pipelined)
    
    // Status
    output reg          filter_busy   // High during the 17-cycle calculation window
);

    // State definitions
    localparam STATE_IDLE      = 1'b0;
    localparam STATE_RUNNING   = 1'b1;

    reg        state;
    reg [4:0]  counter; // Counts from 0 to 17 to schedule all actions

    // --------------------------------------------------------------------
    // 1. Scheduler Counter & State Transition Logic
    // --------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= STATE_IDLE;
            counter     <= 5'd0;
            filter_busy <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    counter <= 5'd0;
                    if (sample_valid) begin
                        state       <= STATE_RUNNING;
                        filter_busy <= 1'b1;
                    end else begin
                        filter_busy <= 1'b0;
                    end
                end

                STATE_RUNNING: begin
                    if (counter == 5'd17) begin
                        state       <= STATE_IDLE;
                        counter     <= 5'd0;
                        filter_busy <= 1'b0;
                    end else begin
                        counter     <= counter + 1'b1;
                        filter_busy <= 1'b1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------------------
    // 2. Control Signal Generation based on Counter Scheduler
    // --------------------------------------------------------------------
    always @(*) begin
        // Default outputs
        rd_addr    = 3'b000;
        pe_sel     = 1'b0;
        pe_valid   = 1'b0;
        clear_acc  = 1'b0;
        wr_en_gate = 1'b0;

        if (state == STATE_RUNNING) begin
            // --- FASE 1: CONVOLUÇÃO / FILTRAGEM FIR (Ciclos 0 a 7) ---
            if (counter >= 5'd0 && counter <= 5'd7) begin
                rd_addr   = counter[2:0]; // Varre x(n-1) até x(n-8)
                pe_sel    = 1'b0;         // MUX na PE aponta para Coeficientes
                pe_valid  = 1'b1;         // Injeta dado válido no pipeline
                
                // No primeiro ciclo (counter == 0), limpa o acumulador anterior
                if (counter == 5'd0) begin
                    clear_acc = 1'b1;
                end
            end

            // --- CICLO INTERMEDIÁRIO: CÁLCULO E ESCALA DO ERRO (Ciclo 8) ---
            else if (counter == 5'd8) begin
                pe_valid = 1'b0; // Pausa PE enquanto erro é registrado
            end

            // --- FASE 2: ATUALIZAÇÃO DOS PESOS (Ciclos 9 a 16) ---
            else if (counter >= 5'd9 && counter <= 5'd16) begin
                // Mapeia contagem [9..16] para endereços de tap [0..7]
                // rd_addr varre novamente as amostras correspondentes de entrada
                rd_addr    = counter[2:0] - 3'd1; 
                pe_sel     = 1'b1; // MUX na PE aponta para o Erro Escalado (mu * e)
                pe_valid   = 1'b1; // Injeta cálculo de gradiente no pipeline
                wr_en_gate = 1'b1; // Permite a gravação dos pesos na saída da PE
            end
        end
    end

    // --------------------------------------------------------------------
    // 3. Write Address Pipeline Routing (Flat Registers)
    // --------------------------------------------------------------------
    // The Processing Element (PE) has an internal latency of 5 clock cycles
    // during weight update (Phase 2). Thus, when we request update of weight
    // 'k' at cycle T, the updated weight is only ready at the PE output at T+5.
    // Flat registers are used to implement the 5-stage shift delay line.
    // --------------------------------------------------------------------
    reg [2:0] wr_addr_pipe0;
    reg [2:0] wr_addr_pipe1;
    reg [2:0] wr_addr_pipe2;
    reg [2:0] wr_addr_pipe3;
    reg [2:0] wr_addr_pipe4;

    always @(posedge clk) begin
        if (rst) begin
            wr_addr_pipe0 <= 3'd0;
            wr_addr_pipe1 <= 3'd0;
            wr_addr_pipe2 <= 3'd0;
            wr_addr_pipe3 <= 3'd0;
            wr_addr_pipe4 <= 3'd0;
        end else begin
            wr_addr_pipe0 <= rd_addr;
            wr_addr_pipe1 <= wr_addr_pipe0;
            wr_addr_pipe2 <= wr_addr_pipe1;
            wr_addr_pipe3 <= wr_addr_pipe2;
            wr_addr_pipe4 <= wr_addr_pipe3;
        end
    end

    // Route the pipelined write address directly to the output via wire assignment
    assign wr_addr = wr_addr_pipe4; // Alinhado com a latência de 5 ciclos da PE

endmodule