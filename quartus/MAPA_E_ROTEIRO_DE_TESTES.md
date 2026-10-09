# SMMA — Mapa de interfaces e roteiro de testes no Quartus

Documento de apoio à verificação do SMMA na DE0-CV (Cyclone V `5CEBA4F23C7N`,
50 MHz). Tem três partes:

1. **Visão geral do fluxo** — o que entra e sai de cada bloco, com volume por janela.
2. **Mapa por bloco e por módulo** — portas, larguras, formatos e protocolo.
3. **Ordem de teste no Quartus** — sequência de baixo para cima, com o
   testbench, o critério de aprovação e o que conferir na síntese em cada passo.

Estado de partida (regressão com Icarus Verilog sobre o conteúdo atual de
`RTL/`, 03/10/2026): **27 de 28 testbenches do caminho de dados e do LMS
passam**. Só o `tb_LMS_Control_FSM` falha (8 divergências) — o diagnóstico está
na seção 4. Dos legados, `peak_detector`, `mdc_gcd` e `f0_estimator` passam;
`tb_autocorrelacao_yw` e `tb_pipeline_completo` não terminam (ver Fase 8).

---

## 0. Convenções comuns a todos os módulos

| item | convenção |
|---|---|
| Relógio | `clk` = `CLOCK_50` (50 MHz), domínio único, sem PLL |
| Reset | `rst` **síncrono, ativo em ALTO** (na placa, `KEY[0]` invertido no `SMMA_Top`). Exceção: `peak_detector`, `mdc_gcd`, `f0_estimator` usam `rst_n` (ativo em baixo) |
| Formato numérico | **Q1.15** com sinal (16 bits, faixa [-1, +1)), salvo indicação. Magnitudes são Q1.15 **sem sinal** (faixa [0, 2)) |
| Handshake de dados | `valid`/`ready`: a palavra é transferida no ciclo em que **os dois** estão em 1 |
| `start` | pulso de 1 ciclo que arma o bloco |
| `ready` | nível: bloco ocioso, aceita novo `start` |
| `busy` | nível: processando |
| `done` | pulso de 1 ciclo ao terminar (exceto `CNN_Control_FSM`, onde é nível até o próximo `start`) |
| `enable` | clock-enable global; em `SMMA_Top` está sempre em `1'b1` |

---

## 1. Visão geral do fluxo (uma janela)

```
Sample_Source ──8503 amostras Q1.15 @25,6 kHz──► FIR_Decimator
                                                     │ 1056 amostras Q1.15 @3,2 kHz
                     ┌───────────────────────────────┴───────────────┐  (fan-out "join": ready = AND)
                     ▼                                               ▼
              Frame_Builder                                  Feature_Temporal
     32 quadros × 64 amostras (salto 32)                    4 features: r_lms, rho1..rho3
                     │ 2048 amostras                                 │
                     ▼                                               │
                 FFT_Top  (32 transformadas)                         │
     64 bins/quadro: índice, Re, Im, |X| (÷16)                       │
     bins 32..63 aceitos e descartados                               │
                     │ 1024 magnitudes (32 bins × 32 quadros)        │
        ┌────────────┴─────────────┐  (fan-out "join")               │
        ▼                          ▼                                 │
 Feature_Spectral          FFT_Log2_Compress                         │
 8 features                1024 pixels (log2 Mitchell)               │
        │                          ▼                                 │
        │                 Spectrogram_Buffer                         │
        │                 1024 pixels transpostos (linha = bin)      │
        │                          ▼                                 │
        │                      CNN_Top ──► classe CNN + 4 scores     │
        ▼                                                            ▼
        └──────────── mux de 12 features (8 espectrais, depois 4 temporais) ──► ML_Tree_Classifier ──► classe árvore
```

| ligação | o que trafega | quantidade por janela |
|---|---|---|
| Sample_Source → FIR | amostra bruta Q1.15 (±32 g) | 8503 |
| FIR → Frame_Builder / Feature_Temporal | amostra decimada Q1.15 | 1056 (= 64 + 31×32) |
| Frame_Builder → FFT | amostra Q1.15 + marcas de início/fim de quadro | 32 × 64 = 2048 |
| FFT → Feature_Spectral / Log2 | `|X[k]|/16`, Q1.15 sem sinal, bins 0..31 | 32 × 32 = 1024 |
| Log2 → Spectrogram_Buffer | pixel 0..32767 | 1024 |
| Spectrogram_Buffer → CNN | pixel em ordem raster (linha = bin, coluna = quadro) | 1024 |
| Feature_Spectral → árvore | features 0..7 | 8 |
| Feature_Temporal → árvore | features 8..11 | 4 |
| árvore → painel | classe 2 bits + erro de percurso | 1 |
| CNN → painel | classe 2 bits + 4 scores Q1.15 | 1 |

**Classes:** 0 = normal, 1 = desbalanceamento, 2 = desalinhamento, 3 = rolamento.

---

## 2. Mapa por bloco (visão geral)

