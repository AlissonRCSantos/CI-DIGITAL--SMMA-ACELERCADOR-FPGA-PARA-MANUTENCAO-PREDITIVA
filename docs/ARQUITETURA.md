# SMMA — Arquitetura final e relação dos módulos

**Smart Machine Monitoring Accelerator** — acelerador digital para manutenção
preditiva de motores elétricos, descrito em Verilog e implementado na
**Terasic DE0-CV** (Cyclone V `5CEBA4F23C7N`, 50 MHz).

A arquitetura segue o **diagrama do grupo** (LMS na entrada → *Data Bus
Driver* → ramo FFT com detector de picos e Euclides, ramo de estimação de
parâmetros com Gauss-Jordan → *Parameter RegFile* → árvore de decisão),
completada com os blocos obrigatórios que faltavam nele (destacados como
**NOVO** no desenho).

![Arquitetura final](diagramas/SMMA_arquitetura.png)

(versões vetoriais: [SVG](diagramas/SMMA_arquitetura.svg) · [PDF](diagramas/SMMA_arquitetura.pdf))

---

## 1. Diagrama do grupo × implementação

| bloco do diagrama | módulo(s) no RTL | observação |
|---|---|---|
| Xa (sensor) | `Sample_Source` | sensor emulado: 12 janelas reais do dataset em ROM, a 25,6 kHz |
| LMS | `LMS_Stage` ↔ `LMS_Filter_Top` (+5 submódulos) | **em série**: toda amostra atravessa o LMS antes do barramento |
| DATA BUS DRIVER | `Data_Bus_Driver` | distribui o dado filtrado aos ramos, com handshake (join) |
| MEM_A (64 amostras) | `Frame_Builder` | quadros de 64 amostras, salto 32 (um quadro a cada 10 ms) |
| FFT | `FFT_Top` (+7 submódulos) | 64 pontos, radix-2 **DIT** (ver §3) |
| MEM_B | `Spectrum_Accumulator` | espectro médio dos 32 quadros da janela |
| PEAK DETECTOR | `peak_detector` | 3 maiores picos acima do limiar |
| EUCLIDES | `mdc_gcd` | k0 = MDC dos picos |
| (BPFO–BPFI) → árvore | `Feature_Spectral` | 8 características: harmônicos 1x/2x/3x, 3 bandas (inclui BPFO/BPFI), energia, centroide |
| coefficient accumulator | `autocorrelacao_yw` | acumula r[k] = Σ x[n]·x[n−k] e normaliza (rho) |
| GAUSS_JORDAN | `Yule_Walker_Solver` ↔ `gauss_jordan_inv` | monta R (Toeplitz 3×3), inverte, a = R⁻¹·r |
| PARAMETER REGFILE | `Parameter_RegFile` | banco com as 16 entradas do classificador |
| DECISION TREE | `ML_Tree_Classifier` | árvore de decisão, 4 classes |

### 1.1 Blocos acrescentados e por quê

