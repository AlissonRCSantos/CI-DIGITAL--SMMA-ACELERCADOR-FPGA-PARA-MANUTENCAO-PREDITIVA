# SMMA no Quartus -- guia de migração

Projeto do **SMMA** (Smart Machine Monitoring Accelerator) para a
**Terasic DE0-CV** (Cyclone V `5CEBA4F23C7N`, 50 MHz).

---

## Antes de gravar: confira a pinagem

As atribuições de pino no `SMMA.qsf` seguem o mapeamento usual da DE0-CV, mas
**não foram conferidas contra o manual da placa**, e os seis displays de 7
segmentos não estão atribuídos. Gravar com pinos de saída errados não funciona
e pode danificar a FPGA.

O caminho seguro:

1. No Quartus, **Assignments → Import Assignments**
2. Importe o `DE0_CV.qsf` que acompanha o CD/Resources da Terasic
3. Apague o bloco de `set_location_assignment` do `SMMA.qsf`

Os nomes das portas do top level (`CLOCK_50`, `KEY`, `SW`, `LEDR`,
`HEX0`..`HEX5`) foram escolhidos **iguais aos do `DE0_CV.qsf` oficial**
justamente para que essa importação case sem renomear nada.

---

## Compilar

```bash
# pela interface
quartus quartus/SMMA.qpf

# ou pela linha de comando, da raiz do repositório
quartus_sh --flow compile quartus/SMMA
```

### O ponto que mais costuma falhar: os `.hex`

Quatro módulos carregam memória por `$readmemh` com caminho **relativo**:

| arquivo | conteúdo | tamanho |
|---|---|---|
| `vetores/demo_amostras.hex` | 12 janelas do dataset, 8503 amostras cada | 204 kB |
| `vetores/demo_rotulos.hex` | rótulo verdadeiro + previsão do modelo | 6 B |
| `vetores/arvore.hex` | 141 nós da árvore de decisão | 564 B |
| `vetores/fir_coef.hex` | 63 coeficientes do FIR anti-alias | 126 B |

Na simulação o caminho vale a partir de `RTL/`; na síntese, a partir do
diretório do projeto. Por isso o `.qsf` traz

```tcl
set_global_assignment -name SEARCH_PATH ../RTL
set_global_assignment -name SEARCH_PATH ../RTL/vetores
```

**Se o Quartus não achar um `.hex`, ele infere a ROM ZERADA e compila sem
erro.** O sintoma na placa é o classificador respondendo sempre a mesma
classe — fácil de confundir com um bug de lógica. Ao compilar, procure no
relatório por avisos de *memory initialization file*.

A ROM do dataset são 204 kB, cerca de 52% dos 384 kB de M10K da Cyclone V.
Ela tem de ir para blocos M10K: em LUTs não cabe. Confira em
**Fitter → Resource Utilization** que os M10K foram usados; se a síntese
tentar LUTs, o projeto não fecha.

---

## Usar na bancada

| controle | função |
|---|---|
| `KEY[0]` | reset |
| `KEY[1]` | dispara uma janela (uma tecla por medida) |
| `SW[3:0]` | escolhe a janela do dataset (0..11) |
| `SW[9]` | troca `LEDR[3:0]` para os scores da CNN |

| display | mostra |
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
| `LEDR[6]` | as duas concordam |
| `LEDR[8]` | ocupado |
| `LEDR[9]` | resultado válido |

Cada janela leva **332 ms** de tempo real (8503 amostras a 25,6 kHz), porque a
`Sample_Source` reproduz o dataset na taxa original do sensor. O `LEDR[8]`
fica aceso durante esse tempo.

O resultado esperado é **11 das 12 janelas corretas**. A janela 8
(`4Nm_Normal`) é lida como desbalanceamento — **é um erro do modelo, não do
hardware**, e a simulação ponta a ponta exige que o hardware o reproduza. A
degradação com carga é justamente o que o relatório discute.

---

## Verificar antes de sintetizar

```bash
cd RTL
./run_regressao.sh              # todos os testbenches (Icarus Verilog)
./run_regressao.sh tb_SMMA_Top  # só o teste ponta a ponta
```

O `tb_SMMA_Top` roda o sistema inteiro pelos **mesmos pinos da placa**, sem
alcançar nenhum sinal interno, e confere que a árvore em hardware reproduz o
modelo Python nas 12 janelas. Ele usa `MODO_RAPIDO = 1`, que desliga o divisor
de taxa de 25,6 kHz da fonte — sem isso cada janela custaria 16 milhões de
ciclos de simulação. **O parâmetro tem de voltar a `0` para a síntese**, e é
esse o padrão do `SMMA_Top`.

O `run_sim.sh` do diretório `RTL/` é para Cadence Xcelium (laboratório); o
`run_regressao.sh` depende só do `iverilog` e roda em qualquer máquina.

---

## Relógio

Um único domínio: o `CLOCK_50` da placa. Sem PLL, sem relógio derivado, sem
travessia entre domínios. O `SMMA.sdc` declara o período de 20 ns e marca
`KEY`, `SW`, `LEDR` e os `HEX` como `false_path` — são chaves mecânicas e LEDs,
e restringi-los só encheria o relatório de falhas de I/O que escondem as do
caminho interno.

Os dois botões passam por dois registradores dentro do `SMMA_Top` antes de
chegar a qualquer FSM; é isso que trata a metaestabilidade, não o `false_path`.

---

## Pendências conhecidas

- **Pinos dos displays de 7 segmentos** não atribuídos (ver acima).
- **Utilização de recursos não medida.** Não há Quartus neste ambiente, então
  nenhum número de ALMs, DSPs ou M10K foi verificado por síntese. O orçamento
  de DSPs foi planejado (4 na FFT, 8 na CNN, 1 em cada extrator de features),
  mas confirme no relatório do Fitter.
- **`tb_LMS_Control_FSM` falha** (8 divergências de contador, a partir da 6).
  É falha **pré-existente** da branch `feat/LMS`, não introduzida aqui. O
  `LMS_Control_FSM` está **fora do caminho de dados entregue**: não aparece no
  `SMMA_Top.v` nem neste `.qsf`, porque o `Feature_Temporal.v` reimplementa o
  preditor LMS internamente (8 taps, μ=2⁻³) com sua própria FSM. O
  `tb_LMS_Filter_Top`, que instancia essa mesma FSM, passa — então vale
  investigar se a divergência é do módulo ou do testbench antes de confiar no
  `LMS_Filter_Top.v` para outro uso.

- `RTL/tb_pipeline_completo.v` testa a cadeia AR (`autocorrelacao_yw` +
  `gauss_jordan_inv`), que **saiu do caminho de dados** quando ρ1..ρ3
  substituíram os coeficientes AR. Os dois módulos continuam no repositório e
  o testbench está quebrado; nenhum dos dois entra no `SMMA.qsf`.
- Arquivos com espaço e parêntese no nome (`gauss_jordan_inv (2).v`,
  `fixed_point_divider (1).v`) são cópias de trabalho; o `run_regressao.sh` os
  ignora e o `.qsf` não os inclui.