| bloco | entradas | saídas | latência / custo | submódulos |
|---|---|---|---|---|
| **Fonte** (`Sample_Source`) | `start`, `janela[3:0]` (SW), `out_ready` | stream Q1.15 (`out_valid`, `out_sample`), `classe_verdadeira[1:0]`, `classe_esperada[1:0]`, `busy`, `done` | 1 amostra a cada 1953 ciclos (25,6 kHz); com `MODO_RAPIDO=1`, o mais rápido que o consumidor aceitar. ROM de 12 × 8503 palavras (≈204 kB, M10K) | — |
| **FIR + decimação** (`FIR_Decimator`) | stream Q1.15 25,6 kHz, `limpa` | stream Q1.15 3,2 kHz, `overflow` | 63 ciclos de MAC por saída; 1 DSP; 1ª saída na 63ª amostra | — |
| **Montador de quadros** (`Frame_Builder`) | stream decimado | stream de quadros de 64 com `out_frame_ini`/`out_frame_fim` | baixa `in_ready` durante o despejo de cada quadro (64 ciclos); buffer 64×16 em LUT-RAM | — |
| **FFT** (`FFT_Top`) | 64 amostras complexas (`in_real`, `in_imag`=0) | 64 bins em ordem natural: `out_index`, `out_real`, `out_imag`, `out_mag` | ≈627 ciclos por transformada; 4 DSP; 1 M10K (dados) + ROM de twiddles | Control_FSM, Addr_Gen, Bit_Reverse, Memory, Twiddle_ROM, Butterfly (→FP_Mult_Unit), Magnitude |
| **Compressão log2** (`FFT_Log2_Compress`) | `|X[k]|` 16 bits sem sinal | pixel 16 bits (0..32767) | 1 ciclo; 0 DSP | — |
| **Buffer do espectrograma** (`Spectrogram_Buffer`) | 1024 pixels por quadro | 1024 pixels por linha (transposto) | 2 M10K | — |
| **Features espectrais** (`Feature_Spectral`) | 1024 magnitudes | 8 features Q1.15 (uma por transferência) | ≈1170 ciclos após o último bin; 0 DSP | Divider_Q15 |
| **Features temporais** (`Feature_Temporal`) | 1056 amostras decimadas + `in_last` | 4 features Q1.15 | 20 multiplicações por amostra num único multiplicador; 4 divisões no fim | Divider_Q15 |
| **Árvore de decisão** (`ML_Tree_Classifier`) | 12 features Q1.15 em sequência | `out_class[1:0]`, `out_error` | 12 ciclos de carga + até 9 de percurso; ROM de 141 nós (564 B) | — |
| **CNN** (`CNN_Top`) | 1024 pixels Q1.15 | `out_class[1:0]`, `out_scores[63:0]`, `out_features[127:0]` | ≈9.332 ciclos por imagem; 9 DSP (8 conv + 1 densa) | Control_FSM, Line_Buffer, Conv_Layer (→MAC, ReLU, Weight_ROM), MaxPool, Dense_Classifier (→MAC, ReLU, Weight_ROM) |
| **LMS** (`LMS_Filter_Top`) — fora do caminho de dados | `in_x`, `in_d` Q1.15 | `out_y`, `out_error`, pesos `w0..w7` | janela de 26 ciclos por amostra; 1 multiplicador | Control_FSM, Input_Delay_Line, Processing_Element (→FP_Mult, FP_Arith), Accumulator_Error_Scale, Weight_Storage |
| **Topo** (`SMMA_Top`) | `CLOCK_50`, `KEY[1:0]`, `SW[9:0]` | `LEDR[9:0]`, `HEX0..HEX5` | 332 ms por janela em tempo real | todos os acima, exceto LMS e legados |

---

## 3. Mapa porta a porta

Notação: **E** = entrada, **S** = saída. Larguras com os parâmetros padrão.

### 3.1 Aritmética comum

**`FP_Mult_Unit`** — multiplicador Q com sinal, arredondamento e saturação. Latência **3 ciclos**, 1 DSP.
Parâmetros: `WIDTH_A/B/Y=16`, `FRAC_A/B/Y=15`, `ROUNDING=1`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `clk`, `rst` | E | 1 | |
| `in_A`, `in_B` | E | 16 s | operandos Q1.15 |
| `out_Y` | S | 16 s | produto Q1.15 (3 ciclos depois) |

**`FP_Arith_Unit`** — somador/subtrator Q com saturação. Latência **2 ciclos**.
Parâmetros: `INT_A/B/Y=1`, `FRAC_A/B/Y=15`, `ROUNDING=1` (o testbench usa Q4.14).

| porta | dir | largura | descrição |
|---|---|---|---|
| `add_sub` | E | 1 | 0 = A+B, 1 = A−B |
| `in_A`, `in_B` | E | INT+FRAC+1 | operandos |
| `out_Y` | S | INT_Y+FRAC_Y+1 | resultado saturado |

**`Divider_Q15`** — divisor sem sinal por restauração, `q = (num<<15)/den` saturado em 0x7FFF. ~16 ciclos, 0 DSP.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | E | 1 | pulso: inicia divisão |
| `num`, `den` | E | 32 | sem sinal |
| `ready` | S | 1 | aceita nova divisão |
| `done` | S | 1 | pulso: quociente válido |
| `quociente` | S | 16 | Q1.15 sem sinal |
| `div_zero` | S | 1 | den = 0 (saída saturada) |