| bloco acrescentado | módulo(s) | por quê |
|---|---|---|
| **FIR anti-alias + decimação ÷8** (antes do LMS) | `FIR_Decimator` | Sem decimação, a FFT de 64 pontos a 25,6 kHz teria bins de **400 Hz**: rotação (50 Hz), BPFO (179 Hz) e BPFI (272 Hz) cairiam todas no bin 0 e o detector de picos/Euclides não teria o que separar. A 3,2 kHz cada bin vale 50 Hz. É também a filtragem que garante "dados filtrados" antes de tudo. |
| **Estimador de f0** (depois do Euclides) | `f0_estimator` | O Euclides entrega o índice k0; o enunciado (3.1) pede a frequência f0 = k0·fs/N e que ela seja encaminhada ao classificador. |
| **Ramo CNN** | `FFT_Log2_Compress`, `Spectrogram_Buffer`, `CNN_Top` (+8 submódulos) | O acelerador CNN é obrigatório (3.6 e lista da seção 4). Ele usa o espectrograma 32×32 formado pelas magnitudes das 32 FFTs da janela. |
| **Unidade de controle global** | `SMMA_Global_Control` | Exigida na seção 4: dá o `start` único a todos os blocos, espera o `ready` de todos e registra o veredito. |
| **Interface de saída** | `SMMA_Panel` | Exigida na seção 4: mostra árvore, CNN e classe verdadeira nos HEX/LEDs da placa (e a f0 com `SW[8]`). |
| **Comunicação** | handshake `valid/ready` + `Stream_Fork` | Os ramos FFT→(MEM_B, CNN) e MEM_B→(features, picos) também se dividem; o `Stream_Fork` garante que todos recebam os mesmos dados. |
| **Aritmética comum** | `FP_Mult_Unit`, `FP_Arith_Unit`, `Divider_Q15`, `fixed_point_divider` | multiplicadores/divisores em ponto fixo usados pelos blocos acima. |

---

## 2. Relação: módulos pedidos no enunciado × projeto

| Requisito do enunciado | Seção | Módulo(s) | Pasta |
|---|---|---|---|
| Interface de entrada dos sensores | 4 | `Sample_Source`, `FIR_Decimator` | `RTL/entrada` |
| Memória / buffers de amostras | 4 | `Frame_Builder` (MEM_A), `Spectrum_Accumulator` (MEM_B), `Spectrogram_Buffer` | `RTL/buffers` |
| Módulo MDC | 3.1 | `peak_detector` → `mdc_gcd` → `f0_estimator` | `RTL/mdc` |
| Módulo FFT (64 pontos) | 3.2 | `FFT_Top` + 7 submódulos; `FFT_Log2_Compress` | `RTL/fft` |
| Inversão de matriz (≤ 4×4) | 3.3 | `autocorrelacao_yw` → `Yule_Walker_Solver` ↔ `gauss_jordan_inv` (+ `fixed_point_divider`) | `RTL/matriz` |
| Filtro adaptativo LMS (8 coef.) | 3.4 | `LMS_Filter_Top` + 5 submódulos, `LMS_Stage` | `RTL/lms` |
| Acelerador de ML | 3.5 | `Feature_Spectral`, `Parameter_RegFile`, `ML_Tree_Classifier` | `RTL/ml` |
| Acelerador CNN (32×32×1, 8 filtros 3×3) | 3.6 | `CNN_Top` + 8 submódulos | `RTL/cnn` |
| Unidade de controle global | 4 | `SMMA_Global_Control` | `RTL/top` |
| Comunicação entre módulos | 4 | `Data_Bus_Driver`, `Stream_Fork`, handshake em todos | `RTL/top` |
| Interface de saída | 4 | `SMMA_Panel` | `RTL/top` |
| Aritmética de ponto fixo | 6.4 | `FP_Mult_Unit`, `FP_Arith_Unit`, `Divider_Q15` | `RTL/comum` |

Origem: os módulos de FFT, LMS, MDC, picos, f0, Gauss-Jordan, divisor e CNN
são os das branches (`fft`, `feat/LMS`, `feat/MDC`, `feat/peak_detector`,
`feat/frequency`, `feat/inverse-matrix`, `feat/CNN`), **sem alteração de
lógica**. O `autocorrelacao_yw` foi reescrito em fluxo para a janela de 1056
amostras (o original guardava 64 amostras em registradores). Os blocos de
ligação/controle são novos.

---

## 3. Decisões que diferem do diagrama (e por quê)

