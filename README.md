# SMMA — Acelerador FPGA para Manutenção Preditiva

**Smart Machine Monitoring Accelerator.** Diagnostica falhas em motores
industriais a partir do sinal de vibração, inteiramente em hardware, numa
Cyclone V (DE0-CV). PBL de Circuitos Digitais IV.

Duas vias de classificação rodam sobre a **mesma janela** e aparecem lado a
lado no painel da placa: uma **árvore de decisão** sobre 12 características
extraídas em hardware, e uma **CNN** sobre o espectrograma.

---

## Pipeline

```
Sample_Source        dataset em ROM, 25,6 kHz, Q1.15 (±32 g)
      |
FIR_Decimator        63 taps @1,4 kHz, decimação ÷8  ->  3,2 kHz
      |
      +--------------------------------+
      |                                |
Frame_Builder                   Feature_Temporal
64 pontos, salto 32             1056 amostras
      |                                | r_lms, rho1..rho3
FFT_Top (64 pts, ÷16)                  |
      | |X[k]|, bins 0..31             |
      +----------------+               |
      |                |               |
Feature_Spectral  FFT_Log2_Compress    |
32x32 -> 8             |               |
      |        Spectrogram_Buffer      |
      |         32x32, transposto      |
      |                |               |
      |            CNN_Top             |
      |                |               |
      +----> ML_Tree_Classifier <------+
                 12 features
```

A decimação ÷8 é o que torna a FFT de 64 pontos útil: a 25,6 kHz os 64 bins
cobrem 400 Hz por bin e **as seis frequências de diagnóstico caem todas no bin
0**. A 3,2 kHz cada bin vale 50 Hz, e eixo (50,17 Hz), FTF (19,94), BPFO
(179,43), BSF (234,19) e BPFI (272,07) se separam.

---

## Resultados medidos

Partição de **teste**, separada por tempo com 0,5 s de guarda.

| | 0 Nm | 2 Nm | 4 Nm | média |
|---|---|---|---|---|
| **Árvore (12 features)** | **0,9725** | **0,9354** | **0,8832** | **0,9331** |
| CNN (espectrograma) | 0,893 | 0,862 | 0,738 | 0,832 |

A média da CNN esconde que ela **degrada muito com a carga**. Seis das oito
características espectrais são **razões pela energia total**, logo não dependem
do nível absoluto do sinal — é por isso que a árvore aguenta a variação de
carga.

Árvore: 141 nós, profundidade 9, **564 B de ROM**. Em Q1.15 a acurácia cai de
0,9331 para 0,9321 (discordância de quantização de 0,149%).

### As 12 características

| # | nome | o que indica |
|---|---|---|
| 0–2 | `r_1x`, `r_2x`, `r_3x` | 1x/2x/3x da rotação — **desbalanceamento**, **desalinhamento** |
| 3–5 | `r_banda1..3` | 200–400, 400–800, 800–1600 Hz — **rolamento** |
| 6 | `log2E` | energia total (aproximação de Mitchell) |
| 7 | `centroide` | centro de massa espectral |
| 8 | `r_lms` | resíduo de um preditor LMS de 8 taps, μ=2⁻³ |
| 9–11 | `rho1..rho3` | autocorrelação normalizada |

`rho1..rho3` substituíram os coeficientes AR(3): dão acurácia **maior** (0,9331
contra 0,9269), árvore **menor** (141 contra 149 nós) e dispensam resolver o
sistema 3×3 no hardware. O que saiu foi o *solver*, não a origem do dado — a
autocorrelação continua sendo a saída do `autocorrelacao_yw.v`.

`r_lms` corre ao **contrário** da intuição: falha de rolamento dá resíduo
**baixo** (~19500) e o estado normal, **alto** (~32100). Depois do FIR de
1,4 kHz e da decimação, o toque de ressonância do rolamento sobra como um sinal
oscilatório que um preditor linear acompanha bem; o estado normal é ruído de
banda larga, que ele não acompanha.

---

## Dataset

