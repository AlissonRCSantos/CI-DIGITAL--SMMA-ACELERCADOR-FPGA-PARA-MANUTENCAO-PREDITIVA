# SMMA — Acelerador FPGA para Manutenção Preditiva

**Smart Machine Monitoring Accelerator.** Diagnostica falhas em motores
elétricos a partir do sinal de vibração, inteiramente em hardware, numa
Cyclone V (DE0-CV, 50 MHz). PBL de Circuitos Digitais IV — CI Digital / CEPEDI.

A arquitetura segue o diagrama do grupo — **LMS na entrada → Data Bus Driver
→ ramo FFT (MEM_A, FFT, MEM_B, detector de picos, Euclides) e ramo de
estimação de parâmetros (acumulador de coeficientes, Gauss-Jordan) →
Parameter RegFile → árvore de decisão** — completada com os blocos
obrigatórios que faltavam: FIR anti-alias/decimação, estimador de f0, ramo
CNN, controle global e interface de saída. Todos são instâncias reais no
`SMMA_Top`, cada um em sua pasta.

![Arquitetura](docs/diagramas/SMMA_arquitetura.png)

---

## Módulos do enunciado × módulos do projeto

| Enunciado | Módulo(s) | Pasta |
|---|---|---|
| Interface de entrada dos sensores | `Sample_Source`, `FIR_Decimator` | `RTL/entrada` |
| Memória / buffers de amostras | `Frame_Builder`, `Spectrum_Accumulator`, `Spectrogram_Buffer` | `RTL/buffers` |
| 3.1 Módulo MDC | `peak_detector` → `mdc_gcd` → `f0_estimator` | `RTL/mdc` |
| 3.2 Módulo FFT (64 pontos) | `FFT_Top` + 7 submódulos, `FFT_Log2_Compress` | `RTL/fft` |
| 3.3 Inversão de matriz (≤ 4×4) | `autocorrelacao_yw` → `Yule_Walker_Solver` ↔ `gauss_jordan_inv` (+ `fixed_point_divider`) | `RTL/matriz` |
| 3.4 Filtro LMS (8 coeficientes) | `LMS_Filter_Top` + 5 submódulos, `LMS_Stage` (em série) | `RTL/lms` |
| 3.5 Acelerador de ML | `Feature_Spectral`, `Parameter_RegFile`, `ML_Tree_Classifier` | `RTL/ml` |
| 3.6 Acelerador CNN | `CNN_Top` + 8 submódulos | `RTL/cnn` |
| Controle global | `SMMA_Global_Control` | `RTL/top` |
| Comunicação entre módulos | `Data_Bus_Driver`, handshake `valid/ready` + `Stream_Fork` | `RTL/top` |
| Interface de saída | `SMMA_Panel` | `RTL/top` |
| Aritmética de ponto fixo | `FP_Mult_Unit`, `FP_Arith_Unit`, `Divider_Q15` | `RTL/comum` |

Detalhes (hierarquia, interfaces, formatos numéricos, latências e decisões de
projeto): **[docs/ARQUITETURA.md](docs/ARQUITETURA.md)**.

---

## Pipeline

```
Sample_Source (Xa, 25,6 kHz) -> FIR_Decimator (/8) -> LMS_Stage <-> LMS_Filter_Top -> Data_Bus_Driver
                                                         | r_lms                        |
   +--------------------------------------------------------------------------------------+
   |  ramo FFT                                                       ramo de parâmetros  |
   v                                                                                     v
 MEM_A (Frame_Builder) -> FFT_Top -> MEM_B (Spectrum_Accumulator)        autocorrelacao_yw
                            |          |-> Feature_Spectral (bandas BPFO/BPFI...)       |
                            |          '-> peak_detector -> mdc_gcd -> f0_estimator      Yule_Walker_Solver
                            |                                                           <-> gauss_jordan_inv
                            '-> FFT_Log2_Compress -> Spectrogram_Buffer -> CNN_Top         |
                                                                                           v
                         Parameter_RegFile (16) <- bandas, f0, r_lms, rho, a1..a3 -> ML_Tree_Classifier
                         SMMA_Global_Control (start/ready/done)  ->  SMMA_Panel (HEX, LEDR)
```

O LMS é um estágio **em série**: toda amostra o atravessa antes do barramento.
O barramento repassa a amostra filtrada pelo FIR (`SAIDA_LMS = 0`), com que os
modelos foram treinados; o LMS contribui com a característica `r_lms`. Ver
[docs/ARQUITETURA.md §3](docs/ARQUITETURA.md).

## Resultados (partição de teste)

| | 0 Nm | 2 Nm | 4 Nm | média |
|---|---|---|---|---|
| **Árvore** | **0,9725** | **0,9354** | **0,8832** | **0,9331** |
| CNN | 0,893 | 0,862 | 0,738 | 0,832 |

Na placa (12 janelas da demonstração): árvore **11/12**, CNN **10/12**, f0
estimada pelo MDC = **50 Hz** (rotação de 3010 rpm). Processamento de uma
janela: **~0,2 ms** depois da última amostra; cada quadro de 10 ms é
transformado em 12,7 µs.

---

## Mapa do repositório

```
RTL/                    Verilog sintetizável, uma pasta por módulo do enunciado
  top/                  SMMA_Top, SMMA_Global_Control, SMMA_Panel, Stream_Fork
  entrada/  buffers/  fft/  mdc/  lms/  matriz/  ml/  cnn/  comum/
sim/
  tb/                   testbenches (mesmas subpastas do RTL)
  run_regressao.sh      roda todos os testbenches (Icarus Verilog)
  run_xcelium.sh        Cadence Xcelium (laboratório)
  modelsim/             scripts .do para ModelSim/Questa
  golden/               modelos de referência (FFT, CNN) e figuras
  filelist.f            lista das fontes RTL
quartus/
  SMMA.qpf / .qsf / .sdc   projeto Quartus (DE0-CV, pinagem incluída)
  vetores/              ROMs ($readmemh) e vetores de teste
python/                 treino, quantização e exportação (CNN, árvore, FIR)
docs/
  ARQUITETURA.md        arquitetura final e relação dos módulos
  QUARTUS_E_PLACA.md    compilar, gravar e usar na bancada
  VERIFICACAO.md        testbenches e ordem de teste
  CNN_treinamento_e_RTL.md
  diagramas/            diagrama de blocos (PNG, SVG, PDF)
  PBL_enunciado.pdf
dados/                  dataset (local, fora do git)
```

## Como usar

```bash
# simulação (39 testbenches, ~4 min)
./sim/run_regressao.sh

# síntese
quartus_sh --flow compile quartus/SMMA      # ou abrir quartus/SMMA.qpf
```

Na placa: `SW[3:0]` escolhe a janela, `KEY[1]` dispara, `KEY[0]` reseta.
`HEX0` = árvore, `HEX1` = CNN, `HEX2` = verdadeira; `SW[8]` mostra f0 do MDC.
Ver **[docs/QUARTUS_E_PLACA.md](docs/QUARTUS_E_PLACA.md)**.

## Dataset

Jung et al., *Data in Brief* **48** (2023), KAIST —
[doi:10.1016/j.dib.2023.109049](https://doi.org/10.1016/j.dib.2023.109049).
Canal de vibração (acelerômetro x do mancal A), 25,6 kHz; quatro classes
(normal, desbalanceamento, desalinhamento, rolamento) em 0, 2 e 4 N·m.