- **LMS em série, repassando o sinal do FIR (`SAIDA_LMS = 0`).** Toda amostra
  atravessa o LMS: o `LMS_Stage` a recebe, roda uma iteração do
  `LMS_Filter_Top` (preditor/ALE: entra x[n−1], desejado x[n]) e só então a
  entrega ao barramento. O que segue no barramento é a amostra filtrada pelo
  FIR, e o LMS contribui com a característica `r_lms` (energia do erro de
  predição). Motivos:
  1. **resultado mantido** — a árvore e a CNN foram treinadas com o sinal do
     FIR; trocar o barramento por y(n) mudaria FFT, espectrograma e
     autocorrelação, e os modelos teriam de ser retreinados;
  2. **medido no dataset** — com o sinal em Q1.15 (±32 g), os pesos do LMS
     quase não adaptam dentro de uma janela: a saída y(n) fica praticamente
     nula (soma de dezenas de LSB em 1056 amostras, `tb_LMS_Stage`). Mandar
     y(n) para a FFT apagaria o espectro.
  O parâmetro `SAIDA_LMS = 1` do `SMMA_Top` coloca y(n) no barramento, para
  quem quiser retreinar os modelos com ele.
- **Um canal (Xa) em vez de quatro.** A ROM de demonstração de um canal já
  ocupa 52% das memórias M10K da DE0-CV; quatro canais precisariam de ~6,5
  Mbit, o dobro do chip. Os modelos também foram treinados com esse canal.
- **FFT DIT em vez de DIF.** As duas são equivalentes matematicamente; a DIT é
  a da branch `fft`, já verificada bit a bit. Trocar mudaria o arredondamento
  e, portanto, o resultado.
- **MEM_A / MEM_B de 1×64** (um canal), dentro do limite de duas memórias da
  FFT (seção 5): `Frame_Builder` (entrada) e `Spectrum_Accumulator` (saída);
  a FFT tem ainda sua RAM interna in-place.

---

## 4. Hierarquia de instanciação

```
SMMA_Top
├── Sample_Source                     sensor Xa (ROM do dataset, 1,6 Mbit em M10K)
├── FIR_Decimator                     anti-alias 63 taps + /8          (NOVO)
├── LMS_Stage ── Divider_Q15          LMS em série
├── LMS_Filter_Top                    LMS (branch feat/LMS)
│   ├── LMS_Control_FSM
│   ├── LMS_Input_Delay_Line
│   ├── LMS_Weight_Storage
│   ├── LMS_Processing_Element ── FP_Mult_Unit, FP_Arith_Unit
│   └── LMS_Accumulator_Error_Scale
├── Data_Bus_Driver ── Stream_Fork    DATA BUS DRIVER
├── Frame_Builder                     MEM_A
├── FFT_Top                           FFT
│   ├── FFT_Control_FSM ── FFT_Addr_Gen, FFT_Bit_Reverse
│   ├── FFT_Butterfly ── FP_Mult_Unit ×4
│   ├── FFT_Memory
│   ├── FFT_Twiddle_ROM
│   └── FFT_Magnitude
├── Stream_Fork (b)                   |X[k]| -> MEM_B e espectrograma
├── Spectrum_Accumulator              MEM_B
├── Stream_Fork (c)                   espectro -> bandas e picos
├── Feature_Spectral ── Divider_Q15   bandas BPFO/BPFI e demais features
├── peak_detector                     PEAK DETECTOR
├── mdc_gcd                           EUCLIDES
├── f0_estimator                      f0 = k0.fs/N                     (NOVO)
├── autocorrelacao_yw ── fixed_point_divider   COEFFICIENT ACCUMULATOR
├── Yule_Walker_Solver                         GAUSS_JORDAN (controle + R^-1 r)
├── gauss_jordan_inv ── fixed_point_divider    GAUSS_JORDAN (inversor)
├── Parameter_RegFile                 PARAMETER REGFILE
├── ML_Tree_Classifier                DECISION TREE
├── FFT_Log2_Compress                 ramo CNN                         (NOVO)
├── Spectrogram_Buffer                ramo CNN                         (NOVO)
├── CNN_Top                           CNN                              (NOVO)
│   ├── CNN_Control_FSM, CNN_Line_Buffer, CNN_MaxPool
│   ├── CNN_Conv_Layer ── CNN_MAC_Unit ×8, CNN_ReLU ×8, CNN_Weight_ROM
│   └── CNN_Dense_Classifier ── CNN_MAC_Unit, CNN_ReLU ×9, CNN_Weight_ROM
├── SMMA_Global_Control               controle global                  (NOVO)
└── SMMA_Panel                        interface de saída               (NOVO)
```