### 3.2 LMS (fora do caminho de dados; o `Feature_Temporal` reimplementa o preditor)

**`LMS_Control_FSM`** — escalonador por contador, 26 ciclos por amostra: ciclo 0 carga; 1–8 filtragem; 12 saída; 13–20 atualização; 21–25 esvaziamento.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `enable`, `valid_in` | E | 1 | inicia quando `start && valid_in` |
| `ready`, `busy`, `valid_out` | S | 1 | handshake (`valid_out` sobe no contador 13, registrado) |
| `load_sample` | S | 1 | → Delay_Line: desloca a amostra (ciclo 0) |
| `rd_addr` | S | 3 | tap lido (Delay_Line e Weight_Storage) |
| `pe_sel` | S | 1 | 0 = filtragem, 1 = atualização de pesos |
| `pe_valid` | S | 1 | habilita o PE |
| `clear_acc` | S | 1 | zera o acumulador (ciclo 0) |
| `wr_addr` | S | 3 | endereço de escrita = `rd_addr` atrasado 5 ciclos |
| `wr_en_gate` | S | 1 | janela de atualização (13–20); **não é usado** pelo `LMS_Filter_Top` |

**`LMS_Input_Delay_Line`**

| porta | dir | largura | descrição |
|---|---|---|---|
| `sample_valid` | E | 1 | desloca a linha |
| `in_x` | E | 16 s | nova amostra x(n) |
| `rd_addr` | E | 3 | seleciona x(n−1−k) |
| `out_x_k` | S | 16 s | tap selecionado (combinacional) |
| `out_d` | S | 16 s | sinal desejado d(n) registrado |

**`LMS_Weight_Storage`** — banco de 8 pesos, leitura combinacional.

| porta | dir | largura | descrição |
|---|---|---|---|
| `rd_addr` | E | 3 | peso lido |
| `rd_data` | S | 16 s | w_k(n) |
| `we`, `wr_addr`, `wr_data` | E | 1 / 3 / 16 s | escrita de w_k(n+1) (`we` = `valid_w_next` do PE) |
| `w0..w7` | S | 16 s cada | depuração |

**`LMS_Processing_Element`** — 1 multiplicador + 1 somador. Filtragem: 3 ciclos; atualização: 5 ciclos.

| porta | dir | largura | descrição |
|---|---|---|---|
| `sel`, `valid_in` | E | 1 | modo e validade |
| `in_x`, `in_w`, `in_u_e` | E | 16 s | x(n−k), w_k(n), μ·e(n) |
| `out_y_part`, `valid_y_part` | S | 16 s / 1 | produto parcial w·x (3 ciclos) |
| `out_w_next`, `valid_w_next` | S | 16 s / 1 | w + μ·e·x (5 ciclos) |

**`LMS_Accumulator_Error_Scale`** — `MU_SHIFT` padrão 4 (o topo usa 3).

| porta | dir | largura | descrição |
|---|---|---|---|
| `clear_acc` | E | 1 | zera |
| `valid_y_part`, `in_y_part` | E | 1 / 16 s | produtos do PE |
| `in_d` | E | 16 s | d(n) |
| `out_y`, `out_error`, `out_u_e` | S | 16 s | y(n), e(n), μ·e(n) |
| `valid_u_e` | S | 1 | pulso: erro pronto |

**`LMS_Filter_Top`** — `start`, `enable`, `valid_in`, `in_x`, `in_d` (E); `ready`, `busy`, `valid_out`, `out_y`, `out_error`, `w0..w7` (S).

### 3.3 Front-end

**`Sample_Source`** — Parâmetros: `N_JANELAS=12`, `N_AMOSTRAS=8503`, `DIV_TAXA=1953`, `MODO_RAPIDO=0`, `ARQ_AMOSTRAS`, `ARQ_ROTULOS`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | E | 1 | inicia a janela selecionada |
| `janela` | E | 4 | 0..11 (`SW[3:0]`) |
| `busy`, `done` | S | 1 | reproduzindo / fim da janela |
| `out_ready` | E | 1 | contrapressão do FIR |
| `out_valid`, `out_sample` | S | 1 / 16 s | amostra Q1.15 (±32 g) |
| `classe_verdadeira` | S | 2 | rótulo do dataset |
| `classe_esperada` | S | 2 | previsão do modelo Python |

**`FIR_Decimator`** — 63 taps, ÷8, `ACC_W=40`, `ARQ_COEF="vetores/fir_coef.hex"`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `limpa` | E | 1 | zera linha de atraso e fase |
| `in_valid`, `in_ready`, `in_sample` | E/S/E | 1/1/16 s | 25,6 kHz |
| `out_ready`, `out_valid`, `out_sample` | E/S/S | 1/1/16 s | 3,2 kHz |
| `overflow` | S | 1 | alguma saída saturou (vai para o `HEX3`) |

**`Frame_Builder`** — `NFFT=64`, `HOP=32`, `N_QUADROS=32`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `ready`, `busy`, `done` | E/S/S/S | 1 | `done` após os 32 quadros |
| `in_valid`, `in_ready`, `in_sample` | E/S/E | 1/1/16 s | amostras decimadas |
| `out_ready`, `out_valid`, `out_sample` | E/S/S | 1/1/16 s | quadros para a FFT |
| `out_frame_ini` / `out_frame_fim` | S | 1 | 1ª / 64ª amostra do quadro |

