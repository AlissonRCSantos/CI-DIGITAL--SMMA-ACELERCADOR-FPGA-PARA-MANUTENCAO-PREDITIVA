// ============================================================================
// Module: LMS_Control_FSM_v4
// Description: Global Counter-Based Scheduler for a folded 8-tap LMS filter
//              with complete industrial-grade handshake interface.
//
// Scheduling Pipeline:
//   - Total cycle window: 26 clock cycles (Counter 0 to 25)
//   - Cycle 0: Dedicated sample load & accumulator reset (load_sample = 1, clear_acc = 1).
//              Shift register captures new sample in_x at end of Cycle 0.
//   - Cycles 1 to 8: Phase 1 FIR Filtering (Taps 0 to 7).
//                    rd_addr = counter - 1 (0 to 7). pe_sel = 0, pe_valid = 1.
//                    Partial products arrive at accumulator on cycles 4 to 11.
//   - Cycle 12: Accumulator output y(n) and raw error e(n) = d(n) - y(n) are ready.
//               Pulses 'valid_out' strobe for 1 cycle and asserts 'ready' = 1.
//   - Cycles 13 to 20: Phase 2 Weight Update (Taps 0 to 7).
//                      rd_addr = counter - 13 (0 to 7). pe_sel = 1, pe_valid = 1.
//   - Cycles 21 to 25: Pipeline drain for 5-cycle weight write-back latency.
// ============================================================================

`timescale 1ns / 1ps

module LMS_Control_FSM (
    input  wire         clk,          // System clock (50 MHz)
    input  wire         rst,          // Synchronous reset (active-high)
    
    // Handshake & Control Ports
    input  wire         start,        // Pulses high for 1 cycle to start operation
    input  wire         enable,       // Active high global module enable (clock-enable)
    input  wire         valid_in,     // Active high when input sample is valid
    
    output reg          ready,        // High when output is ready and stable
    output reg          busy,         // High during calculation window
    output reg          valid_out,    // Pulses high for 1 cycle when output is ready (strobe)

    // Control to Input Delay Line
    output reg          load_sample,  // Trigger to shift/load sample in delay line (1 cycle)
    output reg  [2:0]   rd_addr,      // Selects which tap x(n-k) to read

    // Control to Processing Element (PE)
    output reg          pe_sel,       // 0: Filtering (Fase 1), 1: Weight Update (Fase 2)
    output reg          pe_valid,     // Active high to enable processing inside PE

    // Control to Accumulator & Error Block
    output reg          clear_acc,    // Resets accumulator register before convolution starts

    // Control to Weight Storage
    output wire [2:0]   wr_addr,      // Write address for updated weight (driven continuously)
    output reg          wr_en_gate    // Global gate for weight write-enable (pipelined)
);

    // State definitions
    localparam STATE_IDLE      = 1'b0;
    localparam STATE_RUNNING   = 1'b1;

    reg        state;
    reg [4:0]  counter; // Counts from 0 to 25 to schedule all actions

    // --------------------------------------------------------------------
    // 1. Scheduler Counter & State Transition Logic (with Handshake)
    // --------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= STATE_IDLE;
            counter     <= 5'd0;
            busy        <= 1'b0;
            ready       <= 1'b1; // Initially ready to accept a transaction
            valid_out   <= 1'b0;
            load_sample <= 1'b0;
        end else if (enable) begin
            case (state)
                STATE_IDLE: begin
                    counter     <= 5'd0;
                    busy        <= 1'b0;
                    valid_out   <= 1'b0;
                    load_sample <= 1'b0;
                    
                    if (start && valid_in) begin
                        state       <= STATE_RUNNING;
                        busy        <= 1'b1;
                        ready       <= 1'b0; // Clears when starting new computation
                        load_sample <= 1'b1; // Trigger sample shift in delay line at Cycle 0
                    end
                end

                STATE_RUNNING: begin
                    load_sample <= 1'b0;
                    
                    // valid_out strobe is high for exactly 1 cycle at Cycle 12 (when y(n) and e(n) are ready)
                    if (counter == 5'd12) begin
                        valid_out   <= 1'b1;
                        ready       <= 1'b1; // Output sample is ready for external consumers
                    end else begin
                        valid_out   <= 1'b0;
                    end

                    if (counter == 5'd25) begin
                        state       <= STATE_IDLE;
                        counter     <= 5'd0;
                        busy        <= 1'b0;
                    end else begin
                        counter     <= counter + 1'b1;
                        busy        <= 1'b1;
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
            // --- CICLO 0: CARGA DE AMOSTRA E RESET DO ACUMULADOR ---
            if (counter == 5'd0) begin
                clear_acc = 1'b1;
                pe_valid  = 1'b0; // Multiplicador inativo enquanto shift_reg carrega
            end

            // --- FASE 1: CONVOLUÇÃO / FILTRAGEM FIR (Ciclos 1 a 8) ---
            else if (counter >= 5'd1 && counter <= 5'd8) begin
                rd_addr   = counter[2:0] - 3'd1; // Tap 0 (ciclo 1) até Tap 7 (ciclo 8)
                pe_sel    = 1'b0;                // MUX na PE aponta para Coeficientes
                pe_valid  = 1'b1;                // Injeta dado válido no pipeline
            end

            // --- CICLOS INTERMEDIÁRIOS: CÁLCULO E ESCALA DO ERRO (Ciclos 9 a 12) ---
            else if (counter >= 5'd9 && counter <= 5'd12) begin
                pe_valid = 1'b0; // Pausa PE enquanto produtos terminam de chegar ao acumulador
            end

            // --- FASE 2: ATUALIZAÇÃO DOS PESOS (Ciclos 13 a 20) ---
            else if (counter >= 5'd13 && counter <= 5'd20) begin
                rd_addr    = counter[2:0] - 3'd5; // Tap 0 (ciclo 13) até Tap 7 (ciclo 20)
                pe_sel     = 1'b1;                // MUX na PE aponta para Erro Escalado (mu * e)
                pe_valid   = 1'b1;                // Injeta cálculo de gradiente no pipeline
                wr_en_gate = 1'b1;                // Permite a gravação dos pesos na saída da PE
            end
        end
    end

    // --------------------------------------------------------------------
    // 3. Write Address Pipeline Routing (Flat Registers)
    // --------------------------------------------------------------------
    // Processing Element (PE) has an internal latency of 5 clock cycles
    // during weight update. wr_addr_pipe4 provides the 5-cycle delay line.
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
        end else if (enable) begin
            wr_addr_pipe0 <= rd_addr;
            wr_addr_pipe1 <= wr_addr_pipe0;
            wr_addr_pipe2 <= wr_addr_pipe1;
            wr_addr_pipe3 <= wr_addr_pipe2;
            wr_addr_pipe4 <= wr_addr_pipe3;
        end
    end

    assign wr_addr = wr_addr_pipe4; // Alinhado com a latência de 5 ciclos da PE

endmodule