---

## 5. Fluxo de uma janela, comunicação e controle

Uma **janela** = 8503 amostras brutas (332 ms a 25,6 kHz) = **1056 amostras
decimadas** a 3,2 kHz = **32 quadros de FFT** de 64 pontos com salto de 32 (um
quadro a cada **10 ms**).

1. `KEY[1]` → `SMMA_Global_Control` dá **um único pulso `arranca`** (start de
   todos os blocos no mesmo ciclo).
2. `Sample_Source` → `FIR_Decimator` → `LMS_Stage`: cada amostra filtrada passa
   pelo LMS (30 ciclos) e vai ao `Data_Bus_Driver`.
3. O barramento entrega a amostra **ao mesmo tempo** ao MEM_A (ramo FFT) e ao
   acumulador de coeficientes (ramo de estimação de parâmetros).
4. Ramo FFT: `Frame_Builder` → `FFT_Top` (32×) → MEM_B e espectrograma → CNN.
   No fim da janela, MEM_B entrega o espectro médio às bandas
   (`Feature_Spectral`) e ao detector de picos → Euclides → f0.
5. Ramo de parâmetros: `autocorrelacao_yw` → `Yule_Walker_Solver` ↔
   `gauss_jordan_inv` → a1..a3.
6. `Parameter_RegFile` reúne as 16 entradas (8 espectrais, r_lms, rho1..3, f0,
   a1..a3) e as entrega à árvore.
7. Com as classes da árvore **e** da CNN válidas, o controle registra o
   veredito e o `SMMA_Panel` o mostra.

| forma de operação | onde |
|---|---|
| **série** | FIR → LMS → barramento |
| **pipeline** (por amostra, via handshake) | barramento → quadros → FFT → espectro / espectrograma → CNN |
| **paralelo** | ramo FFT/MDC, ramo de parâmetros e ramo CNN sobre a mesma janela |
| **sequencial** | entre janelas: só arranca com todos os blocos em repouso |

**Controle:** `reset` (síncrono, ativo em alto; `KEY[0]` sincronizado com 2
registradores), `start` (pulso único `arranca`), `ready` (AND de todos os
blocos para arrancar), `busy` (`LEDR[8]`), `done`, `enable`.

**Dados:** handshake `valid/ready` em todos os streams — o produtor segura o
dado até o aceite (sem perda, sem sobrescrita) e cada palavra é contada uma
vez (sem duplicação). O `Data_Bus_Driver` e o `Stream_Fork` fazem *join*: a
palavra só avança quando **todos** os ramos aceitam, de modo que os ramos
processam sempre a mesma janela. Exceção: a saída do `autocorrelacao_yw`
mantém o protocolo original da branch (`r_valid/r_index/r_data`), e seus
consumidores (`Parameter_RegFile`, `Yule_Walker_Solver`) capturam por índice.

### Vetor do PARAMETER REGFILE

| índice | característica | origem |
|---|---|---|
| 0–7 | `r_1x r_2x r_3x r_banda1 r_banda2 r_banda3 log2E centroide` | MEM_B (FFT) |
| 8 | `r_lms` | LMS |
| 9–11 | `rho1 rho2 rho3` | acumulador de coeficientes |
| 12 | `f0` em Hz (0 se o Euclides sinalizar erro) | MDC |
| 13–15 | `a1/2 a2/2 a3/2` | Gauss-Jordan |

A árvore em `quartus/vetores/arvore.hex` foi treinada com as posições 0..11 —
por isso a classificação é idêntica à validada. As posições 12..15 chegam ao
classificador; usá-las na decisão é retreinar e regravar a ROM.