### 3.4 FFT

**`FFT_Top`** — `LOG2N=6`, `SCALE_MASK=6'b001111` (ganho total 1/16).

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `enable` | E | 1 | `in_ready` só sobe **depois** do `start` |
| `ready`, `busy`, `done` | S | 1 | |
| `in_valid`, `in_ready` | E/S | 1 | |
| `in_real`, `in_imag` | E | 16 s | x[n] (imag = 0 no SMMA) |
| `out_ready` | E | 1 | 0 congela o pipeline de saída |
| `out_valid`, `out_index` | S | 1 / 6 | bin k = 0..63, ordem natural |
| `out_real`, `out_imag` | S | 16 s | X[k]/16 |
| `out_mag` | S | 16 | \|X[k]\|/16 (alpha-max + beta-min), sem sinal |
| `stage_dbg` | S | 3 | estágio corrente 1..6 |

Submódulos:

| módulo | entradas | saídas | natureza |
|---|---|---|---|
| `FFT_Bit_Reverse` | `index_in[5:0]` | `index_out[5:0]` | combinacional (só fios) |
| `FFT_Addr_Gen` | `stage[2:0]`, `bfly_idx[4:0]` | `addr_p[5:0]`, `addr_q[5:0]`, `tw_addr[4:0]` | combinacional |
| `FFT_Twiddle_ROM` | `rd_en`, `rd_addr[4:0]` | `w_real`, `w_imag` (16 s): cos e −sen(2πk/64) | leitura registrada, 1 ciclo |
| `FFT_Memory` | porta A e B: `addr[5:0]`, `we`, `din[31:0]` = {imag, real} | `a_dout`, `b_dout` [31:0] | RAM dual-port 64×32, leitura registrada (1 M10K) |
| `FFT_Butterfly` | `in_valid`, `scale_en`, `a_*`, `b_*`, `w_*` (real/imag, 16 s) | `out_valid`, `p_*`, `q_*` (16 s): P = (A+WB)·k, Q = (A−WB)·k | pipeline de 6 ciclos, 4 DSP |
| `FFT_Magnitude` | `en`, `in_valid`, `in_real`, `in_imag` | `out_valid`, `out_mag[15:0]` | 2 ciclos, 0 DSP |
| `FFT_Control_FSM` | `start`, `enable`, `in_valid`, `out_ready` | handshake (`in_ready`, `busy`, `done`, `ready`); memória (`mem_a/b_addr`, `mem_a/b_we`, `mem_sel_load`); ROM (`tw_addr`, `tw_rd_en`); butterfly (`bf_in_valid`, `bf_scale_en`); descarga (`unload_rd`, `unload_index`, `out_pipe_adv`); `stage_out` | estados LOAD → estágios (leitura em fase par, escrita em fase ímpar) → DRAIN → UNLOAD → FLUSH |

**`FFT_Log2_Compress`**

| porta | dir | largura | descrição |
|---|---|---|---|
| `en` | E | 1 | clock-enable (no topo = `in_ready` do buffer) |
| `in_valid`, `in_mag` | E | 1 / 16 | \|X\| sem sinal |
| `out_valid`, `out_pixel` | S | 1 / 16 | `e·2048 + mantissa`, saturado em 32767 |

### 3.5 Caminho da árvore

**`Feature_Spectral`** — `N_BINS=32`, `N_QUADROS=32`, `ACC_W=24`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `ready`, `busy`, `done` | E/S/S/S | 1 | |
| `in_valid`, `in_ready`, `in_mag` | E/S/E | 1/1/16 | bin a bin, quadro a quadro (1024 valores) |
| `out_ready`, `out_valid`, `out_feature` | E/S/S | 1/1/16 s | 8 features, uma por transferência |

Ordem de saída: 0 `r_1x`, 1 `r_2x`, 2 `r_3x`, 3 `r_banda1` (bins 4–7), 4 `r_banda2` (8–15), 5 `r_banda3` (16–31), 6 `log2E`, 7 `centroide`.

**`Feature_Temporal`** — `N_TAPS=8`, `MU_SHIFT=3`, `N_LAGS=3`, `ACC_W=48`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `ready`, `busy`, `done` | E/S/S/S | 1 | |
| `in_valid`, `in_ready`, `in_sample` | E/S/E | 1/1/16 s | 1056 amostras decimadas |
| `in_last` | E | 1 | marca a última amostra (contador no `SMMA_Top`) |
| `out_ready`, `out_valid`, `out_feature` | E/S/S | 1/1/16 s | 4 features |

Ordem de saída: 8 `r_lms` = E[e²]/E[x²], 9 `rho1`, 10 `rho2`, 11 `rho3` = r[k]/r[0].

