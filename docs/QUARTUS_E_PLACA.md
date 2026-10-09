# SMMA no Quartus e na DE0-CV

Projeto para a **Terasic DE0-CV** (Cyclone V `5CEBA4F23C7N`, 50 MHz),
Quartus Prime 20.1 Lite.

## Compilar

1. Abra `quartus/SMMA.qpf` (**File → Open Project**).
2. **Processing → Start Compilation**.
3. Grave com **Tools → Programmer** → `quartus/output_files/SMMA.sof`.

Ou pela linha de comando, a partir da raiz do repositório:

```bash
quartus_sh --flow compile quartus/SMMA
quartus_pgm -m jtag -o "p;quartus/output_files/SMMA.sof"
```

O `SMMA.qsf` lista **todos** os arquivos de `RTL/` (uma seção por módulo do
enunciado), a pinagem da DE0-CV já usada na placa e o `SMMA.sdc` (50 MHz).
As pastas `db/`, `incremental_db/`, `output_files/` e `simulation/` são geradas
pela compilação e não vão para o git.

### Os arquivos `.hex` (ponto que mais costuma falhar)

Os módulos abrem as ROMs por `$readmemh("vetores/...")`, caminho relativo ao
diretório do projeto — por isso a pasta **`quartus/vetores/`** fica ao lado do
`.qpf`:

| arquivo | usado por | conteúdo |
|---|---|---|
| `demo_amostras.hex` | `Sample_Source` | 12 janelas do dataset, 8503 amostras cada (204 kB) |
| `demo_rotulos.hex` | `Sample_Source` | rótulo verdadeiro + previsão do modelo |
| `fir_coef.hex` | `FIR_Decimator` | 63 coeficientes do FIR |
| `arvore.hex` | `ML_Tree_Classifier` | 141 nós da árvore |

**Se o Quartus não achar um `.hex`, ele infere a ROM ZERADA e compila sem
erro** — o sintoma na placa é o classificador respondendo sempre a mesma
classe. Procure no relatório por avisos de *memory initialization file*.
A ROM do dataset tem de ir para M10K (confira em *Fitter → Resource
Utilization*).

Os demais `.hex` da pasta são vetores dos testbenches.

### O que conferir depois de compilar

| relatório | esperado |
|---|---|
| Analysis & Synthesis → Messages | nenhum aviso de `.hex` não encontrado; nenhum latch (`10240`) |
| Fitter → Resource Utilization | cabe na 5CEBA4; `Sample_Source` em M10K |
| TimeQuest → Slow 1100mV 85C → Setup `CLOCK_50` | **slack ≥ 0** a 50 MHz |
| Analysis & Synthesis → Resource Utilization by Entity | `LMS_Stage`, `LMS_Filter_Top`, `gauss_jordan_inv`, `Yule_Walker_Solver`, `mdc_gcd`, `CNN_Top` com recursos ≠ 0 |
| RTL Viewer (Tools → Netlist Viewers) | os blocos do diagrama em `docs/diagramas/` |

`MODO_RAPIDO` tem de ficar em **0** na síntese (é o padrão do `SMMA_Top`); o
valor 1 só existe para acelerar a simulação.

## Usar na bancada

| controle | função |
|---|---|
| `KEY[0]` | reset |
| `KEY[1]` | dispara uma janela (uma tecla por medida) |
| `SW[3:0]` | janela do dataset (0..11) |
| `SW[8]` | mostra a **frequência fundamental (MDC)** em Hz nos `HEX3..HEX0` |
| `SW[9]` | troca `LEDR[3:0]` para os 4 LSB dos scores da CNN |

| display | mostra (com `SW[8] = 0`) |
|---|---|
| `HEX0` | classe da **árvore** |
| `HEX1` | classe da **CNN** |
| `HEX2` | classe **verdadeira** |
| `HEX3` | `E` se houve erro de percurso na árvore ou saturação no FIR |
| `HEX5:4` | índice da janela |

Classes: `0` normal, `1` desbalanceamento, `2` desalinhamento, `3` rolamento.

| LED | significado |
|---|---|
| `LEDR[3:0]` | classe da árvore em one-hot (ou scores da CNN com `SW[9]`) |
| `LEDR[4]` | árvore acertou |
| `LEDR[5]` | CNN acertou |
| `LEDR[6]` | árvore e CNN concordam |
| `LEDR[7]` | o modelo Python acerta esta janela |
| `LEDR[8]` | ocupado |
| `LEDR[9]` | resultado válido |

Cada janela leva **332 ms** (8503 amostras a 25,6 kHz — a fonte reproduz o
dataset na taxa real do sensor); o processamento depois da última amostra
leva ~0,2 ms.

### Resultado esperado

| janela | arquivo | verdadeira | árvore | CNN | f0 (SW[8]) |
|---|---|---|---|---|---|
| 0 | 0Nm_Normal | 0 | 0 | 0 | 50 |
| 1 | 0Nm_Unbalance_1751mg | 1 | 1 | 1 | 50 |
| 2 | 0Nm_Misalign_03 | 2 | 2 | 2 | 50 |
| 3 | 0Nm_BPFO_10 | 3 | 3 | 3 | 50 |
| 4 | 2Nm_Normal | 0 | 0 | 0 | 50 |
| 5 | 2Nm_Unbalance_1751mg | 1 | 1 | **2** | 50 |
| 6 | 2Nm_Misalign_03 | 2 | 2 | 2 | 50 |
| 7 | 2Nm_BPFO_10 | 3 | 3 | 3 | 50 |
| 8 | 4Nm_Normal | 0 | **1** | **2** | 50 |
| 9 | 4Nm_Unbalance_1751mg | 1 | 1 | 1 | 50 |
| 10 | 4Nm_Misalign_03 | 2 | 2 | 2 | 50 |
| 11 | 4Nm_BPFO_10 | 3 | 3 | 3 | 50 |

Árvore: **11/12** (a janela 8 é um erro do modelo, reproduzido pelo hardware).
CNN: **10/12**. Idêntico à integração anterior.

## Relógio

Um único domínio: `CLOCK_50`. Sem PLL, sem travessia entre domínios. O
`SMMA.sdc` declara 20 ns e marca `KEY`, `SW`, `LEDR` e `HEX*` como
`false_path` (chaves e LEDs); os botões passam por dois registradores de
sincronização no `SMMA_Top`.

## Simular pelo ModelSim/Questa

Rode **a partir da pasta `quartus/`** (onde está `vetores/`):

```tcl
do ../sim/modelsim/sim_tb.do tb_SMMA_Top
do ../sim/modelsim/sim_latencia.do          ;# latência de cada bloco, com ondas
```

O fluxo *Tools → Run Simulation Tool* do Quartus roda em
`quartus/simulation/modelsim/`, onde `vetores/` não existe; prefira os scripts
acima. Para a regressão completa sem ModelSim, ver [VERIFICACAO.md](VERIFICACAO.md).