As interfaces porta a porta de cada módulo (larguras, protocolo, latência)
estão documentadas no cabeçalho do respectivo arquivo `.v`.

**Resultado na placa preservado:** o `tb_Equivalencia` compara, nas 12
janelas, bit a bit, as 12 características usadas pela árvore, os 4 scores da
CNN e todos os pinos do painel contra a integração anterior — 12/12 idênticas.

---

## 6. Formato numérico (enunciado 6.4)

Convenção do projeto: Q*i*.*f* = *i* bits à esquerda da vírgula **incluindo o
bit de sinal** e *f* bits fracionários (Q1.15 = 16 bits, faixa [−1, +1)).

| grandeza | formato | bits (int + frac) | observação |
|---|---|---|---|
| amostras do sensor | Q1.15 | 1 + 15 | fundo de escala ±32 g |
| coeficientes do FIR | Q1.15 | 1 + 15 | acumulador largo, saturação na saída |
| dados e twiddles da FFT | Q1.15 | 1 + 15 | ÷2 nos 4 primeiros estágios (ganho ÷16) |
| \|X[k]\| e espectro médio | inteiro sem sinal | 16 | alpha-max-beta-min; acumulador de 24 bits |
| características | Q1.15 | 1 + 15 | razões ∈ [0,1), log2 de Mitchell |
| coeficientes do LMS | Q1.15 | 1 + 15 | μ = 2⁻³ (deslocamento); acumulador de 32 bits |
| energias do LMS / autocorrelação | inteiro | 48 | produtos plenos 32 bits × 1056 |
| rho (autocorrelação normalizada) | Q1.15 | 1 + 15 | \|rho\| ≤ 1 |
| elementos da matriz e de R⁻¹ | **Q8.16** (24 bits) | 8 + 16 | faixa ±128; o Q4.12 original satura (\|R⁻¹\| chega a ~16) |
| coeficientes AR | Q1.15 de a/2 | 1 + 15 | \|a1\| chega a ~1,5 |
| pesos e ativações da CNN | Q1.15 | 1 + 15 | pesos de 16 bits (8 e 4 bits avaliados em Python) |
| MAC da CNN | inteiro | 40 | requantizado para Q1.15 com saturação |
| limiares da árvore | Q1.15 | 1 + 15 | comparação com sinal |
| f0 | inteiro (Hz) | 20 no estimador, 16 no vetor | + 6 bits fracionários no `f0_estimator` |

Multiplicação Q1.15: `sat16((a·b + 2¹⁴) ≫ 15)` (arredondamento meio-para-cima e
saturação). Toda a aritmética dos extratores de características casa **bit a
bit** com `python/smma/features.py`, porque os limiares da árvore foram
aprendidos sobre esses números.

---

## 7. Mapeamento algoritmo → arquitetura (resumo)

Latências medidas no `tb_latencia` (janela 3, tempo real com divisor de taxa
reduzido), em ciclos de 50 MHz.