**`ML_Tree_Classifier`** — `N_FEATURES=12`, `N_NOS=153` no padrão (o topo passa **141**), `PROF_MAX=9`, `ARQ_ROM="vetores/arvore.hex"`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `enable` | E | 1 | |
| `ready`, `busy`, `done` | S | 1 | |
| `in_valid`, `in_ready`, `in_feature` | E/S/E | 1/1/16 s | 12 features em sequência, na ordem 0..11 |
| `out_ready` | E | 1 | |
| `out_valid`, `out_class` | S | 1 / 2 | classe 0..3 |
| `out_error` | S | 1 | percurso não terminou em folha |

Formato do nó (32 bits): bit 31 = folha; folha → `[1:0]` classe; interno → `[30:27]` feature, `[26:11]` limiar Q1.15, `[10:3]` filho direito (o esquerdo é sempre índice+1). Regra: `feature <= limiar` → esquerda.

### 3.6 Caminho da CNN

**`Spectrogram_Buffer`** — `N_BINS=32`, `N_QUADROS=32`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `ready`, `busy`, `done` | E/S/S/S | 1 | `done` só depois de a imagem ser **drenada** |
| `in_valid`, `in_ready`, `in_pixel` | E/S/E | 1/1/16 | entra por quadro |
| `out_ready`, `out_valid`, `out_pixel` | E/S/S | 1/1/16 | sai por linha (raster: linha = bin, coluna = quadro) |