Jung et al., *Data in Brief* **48** (2023), KAIST —
[doi:10.1016/j.dib.2023.109049](https://doi.org/10.1016/j.dib.2023.109049).
Usa-se apenas o canal de **vibração** (acelerômetro x do mancal A), 25,6 kHz.

Quatro classes: normal, desbalanceamento (massa de 583 a 3318 mg no disco do
rotor), desalinhamento (0,1 a 0,5 mm) e rolamento (BPFO/BPFI, 0,3 a 3,0 mm).
Três cargas: 0, 2 e 4 N·m, a 3010 RPM.

> A carga de **0 N·m é mantida**. "Desbalanceamento" aqui é desbalanceamento de
> **massa do rotor**, não de carga; a carga é uma condição de torque
> independente. Descartar 0 N·m jogaria fora 36% do treino e **pioraria** a
> própria classe de desbalanceamento (0,8926 contra 0,9204).

---

## Mapa do repositório

```
RTL/              Verilog + testbenches + vetores de teste
RTL/vetores/      .hex: dataset da demo, árvore, coeficientes, vetores
quartus/          projeto Quartus (.qpf/.qsf/.sdc) e guia de migração
python/           treino, quantização e exportação dos vetores
python/smma/      modelo de referência bit-exato com o hardware
dados/            dados processados (gerados pelos scripts)
dataset/          .mat originais
```

### Blocos em `RTL/`

| módulo | o que faz |
|---|---|
| `SMMA_Top.v` | top level: cadeia completa, unidade de controle e painel |
| `Sample_Source.v` | 12 janelas do dataset em ROM, reproduzidas a 25,6 kHz |
| `FIR_Decimator.v` | FIR de 63 taps + decimação ÷8, **um** multiplicador |
| `Frame_Builder.v` | quadros de 64 amostras com salto de 32 |
| `FFT_Top.v` + `FFT_*.v` | FFT radix-2 DIT de 64 pontos, in-place, Q1.15, ganho ÷16 |
| `Feature_Spectral.v` | as 8 características espectrais |
| `Feature_Temporal.v` | `r_lms` e `rho1..rho3` |
| `Divider_Q15.v` | divisor por restauração, compartilhado |
| `ML_Tree_Classifier.v` | percurso da árvore em ROM |
| `Spectrogram_Buffer.v` | imagem 32×32 transposta |
| `CNN_Top.v` + `CNN_*.v` | conv + ReLU + pooling + GAP + dense |
| `FP_Mult_Unit.v`, `FP_Arith_Unit.v` | aritmética Q1.15 comum |

Fora do caminho de dados, preservados das branches de origem: `peak_detector.v`,
`mdc_gcd.v`, `f0_estimator.v`, `LMS_Filter_Top.v`, `autocorrelacao_yw.v`,
`gauss_jordan_inv (2).v`.

---

## Verificação

```bash
cd RTL
./run_regressao.sh              # todos os testbenches (Icarus Verilog)
./run_regressao.sh tb_SMMA_Top  # só o teste ponta a ponta
```

Todo extrator é conferido **bit a bit** contra o modelo Python, em janelas reais
da partição de teste. Não é rigor gratuito: os limiares da árvore foram
aprendidos sobre aqueles números, então uma diferença de poucos LSB não "quase
acerta" — ela move a fronteira de decisão e pode trocar a classe.

O `tb_SMMA_Top` exercita o sistema pelos **mesmos pinos da placa**, sem
alcançar sinal interno, e exige que a árvore em hardware reproduza o modelo nas
12 janelas.

O `run_sim.sh` é para Cadence Xcelium (laboratório); o `run_regressao.sh`
depende só do `iverilog`.

**Pendência conhecida:** o `tb_LMS_Control_FSM` falha (8 divergências de
contador), falha pré-existente da branch `feat/LMS`. O módulo está **fora do
caminho de dados**: o `Feature_Temporal.v` reimplementa o preditor LMS com sua
própria FSM, e nem o `SMMA_Top.v` nem o projeto Quartus instanciam
`LMS_Control_FSM`.

---

## Reproduzir o treino

```bash
python python/scripts/01b_converter_mat.py            # .mat -> .npy
python python/scripts/06_gerar_features.py            # 12 features por janela
python python/scripts/07_treinar_classificador.py     # treina a árvore
python python/scripts/08_exportar_classificador.py    # -> vetores/arvore.hex
python python/scripts/09_exportar_frontend.py         # -> fir_coef, fir_teste
python python/scripts/10_exportar_demo_fpga.py        # -> ROM da demo
python python/scripts/11_exportar_vetores_features.py # -> feat_teste, temp_teste
```

---

## Para sintetizar

Ver **[quartus/README.md](quartus/README.md)**. Dois pontos antes de gravar:

1. **A pinagem do `.qsf` não foi conferida** contra o manual da DE0-CV, e os
   displays de 7 segmentos não estão atribuídos — importe o `DE0_CV.qsf` da
   Terasic.
2. Se o Quartus não achar um `.hex`, ele **infere a ROM zerada e compila sem
   erro**; o sintoma na placa é o classificador responder sempre a mesma classe.