| módulo | algoritmo | datapath / controle | ciclos | recursos principais |
|---|---|---|---|---|
| FIR + decimação | convolução 63 taps, ÷8 | 1 multiplicador reutilizado, linha de atraso | 63 por saída | 1 DSP |
| FFT | radix-2 DIT, in-place, 6 estágios × 32 borboletas | 1 borboleta (4 mult.), RAM dupla porta, ROM de twiddles, FSM | **636 por quadro** (carga + cálculo + descarga) | 4 DSP, 1 RAM 64×32 |
| espectro médio | Σ de 32 quadros, ≫ 5 | 32 acumuladores | 32 de saída | 0 DSP |
| MDC | top-3 picos; Euclides por subtração; f0 = k0·fs/N | comparadores em cascata; 2 regs + subtrator + comparador; 1 mult. 6×20 | 25 após o espectro | 0 DSP |
| LMS (em série) | y = Σwᵢx(n−1−i); e = d − y; wᵢ += μ·e·x | PE compartilhado (1 mult. + 1 somador em pipeline), FSM de 26 ciclos | **30 por amostra**, da entrada ao barramento (16 multiplicações) | 1 DSP (+1 p/ energias) |
| autocorrelação | r[k] += x[n]·x[n−k], rho = r[k]/r[0] | 2 multiplicadores, 4 acumuladores de 48 bits, divisor por restauração | ~3 por amostra; 440 para as 4 divisões | 2 DSP |
| inversão 3×3 | Gauss-Jordan com pivotamento parcial; a = R⁻¹r | memória 4×8, 1 multiplicador, divisor (1/pivô), FSM; MAC no solver | **245** (inversão) + 32 (MAC) | 2 DSP |
| árvore | percurso de nós com comparação ≤ | ROM 141×32, 1 comparador | **20** | 0 DSP |
| CNN | conv 3×3 ×8 + ReLU + maxpool 2×2 + GAP + densa 8→4 | line buffer, 8 MACs em paralelo, FSM | **9 332** após o último bin | 8 DSP |

Ver os cabeçalhos dos arquivos para pseudocódigo, estados e justificativas de
cada bloco.

---

## 8. Decisões de projeto (enunciado 6.8)

- **Em série:** FIR → LMS → barramento (toda amostra atravessa o LMS).
- **Paralelos:** depois do barramento, os ramos FFT/MDC, estimação de
  parâmetros e CNN; e os 8 filtros da camada convolucional.
- **Compartilhados:** divisores (1 por bloco), o multiplicador do FIR (63 taps),
  o PE do LMS (filtragem e atualização), os 2 multiplicadores da autocorrelação
  (4 lags), o multiplicador do Gauss-Jordan (normalização e eliminação).
- **Maior gargalo / maior consumo:** a CNN — 9 332 ciclos por imagem e 8 DSPs;
  é o maior consumidor de multiplicadores. A FFT vem em seguida (4 DSPs).
- **Requisito de 10 ms:** cada quadro novo (64 amostras, salto de 32 = 10 ms a
  3,2 kHz) é transformado em 636 ciclos = **12,7 µs**; a decisão completa da
  janela fica pronta **~200 µs** depois da última amostra. O requisito é
  atendido com folga de mais de 700×; o tempo de uma janela (332 ms) é
  dominado pela taxa do sensor, não pelo processamento.
- **Otimizações possíveis:** compartilhar um único divisor entre os blocos de
  features; usar os pesos de 8 bits na CNN (acurácia medida em Python); gating
  de clock dos ramos ociosos entre janelas.

---

## 9. Observações honestas

- **f0 nas 12 janelas da demonstração = 50 Hz**, que é a rotação real (3010 rpm
  = 50,17 Hz, bin 1). Os picos dominantes do espectro médio, porém, são
  ressonâncias estruturais (bins 12–29), cujo MDC dá 1 — o próprio enunciado
  avisa que falhas de rolamento produzem componentes não harmônicas. O módulo
  está correto (o `tb_MDC_Chain` reproduz o exemplo do enunciado:
  MDC(12, 18, 30) = 6); a interpretação física do k0 depende do espectro.
- **Tempo no Quartus:** a síntese/fitting não pôde ser rodada neste ambiente.
  A elaboração completa foi verificada com Yosys (0 problemas), mas confira no
  TimeQuest que o projeto fecha em 50 MHz — os caminhos novos mais longos são o
  multiplicador 24×24 do `gauss_jordan_inv` e o MAC do `Yule_Walker_Solver`.
- **Recursos:** a integração anterior usava 9 085 ALMs (49%), 18 DSPs (27%) e
  203 M10K (66%). Os blocos reintegrados acrescentam ~6 multiplicadores e
  algumas centenas de registradores; confira no relatório do Fitter.