**`CNN_Top`** — `IMG_W=IMG_H=32`, `NUM_FILTERS=8`, `NUM_CLASSES=4`, `ACC_W=40`, `GAP_SHIFT=8`.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start`, `enable` | E | 1 | |
| `in_valid`, `in_ready`, `in_pixel` | E/S/E | 1/1/16 s | 1024 pixels |
| `busy`, `ready`, `done`, `valid_out` | S | 1 | `valid_out` = pulso de 1 ciclo |
| `out_class` | S | 2 | argmax |
| `out_scores` | S | 64 | 4 × Q1.15 (classe 0 nos bits baixos) |
| `out_features` | S | 128 | 8 saídas do GAP (depuração) |

Submódulos (tensores: 32×32×1 → conv 32×32×8 → pool 16×16×8 → GAP 8 → densa 4 → classe):

| módulo | entradas | saídas | natureza |
|---|---|---|---|
| `CNN_ReLU` | `in_acc[39:0]` (Q?.30) | `out_y[15:0]` Q1.15 | combinacional: reescala + satura + ReLU (`ENABLE_RELU=0` só satura) |
| `CNN_MAC_Unit` | `en`, `first`, `last`, `init_acc[39:0]` (bias<<15), `in_a`, `in_b` (16 s) | `out_acc[39:0]`, `out_valid` | 3 ciclos, 1 DSP |
| `CNN_Weight_ROM` | `tap_addr[3:0]`, `dense_addr[4:0]` (classe·8+feature), `dense_bias_addr[1:0]` | `conv_w[127:0]` (8 pesos do tap), `conv_bias[127:0]`, `dense_w`, `dense_bias` (16 s) | combinacional (LUTs), gerada por `05_exportar_rtl.py` |
| `CNN_Line_Buffer` | `start`, `push_en`, `win_ack`, `in_pixel` | `out_win[143:0]` (janela 3×3), `win_valid`, `need_pixel`, `last_push`, `out_row/out_col[5:0]` | 33×33 = 1089 passos (65 de padding) |
| `CNN_Conv_Layer` | `win_valid`, `win_data[143:0]` | `win_ready`, `out_valid`, `out_data[127:0]` (8 canais) | 8 MAC em paralelo, 9 ciclos por janela |
| `CNN_MaxPool` | `start`, `in_valid`, `in_data[127:0]` | `out_valid`, `out_data[127:0]` | 2×2 / stride 2, em streaming |
| `CNN_Dense_Classifier` | `start`, `in_valid`, `in_data[127:0]`, `run` | `out_valid`, `out_class[1:0]`, `out_scores[63:0]`, `out_features[127:0]` | GAP (>>8) + 1 MAC × 32 + argmax |
| `CNN_Control_FSM` | `start`, `enable`, `in_valid`, `need_pixel`, `last_push`, `conv_ready`, `pool_out_valid`, `dense_done` | `in_ready`, `busy`, `ready`, `done`, `valid_out`, `frame_start`, `push_en`, `dense_run` | IDLE → STREAM → DRAIN → DENSE → FINISH |

### 3.7 Topo (`SMMA_Top`)

| porta | dir | largura | função |
|---|---|---|---|
| `CLOCK_50` | E | 1 | relógio |
| `KEY[0]` | E | 1 | reset (ativo em baixo, sincronizado em 2 FF) |
| `KEY[1]` | E | 1 | dispara uma janela (borda) |
| `SW[3:0]` | E | 4 | janela 0..11 |
| `SW[9]` | E | 1 | `LEDR[3:0]` passa a mostrar `cnn_scores[3:0]` — atenção: são os 4 LSB do score da **classe 0**, não um resumo dos 4 scores (ver nota abaixo) |
| `HEX0` / `HEX1` / `HEX2` | S | 7 | classe árvore / CNN / verdadeira |
| `HEX3` | S | 7 | `E` = erro de percurso ou overflow do FIR |
| `HEX5:HEX4` | S | 14 | índice da janela |
| `LEDR[3:0]` | S | 4 | classe da árvore em one-hot |
| `LEDR[4]` / `[5]` / `[6]` | S | 1 | árvore certa / CNN certa / as duas concordam |
| `LEDR[7]` | S | 1 | previsão do modelo Python = rótulo |
| `LEDR[8]` / `[9]` | S | 1 | ocupado / resultado válido |

> **Nota sobre `SW[9]`.** `cnn_scores` tem 64 bits (4 scores × 16). O
> `assign LEDR[3:0] = SW[9] ? cnn_scores[3:0] : arv_onehot;` mostra só os 4 bits
> menos significativos do score da classe 0, que na prática são ruído. Se a
> intenção é "ver o quanto a CNN hesitou", algo como o bit de sinal de cada
> score (`{cnn_scores[63], cnn_scores[47], cnn_scores[31], cnn_scores[15]}`) ou
> o one-hot da classe da CNN mostraria isso.

FSM global: `E_PARADO → E_ARRANCA` (um único pulso `r_arranca` para Source, Frame_Builder, Feature_Spectral, Feature_Temporal, Spectrogram_Buffer e CNN) `→ E_ADQUIRE` (até `fb_done`) `→ E_DECIDE` (espera árvore **e** CNN) `→ E_PRONTO → E_PARADO`.

### 3.8 Legados (fora do `SMMA.qsf`)

| módulo | entradas | saídas | observação |
|---|---|---|---|
| `peak_detector` | `start`, `mag_valid`, `mag_data[15:0]`, `cfg_threshold[15:0]`, `out_ready` | `mag_ready`, `out_valid`, `out_data[5:0]` (índice do pico), `busy`, `done` | `rst_n` |
| `mdc_gcd` | `start`, `in_valid`, `in_data[5:0]` (picos), `cfg_min_valid[5:0]`, `out_ready` | `in_ready`, `out_valid`, `out_data[5:0]` (k0), `out_error`, `busy`, `done` | `rst_n` |
| `f0_estimator` | `start`, `in_valid`, `in_data[5:0]` (k0), `cfg_fs[19:0]`, `out_ready` | `in_ready`, `out_valid`, `f0_int[19:0]`, `f0_frac[5:0]`, `busy`, `done` | `rst_n` |
| `autocorrelacao_yw` | `reset`, `lms_valid`, `lms_data[15:0]` (Q4.12) | `busy`, `r_valid`, `r_index[2:0]`, `r_data[15:0]` | depende de `fixed_point_divider`, que só existe em `fixed_point_divider (1).v` |

---

## 4. Ordem de teste no Quartus

A regra é **de baixo para cima**: nenhum módulo é testado antes de tudo o que
ele instancia já ter passado. Dentro de cada fase, segue-se o sentido do dado.

Cada passo tem duas verificações:

- **(S) Síntese:** módulo como top-level → *Analysis & Synthesis* → conferir
  mensagens e recursos (procedimento na seção 5.1).
- **(T) Testbench:** simulação no Questa/ModelSim (seção 5.2). O critério de
  aprovação é o que o testbench imprime.

### Fase 1 — Aritmética comum (base do LMS, da FFT e das features)

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 1.1 | `FP_Mult_Unit` | — | `tb_FP_Mult_Unit` | `Failures ([FAIL]) : 0`, latência de 3 ciclos | 1 DSP |
| 1.2 | `FP_Arith_Unit` | — | `tb_FP_Arith_Unit` | soma, subtração e saturação (Q4.14) sem falha | 0 DSP |
| 1.3 | `Divider_Q15` | — | `tb_Divider_Q15` | bordas + varredura aleatória, inclusive den = 0 | 0 DSP |

### Fase 2 — Módulos do LMS

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 2.1 | `LMS_Control_FSM` | — | `tb_LMS_Control_FSM` | **falha hoje** (ver nota abaixo) | sem latches |
| 2.2 | `LMS_Input_Delay_Line` | — | `tb_LMS_Input_Delay_Line` | deslocamento e leitura endereçada corretos | registradores, sem RAM |
| 2.3 | `LMS_Weight_Storage` | — | `tb_LMS_Weight_Storage` | escrita/leitura dos 8 pesos | leitura combinacional |
| 2.4 | `LMS_Processing_Element` | 1.1, 1.2 | `tb_LMS_Processing_Element` | latências 3 (filtro) e 5 (atualização), back-to-back | 1 DSP |
| 2.5 | `LMS_Accumulator_Error_Scale` | — | `tb_LMS_Accumulator_Error_Scale` | y(n), e(n), μ·e(n) e strobe `valid_u_e` | |
| 2.6 | `LMS_Filter_Top` | 2.1–2.5 | `tb_LMS_Filter_Top` | identificação de sistema com 400 amostras converge | 1 DSP no total |

> **Nota sobre o 2.1.** As 8 divergências (contadores 6 a 13) vêm da tabela de
> valores esperados do testbench, não de um defeito que afete o filtro:
> (a) nos contadores 6–13 o testbench espera `wr_addr` = `rd_addr` atrasado
> **4** ciclos, mas nas linhas 19–25 ele espera atraso de **5**, que é o que a
> FSM faz e o que o PE exige; nessa faixa `wr_addr` não é usado (nenhuma escrita
> acontece). (b) O testbench espera `valid_out`/`ready` no contador 12, mas a
> FSM os **registra** quando o contador vale 12, então eles aparecem no 13; o
> comentário da própria FSM ("ciclo 12") é que está impreciso. Como o
> `tb_LMS_Filter_Top` passa e o `LMS_Filter_Top` escreve os pesos com o
> `valid_w_next` do PE (e não com `wr_en_gate`), basta corrigir as linhas 6–13
> do testbench ou adiantar o `valid_out` para o contador 11. A primeira opção é
> a segura.

### Fase 3 — Front-end

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 3.1 | `Sample_Source` (+ FIR a jusante) | — | `tb_Sample_Source` | 8503 amostras por janela, conteúdo = ROM, rótulos certos, intervalo de 1953 ciclos com `MODO_RAPIDO=0` | **ROM em M10K** (≈1,6 Mbit); nenhum aviso de arquivo de inicialização não encontrado |
| 3.2 | `FIR_Decimator` | — | `tb_FIR_Decimator` | bit a bit contra `fir_teste.hex`, 1 saída a cada 8, 1ª saída na amostra 62 | 1 DSP; coeficientes carregados |
| 3.3 | `Frame_Builder` | — | `tb_Frame_Builder` | quadro f contém as amostras f·32 … f·32+63, nenhuma perdida | buffer em LUT-RAM |

### Fase 4 — FFT

Os submódulos da FFT **não têm testbench próprio**; são cobertos pelo
`tb_FFT_Top`. Para eles, faça só a síntese e confira o RTL Viewer.

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 4.1 | `FFT_Bit_Reverse` | — | (S) apenas | — | 0 LUTs (só fios) |
| 4.2 | `FFT_Addr_Gen` | — | (S) apenas | — | ~30 LUTs, 0 registradores |
| 4.3 | `FFT_Twiddle_ROM` | — | (S) apenas | — | ROM 32×32 |
| 4.4 | `FFT_Memory` | — | (S) apenas | — | **1 M10K** inferido (dual-port) |
| 4.5 | `FFT_Butterfly` | 1.1 | (S) apenas | — | 4 DSP |
| 4.6 | `FFT_Magnitude` | — | (S) apenas | — | 0 DSP |
| 4.7 | `FFT_Control_FSM` | 4.1, 4.2 | (S) apenas | — | sem latches |
| 4.8 | `FFT_Top` | 4.1–4.7 | `tb_FFT_Top` | 7 casos (impulso, DC, tom bin 4, tom bin 13, motor, contrapressão, reset no meio) dentro de 2 LSB da DFT ideal | 4 DSP, 1 M10K |
| 4.9 | `FFT_Log2_Compress` | — | `tb_FFT_Log2_Compress` | as 65.536 entradas, monotonicidade e continuidade | 0 DSP |

### Fase 5 — Features e árvore

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 5.1 | `Feature_Spectral` | 1.3 | `tb_Feature_Spectral` | 8 janelas reais, bit a bit | 0 DSP (multiplicador 5×16 em LUT) |
| 5.2 | `Feature_Temporal` | 1.3 | `tb_Feature_Temporal` | 6 janelas reais, bit a bit | 1 DSP |
| 5.3 | `ML_Tree_Classifier` | — | `tb_ML_Tree_Classifier` | classe = modelo quantizado em todos os casos de `clf_teste.hex`; contrapressão e reuso (o testbench instancia com `N_NOS=153` sobre um `.hex` de 141 linhas: aviso de `$readmemh` com menos palavras é esperado) | 0 DSP; ROM de 141 nós carregada |

### Fase 6 — CNN

| # | módulo | depende de | testbench | aprovar quando | conferir na síntese |
|---|---|---|---|---|---|
| 6.1 | `CNN_ReLU` | — | `tb_CNN_ReLU` | reescala, saturação, ReLU on/off | combinacional |
| 6.2 | `CNN_MAC_Unit` | — | `tb_CNN_MAC_Unit` | 9 produtos + bias, acumulações seguidas sem bolha, latência 3 | 1 DSP |
| 6.3 | `CNN_Weight_ROM` | — | `tb_CNN_Weight_ROM` | 116 pesos = `rom_pesos.hex` | LUTs |
| 6.4 | `CNN_Line_Buffer` | — | `tb_CNN_Line_Buffer` | 16 janelas da imagem 4×4, bordas e cantos | |
| 6.5 | `CNN_Conv_Layer` | 6.1–6.3 | `tb_CNN_Conv_Layer` | 4 casos = `conv_esperado.hex`, 9 ciclos/janela | 8 DSP |
| 6.6 | `CNN_MaxPool` | — | `tb_CNN_MaxPool` | 2 canais com ordenações opostas | 0 DSP |
| 6.7 | `CNN_Dense_Classifier` | 6.1–6.3 | `tb_CNN_Dense_Classifier` | GAP, scores e classe = `dense_esperado.hex` | 1 DSP |
| 6.8 | `CNN_Control_FSM` | — | `tb_CNN_Control_FSM` | 8 propriedades (contrapressão, padding, pulsos de 1 ciclo) | sem latches |
| 6.9 | `Spectrogram_Buffer` | — | `tb_Spectrogram_Buffer` | transposição das 1024 posições | 2 M10K |
| 6.10 | `CNN_Top` | 6.1–6.8 | `tb_CNN_Top` | 8 espectrogramas reais bit a bit (features, scores, classe); ≈9.300 ciclos/imagem | 9 DSP |

### Fase 7 — Integração e placa

| # | etapa | aprovar quando |
|---|---|---|
| 7.1 | `tb_SMMA_Top` (`MODO_RAPIDO=1`, `N_NOS=141`) | árvore = modelo Python nas 12 janelas; 11/12 contra o rótulo (a janela 8, `4Nm_Normal`, erra no modelo); janelas em sequência sem reset |
| 7.2 | Compilação completa do `SMMA_Top` (`MODO_RAPIDO=0`) | Fitter fecha; **Timing Analyzer**: slack ≥ 0 a 50 MHz; M10K usados pela ROM do dataset; nenhum aviso de `.hex` não encontrado; DSP ≈ 4 (FFT) + 9 (CNN) + 1 (FIR) + 1 (Feature_Temporal) |
| 7.3 | Pinagem | importar o `DE0_CV.qsf` da Terasic e conferir os `HEX` (hoje não atribuídos) |
| 7.4 | Placa | para cada janela 0..11: `KEY[1]`, `LEDR[8]` acende por ~332 ms, depois `LEDR[9]`; conferir `HEX0..HEX2` e `LEDR[4]` |

### Fase 8 — Legados (opcional)

`peak_detector_tb`, `mdc_gcd_tb` e `f0_estimator_tb` passam (testados
isoladamente com Icarus). O `tb_autocorrelacao_yw` e o `tb_pipeline_completo`
não terminaram em 15 minutos. Três problemas já identificados: leem
`amostras_lms.txt`, mas o arquivo no repositório se chama `amostras_lms` (sem
extensão); o `tb_autocorrelacao_yw` termina com `$stop`; e é preciso compilar
`fixed_point_divider (1).v` (e `gauss_jordan_inv (2).v` para o pipeline)
explicitamente. Mesmo corrigindo o nome do arquivo, o `tb_autocorrelacao_yw`
não terminou em 60 s, então há mais alguma coisa travando — precisa de
investigação, mas esses módulos estão fora do caminho de dados.

---

## 5. Como executar cada passo

### 5.1 Síntese de um módulo isolado (Quartus)

1. Abra `quartus/SMMA.qpf`. Para módulos que não estão no `.qsf` (LMS,
   legados), adicione o arquivo em *Project → Add/Remove Files in Project*.
2. Na aba **Files** do *Project Navigator*, clique com o botão direito no
   arquivo → **Set as Top-Level Entity**.
3. **Processing → Start → Start Analysis & Synthesis**. **Não** rode o Fitter
   em submódulos: portas largas (ex.: `out_data[127:0]` da conv) passam do
   número de pinos do dispositivo.
4. Confira em *Messages*:
   - `Warning (10240)` — latch inferido: não deve aparecer;
   - `Warning (10230)` — valor truncado: avaliar caso a caso;
   - aviso de arquivo de inicialização de memória não encontrado: **não pode
     aparecer** em `Sample_Source`, `FIR_Decimator` e `ML_Tree_Classifier`
     (a ROM seria inferida zerada e o projeto compilaria sem erro).
5. Confira *Compilation Report → Analysis & Synthesis → Resource Usage
   Summary* (DSP e bits de memória) contra a coluna "conferir na síntese".
6. *Tools → Netlist Viewers → RTL Viewer* para ver as portas e a hierarquia.
7. Ao terminar, volte o top-level para `SMMA_Top`.

### 5.2 Simulação (Questa Intel FPGA / ModelSim)

O ponto que mais dá problema é o caminho dos `.hex`: os testbenches abrem
`vetores/...` com caminho **relativo à pasta `RTL/`**. O fluxo do Quartus
(*Tools → Run Simulation Tool → RTL Simulation*) roda em
`quartus/simulation/questa/`, onde esses caminhos não existem. O mais simples é
rodar o Questa direto da pasta `RTL/`:

```tcl
# no Transcript do Questa/ModelSim
cd {C:/Users/Sara/Desktop/CI DIGITAL - CEPEDI/PBL/CI-DIGITAL--SMMA-ACELERCADOR-FPGA-PARA-MANUTENCAO-PREDITIVA/RTL}
vlib work
# compila tudo, menos as cópias com espaço no nome
foreach f [glob *.v] { if {![string match "* *" $f]} { vlog -quiet $f } }
file mkdir sim_out
vsim -voptargs=+acc -onfinish stop work.tb_FP_Mult_Unit
add wave -r /*
run -all
```

Para cada novo passo, troque só o nome do testbench no `vsim` (sem recompilar,
a menos que tenha editado algum `.v`).

Tempo de simulação: os testes de bloco levam segundos; `tb_CNN_Top`,
`tb_Feature_*` e `tb_Sample_Source` levam mais; o `tb_SMMA_Top` é o mais longo
(cerca de 2 minutos no Icarus).
