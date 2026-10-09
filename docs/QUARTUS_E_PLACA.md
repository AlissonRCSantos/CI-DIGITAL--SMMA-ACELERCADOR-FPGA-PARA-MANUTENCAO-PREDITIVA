# SMMA no Quartus e na DE0-CV

Quartus Prime 20.1 Lite · Terasic DE0-CV (Cyclone V `5CEBA4F23C7`, 50 MHz).

## Compilar

1. Abra **`quartus/SMMA.qpf`** (*File → Open Project*). O `SMMA.qsf` já traz o
   dispositivo, o top `SMMA_Top`, os 48 arquivos de `RTL/`, a pinagem e o
   `SMMA.sdc`.
2. **Processing → Start Compilation** (Ctrl+L).

Pela linha de comando, a partir da raiz: `quartus_sh --flow compile quartus/SMMA`.

As pastas `db/`, `incremental_db/` e `output_files/` são geradas pela
compilação. Podem ser apagadas, e o Quartus as recria.

### Conferir

| relatório | esperado |
|---|---|
| Messages (filtrar `hex`) | nenhum `.hex` não encontrado. O aviso *"Memory depth (16) … differs from (12)"* é normal: a ROM de rótulos tem 16 posições e só 12 são usadas |
| Fitter → Resource Section | 10 316 ALMs (56%), 203 M10K (66%), 24 DSP (36%) |
| Timing Analyzer → Slow 1100mV 85C → Setup `CLOCK_50` | slack **+2,961 ns** (Fmax 58,7 MHz) |

Os `.hex` das ROMs ficam em **`quartus/vetores/`**, ao lado do `.qpf`, porque os
módulos abrem `vetores/<arquivo>.hex` com caminho relativo. Se um deles não for
encontrado, a ROM fica zerada sem erro de compilação, e o sintoma na placa é a
árvore responder sempre a mesma classe.

| arquivo | usado por |
|---|---|
| `demo_amostras.hex`, `demo_rotulos.hex` | `Sample_Source` (12 janelas do dataset) |
| `fir_coef.hex` | `FIR_Decimator` |
| `arvore.hex` | `ML_Tree_Classifier` |
| demais `.hex` | testbenches |

## Gravar

1. Ligue a placa pelo USB‑Blaster, com a chave RUN/PROG em **RUN**.
2. **Tools → Programmer** → *Hardware Setup*: **USB‑Blaster**, modo **JTAG**.
3. Arquivo `output_files/SMMA.sof`, marque **Program/Configure** → **Start** → *100% (Successful)*.

A configuração é volátil: depois de desligar a placa, é preciso gravar de novo.

## Usar na bancada

| controle | função |
|---|---|
| `KEY[0]` | reset |
| `KEY[1]` | processa a janela escolhida (~0,33 s) |
| `SW[3:0]` | janela do dataset (0..11) |
| `SW[8]` | mostra a frequência fundamental (Hz) nos displays |
| `SW[9]` | `LEDR[3:0]` passa a mostrar bits dos scores da CNN |

| saída | significado |
|---|---|
| `HEX0` / `HEX1` / `HEX2` | classe da árvore / da CNN / verdadeira |
| `HEX3` | `E` = erro no percurso da árvore ou saturação no FIR |
| `HEX5:4` | número da janela |
| `LEDR[3:0]` | classe da árvore em one-hot |
| `LEDR4` / `LEDR5` / `LEDR6` / `LEDR7` | árvore certa / CNN certa / árvore = CNN / modelo Python certo |
| `LEDR8` / `LEDR9` | ocupado / resultado válido |

Classes: `0` normal, `1` desbalanceamento, `2` desalinhamento, `3` rolamento.

### Resultado esperado

| janela | arquivo | verdadeira | árvore | CNN |
|---|---|---|---|---|
| 0 | 0Nm_Normal | 0 | 0 | 0 |
| 1 | 0Nm_Unbalance_1751mg | 1 | 1 | 1 |
| 2 | 0Nm_Misalign_03 | 2 | 2 | 2 |
| 3 | 0Nm_BPFO_10 | 3 | 3 | 3 |
| 4 | 2Nm_Normal | 0 | 0 | 0 |
| 5 | 2Nm_Unbalance_1751mg | 1 | 1 | **2** |
| 6 | 2Nm_Misalign_03 | 2 | 2 | 2 |
| 7 | 2Nm_BPFO_10 | 3 | 3 | 3 |
| 8 | 4Nm_Normal | 0 | **1** | **2** |
| 9 | 4Nm_Unbalance_1751mg | 1 | 1 | 1 |
| 10 | 4Nm_Misalign_03 | 2 | 2 | 2 |
| 11 | 4Nm_BPFO_10 | 3 | 3 | 3 |

Resultado esperado: árvore **11/12** e CNN **10/12**. Com `SW[8]`, f0 = **50 Hz** em
todas as janelas. Há uma ficha para anotar os resultados em
[`SMMA_casos_de_teste_placa.pdf`](SMMA_casos_de_teste_placa.pdf).

## Problemas comuns

- **Nenhum cabo em *Hardware Setup*:** instale o driver em
  `C:\intelFPGA_lite\20.1\quartus\drivers` pelo Gerenciador de Dispositivos.
- **Erro com um nome de arquivo antigo:** feche o Quartus, apague `quartus/db`
  e `quartus/incremental_db` e abra o `.qpf` de novo.
- **Simular no ModelSim:** a partir de `quartus/`,
  `do ../sim/modelsim/sim_tb.do tb_SMMA_Top`. Mais em [VERIFICACAO.md](VERIFICACAO.md).
