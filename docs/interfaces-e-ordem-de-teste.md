# SMMA — Interfaces dos módulos e ordem de teste

Mapa das entradas e saídas de cada bloco e a ordem em que levá-los ao Quartus.
Portas conferidas contra o RTL (não de memória); larguras mostradas para os
parâmetros padrão (`WIDTH = 16`, Q1.15).

---

## 1. Convenções válidas para todo o projeto

Antes das tabelas, três contratos que se repetem em quase todo módulo. Entender
estes três elimina a maior parte do trabalho de ler as tabelas.

### 1.1 Relógio e reset

| porta | dir | descrição |
|---|---|---|
| `clk` | in | `CLOCK_50`, **único domínio de relógio do projeto**. Sem PLL, sem relógio derivado, sem travessia entre domínios. |
| `rst` | in | Reset **síncrono, ativo em ALTO**. Os botões da DE0-CV são ativos em baixo; a inversão acontece **uma única vez**, no `SMMA_Top`. |

### 1.2 Handshake de dados: `valid` / `ready`

Todo fluxo de dados entre blocos usa o mesmo par:

```
in_valid   produtor: "há dado válido em in_* neste ciclo"
in_ready   consumidor: "aceito o dado neste ciclo"
```

A transferência acontece **no ciclo em que os dois estão altos**. Regras:

- o produtor **não pode** retirar `valid` antes de a transferência ocorrer;
- `ready` **não pode** depender de `valid` (senão trava);
- `valid` **pode** depender de `ready` (é o que permite os *joins* do top level).

Quando um fluxo alimenta dois consumidores, o `SMMA_Top` faz um **join**:
`ready = AND` dos dois e `valid` replicado. Entregar a um e não ao outro
dessincronizaria os dois classificadores silenciosamente — eles passariam a
decidir sobre janelas diferentes.

### 1.3 Controle de bloco: `start` / `ready` / `busy` / `done`

| porta | dir | descrição |
|---|---|---|
| `start` | in | Pulso de **1 ciclo** que inicia uma operação. Aceito só quando `ready = 1`. |
| `ready` | out | Em repouso, pronto para novo `start`. |
| `busy` | out | Operação em andamento. |
| `done` | out | Pulso de **1 ciclo** ao concluir. |
| `enable` | in | Habilitação global (onde existe). Congela o bloco quando baixo. |

> **Atenção ao `done`.** Ele não significa a mesma coisa em todos os blocos. No
> `Spectrogram_Buffer`, `done` sobe depois de a imagem ter sido **drenada**, não
> quando ela ficou pronta — usá-lo para disparar a CNN seria tarde demais,
> porque os pixels já teriam passado. É por isso que no `SMMA_Top` a CNN arranca
> junto com os demais blocos e simplesmente espera no handshake de carga.

### 1.4 Formato numérico

**Q1.15**: inteiro de 16 bits com sinal, 15 bits fracionários, faixa
[-1, +0,999969]. Fundo de escala do sensor: **±32 g**.

Multiplicação Q1.15 com arredondamento meio-para-cima e saturação:
`sat16((a*b + 2^14) >> 15)`.

> Toda a aritmética dos extratores precisa casar **bit a bit** com
> `python/smma/features.py`, porque os limiares da árvore foram aprendidos sobre
> aqueles números. Uma diferença de poucos LSB não "quase acerta" — ela move a
> fronteira de decisão e pode trocar a classe.

---

## 2. Grupo: Aquisição

```
Sample_Source --25,6 kHz--> FIR_Decimator --3,2 kHz--> Frame_Builder --quadros de 64-->
```

### `Sample_Source` — dataset em ROM

Reproduz 12 janelas do dataset na taxa original do sensor. É a fonte que
substitui o ADC na demonstração.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia a reprodução de uma janela |
| `janela` | in | 4 | qual das 12 janelas (`SW[3:0]`) |
| `busy` / `done` | out | 1 | reproduzindo / janela terminou |
| `out_valid` / `out_ready` | out/in | 1 | handshake de saída |
| `out_sample` | out | 16 | amostra crua Q1.15 |
| `classe_verdadeira` | out | 2 | rótulo real da janela |
| `classe_esperada` | out | 2 | **previsão do modelo Python** para esta janela |

Parâmetros relevantes: `N_AMOSTRAS = 8503` (uma janela), `DIV_TAXA = 1953`
(50 MHz ÷ 25,6 kHz), `MODO_RAPIDO` (1 ignora a taxa, só para simulação).

`classe_esperada` existe para o teste: comparar o hardware com ela verifica que
a cadeia reproduz o **modelo**, o que é mais forte que comparar com o rótulo
verdadeiro — o hardware poderia acertar o rótulo por acaso calculando as
características erradas.

### `FIR_Decimator` — anti-alias + decimação ÷8

63 taps com corte em 1,4 kHz, **um único multiplicador** reusado.

| porta | dir | largura | descrição |
|---|---|---|---|
| `limpa` | in | 1 | **pulso por janela**: zera linha de atraso, fase e preenchimento |
| `in_valid` / `in_ready` | in/out | 1 | entrada a 25,6 kHz |
| `in_sample` | in | 16 | Q1.15 |
| `out_valid` / `out_ready` | out/in | 1 | saída a 3,2 kHz |
| `out_sample` | out | 16 | Q1.15 |
| `overflow` | out | 1 | alguma saída saturou |

> **`limpa` é obrigatório entre janelas.** Uma janela tem 8503 amostras cruas e
> 8503 mod 8 = 7, então sem limpar cada janela desloca a fase da decimação em 7
> e a contagem de saídas deixa de ser 1056. Com 1055, o `Feature_Temporal` nunca
> recebe a amostra marcada como última e **o sistema inteiro para**. Também é
> necessário para equivalência: o modelo convolve cada janela de forma
> independente (`mode="valid"`).

### `Frame_Builder` — quadros de 64 com salto de 32

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia uma janela de 32 quadros |
| `ready`/`busy`/`done` | out | 1 | controle padrão |
| `in_valid` / `in_ready` | in/out | 1 | amostras decimadas |
| `in_sample` | in | 16 | Q1.15 |
| `out_valid` / `out_ready` | out/in | 1 | handshake para a FFT |
| `out_sample` | out | 16 | amostra do quadro |
| `out_frame_ini` | out | 1 | 1 na **primeira** amostra do quadro |
| `out_frame_fim` | out | 1 | 1 na **64ª** amostra do quadro |

Buffer circular de 64×16 com leitura **combinacional** (cabe em LUT-RAM). Ele
baixa `in_ready` enquanto despeja um quadro — não perde amostra porque a fonte
respeita contrapressão, e a 3,2 kHz há 15.625 ciclos entre amostras contra 64 do
despejo.

`out_frame_ini` e `out_frame_fim` existem porque a `FFT_Top` só levanta
`in_ready` **depois** do pulso de `start`: o top level usa `frame_ini` para
armar a FFT e `frame_fim` para desarmá-la.

---

## 3. Grupo: FFT

```
FFT_Top
 ├── FFT_Control_FSM ── FFT_Addr_Gen, FFT_Bit_Reverse
 ├── FFT_Butterfly ──── FP_Mult_Unit (x4)
 ├── FFT_Memory
 ├── FFT_Twiddle_ROM
 └── FFT_Magnitude
FFT_Log2_Compress (usado depois, pelo espectrograma)
```

### `FFT_Top` — a interface que importa

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` / `enable` | in | 1 | inicia transformada / habilitação |
| `ready`/`busy`/`done` | out | 1 | controle padrão |
| `in_valid` / `in_ready` | in/out | 1 | carga das 64 amostras |
| `in_real` / `in_imag` | in | 16 | `x[n]`; `in_imag = 0` para sinal real |
| `out_valid` / `out_ready` | out/in | 1 | handshake de saída |
| `out_index` | out | 6 | índice `k` do bin (**0..63, ordem natural**) |
| `out_real` / `out_imag` | out | 16 | `Re/Im{X[k]}` ÷16 |
| `out_mag` | out | 16 | `\|X[k]\|` ÷16, sem sinal |
| `stage_dbg` | out | 3 | estágio corrente (1..6), depuração |

Parâmetro `SCALE_MASK = 6'b001111` → ganho total ÷16, igual ao do treinamento.

> **A saída sai em ordem natural de frequência** (0, 1, 2, ..., 63). A inversão
> de bits acontece na **carga**, não na leitura. Isso é o que permite que o
> `Feature_Spectral` e o `Spectrogram_Buffer` assumam bins sequenciais.
>
> Para sinal real o espectro é simétrico, então só os bins 0..31 interessam. Os
> bins 32..63 têm de ser **aceitos e descartados** — deixar de aceitá-los
> travaria a FFT no despejo.

### Submódulos da FFT

| módulo | entradas | saídas | papel |
|---|---|---|---|
| `FFT_Bit_Reverse` | `index_in[5:0]` | `index_out[5:0]` | combinacional, inverte os bits do índice |
| `FFT_Addr_Gen` | `stage[2:0]`, `bfly_idx[4:0]` | `addr_p[5:0]`, `addr_q[5:0]`, `tw_addr[4:0]` | combinacional, endereços do par da borboleta |
| `FFT_Memory` | 2 portas: `a_addr/a_we/a_din`, `b_addr/b_we/b_din` | `a_dout`, `b_dout` | RAM dupla porta, 32 bits (Re\|Im), **leitura registrada** |
| `FFT_Twiddle_ROM` | `rd_en`, `rd_addr[4:0]` | `w_real`, `w_imag` | fatores de rotação Q1.15 |
| `FFT_Butterfly` | `in_valid`, `scale_en`, `a_real/imag`, `b_real/imag`, `w_real/imag` | `out_valid`, `p_real/imag`, `q_real/imag` | borboleta radix-2, **latência de 6 ciclos** |
| `FFT_Magnitude` | `en`, `in_valid`, `in_real`, `in_imag` | `out_valid`, `out_mag` | alpha-max-beta-min: `max + min/4 + min/8` |
| `FFT_Log2_Compress` | `en`, `in_valid`, `in_mag` | `out_valid`, `out_pixel` | log2 de Mitchell, **zero DSP** |
| `FFT_Control_FSM` | `start`, `enable`, `in_valid`, `out_ready` | `mem_*`, `tw_*`, `bf_in_valid`, `bf_scale_en`, `unload_*`, `out_pipe_adv`, `stage_out` | sequencia os 6 estágios |

Notas que custaram depuração:

- `FFT_Butterfly.scale_en` vem de `SCALE_MASK[stage-1]` e precisa de uma linha
  de atraso de 5 estágios para acompanhar a latência da borboleta.
- O `en` do `FFT_Log2_Compress` serve de **skid de um nível**: com
  `en = consumidor_ready`, o pixel registrado só é substituído quando o
  consumidor puder receber.
- A `FFT_Memory` **não tem clock-enable**. Um endereço visível por apenas um
  ciclo podia cair num ciclo de estol; a FSM resolve isso com `unload_phase`
  (dois ciclos aceitos por bin).

### Aritmética comum

| módulo | entradas | saídas | papel |
|---|---|---|---|
| `FP_Mult_Unit` | `in_A`, `in_B` | `out_Y` | multiplicador em ponto fixo, larguras e pontos binários parametrizáveis |
| `FP_Arith_Unit` | `add_sub`, `in_A`, `in_B` | `out_Y` | somador/subtrator em ponto fixo |

---

## 4. Grupo: Características

```
|X[k]| bins 0..31 ──> Feature_Spectral ──> 8 features ─┐
                                                        ├─> 12 features
sinal decimado ─────> Feature_Temporal ──> 4 features ─┘
                           (ambos usam Divider_Q15)
```

### `Divider_Q15` — divisor compartilhado

Divisão por restauração, sem sinal. O sinal é tratado **fora** dele.

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia a divisão |
| `ready` / `done` | out | 1 | pronto / terminou |
| `num` / `den` | in | `NUM_W`/`DEN_W` | numerador e denominador |
| `quociente` | out | 16 | `(num << 15) / den`, saturado em 32767 |
| `div_zero` | out | 1 | denominador nulo |

> **`done` e `ready` sobem no MESMO ciclo.** Quem consome tem de testar `done`
> **antes** de `ready`; testando `ready` primeiro, a FSM reinicia a divisão que
> acabou de terminar e nunca captura o resultado — travando para sempre. Esse bug
> apareceu no `Feature_Spectral`.
>
> São `FRAC` (15) iterações, não 16. Com 16 todos os resultados dobram.

### `Feature_Spectral` — as 8 características espectrais

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia uma janela |
| `ready`/`busy`/`done` | out | 1 | controle padrão |
| `in_valid` / `in_ready` | in/out | 1 | handshake |
| `in_mag` | in | 16 | `\|X[k]\|`, **1024 valores** (32 quadros × 32 bins) |
| `out_valid` / `out_ready` | out/in | 1 | handshake |
| `out_feature` | out | 16 | uma das 8, em sequência, Q1.15 |

Saídas na ordem: `r_1x`, `r_2x`, `r_3x`, `r_banda1`, `r_banda2`, `r_banda3`,
`log2E`, `centroide`. Latência ~1170 ciclos (23 µs). Zero DSP.

### `Feature_Temporal` — as 4 características temporais

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia uma janela |
| `ready`/`busy`/`done` | out | 1 | controle padrão |
| `in_valid` / `in_ready` | in/out | 1 | handshake |
| `in_sample` | in | 16 | amostra decimada, **1056 por janela** |
| `in_last` | in | 1 | **marca a última amostra** — sem ela o bloco nunca conclui |
| `out_valid` / `out_ready` | out/in | 1 | handshake |
| `out_feature` | out | 16 | `r_lms`, `rho1`, `rho2`, `rho3`, em sequência |

Um multiplicador 16×16 serve às 20 multiplicações por amostra. Latência 26.460
ciclos (529 µs) contra orçamento de 320 ms.

> Duas histórias separadas, de propósito: `hist[0:7]` para o preditor (começa
> vazia, **`x[0]` nunca entra nela**) e `hac[0:2]` para a autocorrelação (recebe
> todas as amostras, inclusive `x[0]`). Compartilhar uma só fazia `r_lms`
> divergir até 30 LSB.

---

## 5. Grupo: Classificador numérico

### `ML_Tree_Classifier` — percurso da árvore em ROM

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` / `enable` | in | 1 | inicia classificação / habilitação |
| `ready`/`busy`/`done` | out | 1 | controle padrão |
| `in_valid` / `in_ready` | in/out | 1 | handshake |
| `in_feature` | in | 16 | **12 características, NA ORDEM DO TREINAMENTO** |
| `out_valid` / `out_ready` | out/in | 1 | handshake |
| `out_class` | out | 2 | 0 normal, 1 desbalanceamento, 2 desalinhamento, 3 rolamento |
| `out_error` | out | 1 | percurso não terminou em folha |

Parâmetros: `N_FEATURES = 12`, `N_NOS = 141`, `PROF_MAX = 9`,
`ARQ_ROM = "vetores/arvore.hex"`. Latência 21 ciclos.

Ordem das características (índices 0..11): as 8 espectrais, depois `r_lms`,
`rho1`, `rho2`, `rho3`.

> **Trocar a ordem não gera erro em lugar nenhum** — só uma classificação
> errada, silenciosa. No top level o índice vem de um contador único por isso.

Codificação de um nó (32 bits): `bit31` = folha, `[30:27]` = característica,
`[26:11]` = limiar Q1.15, `[10:3]` = filho direito, `[1:0]` = classe da folha.

---

## 6. Grupo: Espectrograma e CNN

```
Spectrogram_Buffer (32x32, transposto) ──> CNN_Top
                                            ├── CNN_Control_FSM
                                            ├── CNN_Line_Buffer
                                            ├── CNN_Conv_Layer ──── CNN_MAC_Unit, CNN_ReLU, CNN_Weight_ROM
                                            ├── CNN_MaxPool
                                            └── CNN_Dense_Classifier ─ CNN_MAC_Unit, CNN_ReLU, CNN_Weight_ROM
```

### `Spectrogram_Buffer`

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` | in | 1 | inicia uma imagem |
| `ready`/`busy`/`done` | out | 1 | **`done` = imagem DRENADA**, não pronta |
| `in_valid` / `in_ready` | in/out | 1 | handshake |
| `in_pixel` | in | 16 | já comprimido em log2, 1024 pixels |
| `out_valid` / `out_ready` | out/in | 1 | handshake |
| `out_pixel` | out | 16 | sem sinal (0..32767); liga direto no `in_pixel` com sinal da CNN |

Escrita em `quadro*32 + bin`, leitura em `col*32 + lin` — é aqui que a
transposição acontece.

### `CNN_Top`

| porta | dir | largura | descrição |
|---|---|---|---|
| `start` / `enable` | in | 1 | processa uma imagem / habilitação |
| `in_valid` / `in_ready` | in/out | 1 | handshake |
| `in_pixel` | in | 16 | pixel do espectrograma, com sinal |
| `busy`/`ready`/`done` | out | 1 | controle padrão |
| `valid_out` | out | 1 | pulso: resultado válido |
| `out_class` | out | 2 | classe predita |
| `out_scores` | out | 4×16 | scores brutos (depuração) |
| `out_features` | out | 8×16 | saída do GAP (depuração) |

### Submódulos da CNN

| módulo | entradas | saídas | papel |
|---|---|---|---|
| `CNN_Weight_ROM` | `tap_addr[3:0]`, `dense_addr[4:0]`, `dense_bias_addr[1:0]` | `conv_w`, `conv_bias`, `dense_w`, `dense_bias` | ROM combinacional, organizada **por tap** |
| `CNN_ReLU` | `in_acc[39:0]` | `out_y[15:0]` | combinacional, satura e ativa |
| `CNN_MAC_Unit` | `en`, `first`, `last`, `init_acc`, `in_a`, `in_b` | `out_acc[39:0]`, `out_valid` | acumulador multiplicador |
| `CNN_Line_Buffer` | `start`, `push_en`, `win_ack`, `in_pixel` | `need_pixel`, `last_push`, `out_win[143:0]`, `win_valid`, `out_row`, `out_col` | janela deslizante 3×3 |
| `CNN_Conv_Layer` | `win_valid`, `win_data[143:0]` | `win_ready`, `out_valid`, `out_data[127:0]` | 8 filtros 3×3 |
| `CNN_MaxPool` | `start`, `in_valid`, `in_data` | `out_valid`, `out_data` | pooling 2×2 |
| `CNN_Dense_Classifier` | `start`, `in_valid`, `in_data`, `run` | `out_valid`, `out_class`, `out_scores`, `out_features` | GAP + camada densa |
| `CNN_Control_FSM` | `start`, `enable`, `in_valid`, `need_pixel`, `last_push`, `conv_ready`, `pool_out_valid`, `dense_done` | `in_ready`, `busy`, `ready`, `done`, `valid_out`, `frame_start`, `push_en`, `dense_run` | sequencia a inferência |

---

## 7. Top level

### `SMMA_Top` — pinos da placa

| porta | dir | largura | descrição |
|---|---|---|---|
| `CLOCK_50` | in | 1 | relógio de 50 MHz |
| `KEY` | in | 2 | **ativo em BAIXO**: `[0]` reset, `[1]` dispara uma janela |
| `SW` | in | 10 | `[3:0]` janela (0..11), `[9]` troca `LEDR[3:0]` para scores da CNN |
| `LEDR` | out | 10 | ver abaixo |
| `HEX0`..`HEX5` | out | 7 cada | displays, **ativos em BAIXO** |

| display | mostra | | LED | significado |
|---|---|---|---|---|
| `HEX0` | classe da **árvore** | | `LEDR[3:0]` | árvore em one-hot (ou scores) |
| `HEX1` | classe da **CNN** | | `LEDR[4]` | árvore acertou |
| `HEX2` | classe **verdadeira** | | `LEDR[5]` | CNN acertou |
| `HEX3` | `E` se erro de percurso ou saturação | | `LEDR[6]` | as duas concordam |
| `HEX5:4` | índice da janela | | `LEDR[8]` / `LEDR[9]` | ocupado / resultado válido |

Unidade de controle, 5 estados: `E_PARADO` → `E_ARRANCA` (pulso único de start
em todos os blocos da aquisição, para que comecem no **mesmo ciclo**) →
`E_ADQUIRE` (1056 amostras, 32 quadros) → `E_DECIDE` (árvore e CNN **em
paralelo**) → `E_PRONTO` (volta sozinho; o painel não apaga).

---

## 8. Módulos fora do caminho de dados

Preservados das branches de origem, **não instanciados** pelo `SMMA_Top` nem
listados no `SMMA.qsf`:

| módulo | situação |
|---|---|
| `LMS_Filter_Top` + `LMS_Control_FSM`, `LMS_Input_Delay_Line`, `LMS_Weight_Storage`, `LMS_Processing_Element`, `LMS_Accumulator_Error_Scale` | O `Feature_Temporal.v` **reimplementa** o preditor LMS (8 taps, μ=2⁻³) com FSM própria. O `tb_LMS_Control_FSM` **falha** (8 divergências), falha pré-existente da branch `feat/LMS`. |
| `autocorrelacao_yw`, `gauss_jordan_inv (2)`, `fixed_point_divider (1)` | A cadeia AR saiu do projeto quando ρ1..ρ3 substituíram os coeficientes AR. Os dois testbenches **travam** (`$stop`). |
| `peak_detector`, `mdc_gcd`, `f0_estimator` | Não entraram no caminho final. |

---

## 9. Hierarquia de instanciação

```
SMMA_Top
├── Sample_Source                 (folha, ROM 204 kB)
├── FIR_Decimator                 (folha)
├── Frame_Builder                 (folha)
├── FFT_Top
│   ├── FFT_Control_FSM
│   │   ├── FFT_Addr_Gen          (folha, combinacional)
│   │   └── FFT_Bit_Reverse       (folha, combinacional)
│   ├── FFT_Butterfly
│   │   └── FP_Mult_Unit x4       (folha)
│   ├── FFT_Memory                (folha)
│   ├── FFT_Twiddle_ROM           (folha)
│   └── FFT_Magnitude             (folha)
├── FFT_Log2_Compress             (folha)
├── Feature_Spectral
│   └── Divider_Q15               (folha)
├── Feature_Temporal
│   └── Divider_Q15               (folha)
├── ML_Tree_Classifier            (folha, ROM 564 B)
├── Spectrogram_Buffer            (folha)
└── CNN_Top
    ├── CNN_Control_FSM           (folha)
    ├── CNN_Line_Buffer           (folha)
    ├── CNN_Conv_Layer
    │   ├── CNN_MAC_Unit          (folha)
    │   ├── CNN_ReLU              (folha, combinacional)
    │   └── CNN_Weight_ROM        (folha, combinacional)
    ├── CNN_MaxPool               (folha)
    └── CNN_Dense_Classifier
        ├── CNN_MAC_Unit
        ├── CNN_ReLU
        └── CNN_Weight_ROM
```

---

## 10. Ordem de teste

### 10.1 O que o Quartus verifica — e o que ele NÃO verifica

Vale separar isso antes da lista, porque é o erro mais comum:

| ferramenta | responde |
|---|---|
| **Simulação** (`run_regressao.sh`) | O módulo calcula **certo**? |
| **Quartus Analysis & Synthesis** | Elabora? Infere a memória certa (M10K vs LUT)? Quantos DSPs? |
| **Quartus Fitter** | Cabe no dispositivo? |
| **TimeQuest** | Fecha em 50 MHz? |

**O Quartus não verifica função.** Um módulo que sintetiza, cabe e fecha tempo
pode estar calculando a coisa errada. Por isso cada etapa abaixo tem **duas
portas**: a funcional (simulação) e a de implementação (Quartus). Não avance sem
as duas.

Para testar um módulo isolado no Quartus: **Project → Set as Top-Level Entity**
sobre o arquivo dele, rodar *Analysis & Synthesis*, e depois devolver
`SMMA_Top` como top.

### 10.2 Ordem recomendada — de baixo para cima

A ordem segue a hierarquia da seção 9. A razão de ir de baixo para cima é
prática: um erro de arredondamento no multiplicador aparece como classe errada
no top level, e você o depuraria no lugar errado.

---

#### Etapa 0 — Aritmética base

`FP_Mult_Unit` → `FP_Arith_Unit` → `Divider_Q15`

**Por que primeiro:** todo bin da FFT e toda característica passa por estes.
Um erro de saturação ou de arredondamento aqui contamina tudo acima.

- Simulação: `./run_regressao.sh tb_FP_Mult_Unit` (2005 operações),
  `tb_FP_Arith_Unit`, `tb_Divider_Q15`.
- Quartus: confirmar que o multiplicador vira **DSP**, não LUTs.
- **Porta:** os três passam. O `Divider_Q15` é o mais crítico — confira que são
  15 iterações, não 16.

#### Etapa 1 — Aquisição

`Sample_Source` → `FIR_Decimator` → `Frame_Builder`

Independentes entre si; cada um tem referência exata em Python.

- Simulação: `tb_Sample_Source`, `tb_FIR_Decimator`, `tb_Frame_Builder`.
- Quartus: **este é o maior risco de fitting do projeto.** A ROM do
  `Sample_Source` tem 204 kB (~52% da M10K da Cyclone V) e **tem** de ir para
  blocos M10K. Verifique em *Fitter → Resource Utilization*. Se a ferramenta
  tentar LUTs, o projeto não fecha.
- Quartus: procure avisos de **memory initialization file** não encontrado. Se o
  `.hex` não for achado, o Quartus **infere a ROM zerada e compila sem erro** —
  e o sintoma na placa é o classificador responder sempre a mesma classe.
- **Porta:** os três passam, a ROM está em M10K, nenhum aviso de `.hex`.

#### Etapa 2 — FFT

**2a. Folhas:** `FFT_Bit_Reverse`, `FFT_Addr_Gen`, `FFT_Twiddle_ROM`,
`FFT_Memory`, `FFT_Magnitude`, `FFT_Log2_Compress`

- Simulação: `tb_FFT_Log2_Compress` (verificado nas 65536 entradas).
- **Porta:** elaboram e a ROM de twiddles está correta.

**2b.** `FFT_Butterfly` — depende da Etapa 0.
Atenção à latência de 6 ciclos e ao alinhamento de `scale_en`.

**2c.** `FFT_Control_FSM` — depende de 2a.

**2d.** `FFT_Top` — integra tudo.

- Simulação: `./run_regressao.sh tb_FFT_Top` (13 verificações).
- Quartus: 4 DSPs esperados (os `FP_Mult_Unit` da borboleta).
- **Porta:** `tb_FFT_Top` passa **inclusive sob contrapressão**. Dois bugs de
  alinhamento índice-contra-dado só apareceram com o consumidor estolando.

#### Etapa 3 — Características

**3a.** `Feature_Spectral` — depende do `Divider_Q15`.
**3b.** `Feature_Temporal` — depende do `Divider_Q15`.

- Simulação: `tb_Feature_Spectral` (8 janelas × 8 features, bit a bit),
  `tb_Feature_Temporal` (6 janelas × 4 features, bit a bit).
- **Porta:** comparação **bit a bit** com o modelo, não por tolerância. Um
  desvio de poucos LSB move a fronteira de decisão da árvore.

#### Etapa 4 — Classificador numérico

`ML_Tree_Classifier`

- Simulação: `tb_ML_Tree_Classifier` (64 casos, bit a bit).
- Quartus: ROM de 564 B; confira que o `arvore.hex` foi carregado.
- **Porta:** 64/64 e `N_NOS` igual ao número de palavras do `arvore.hex` (141).

#### Etapa 5 — Espectrograma e CNN

**5a. Folhas:** `CNN_Weight_ROM`, `CNN_ReLU`, `CNN_MAC_Unit`,
`CNN_Line_Buffer`, `CNN_MaxPool`, `Spectrogram_Buffer`

**5b.** `CNN_Conv_Layer`, `CNN_Dense_Classifier` — dependem de 5a.

**5c.** `CNN_Control_FSM`

**5d.** `CNN_Top`

- Simulação: os 9 `tb_CNN_*` e `tb_Spectrogram_Buffer`.
- Quartus: ~8 DSPs esperados (um por filtro).
- **Porta:** `tb_CNN_Top` passa e o `Spectrogram_Buffer` transpõe certo
  (escrita `quadro*32 + bin`, leitura `col*32 + lin`).

#### Etapa 6 — Top level

`SMMA_Top`

- Simulação: `./run_regressao.sh tb_SMMA_Top` (~2 min). Exercita o sistema
  pelos **mesmos pinos da placa**, sem alcançar sinal interno.
- **Porta funcional:** a árvore em hardware reproduz o modelo nas **12 janelas**,
  11/12 contra os rótulos verdadeiros. A janela 8 (`4Nm_Normal`) é lida como
  desbalanceamento — **erro do modelo**, e o teste exige que o hardware o
  reproduza.
- Quartus: `MODO_RAPIDO` tem de estar em **0** (é o padrão). Rodar compilação
  completa, conferir *Resource Utilization* e TimeQuest ≥ 50 MHz.
- **Antes de gravar:** importar o `DE0_CV.qsf` da Terasic. A pinagem do
  `SMMA.qsf` **não foi conferida** e os displays de 7 segmentos não estão
  atribuídos.

#### Etapa 7 (opcional) — Trilha dos módulos fora do caminho

Só se houver intenção de sintetizá-los. **Não são pré-requisito de nada acima.**

1. `LMS_Control_FSM` — **corrigir primeiro**: `tb_LMS_Control_FSM` falha com 8
   divergências de contador. Curiosamente o `tb_LMS_Filter_Top`, que instancia
   essa mesma FSM, passa — então o primeiro passo é descobrir se a divergência é
   do módulo ou do testbench.
2. `LMS_Input_Delay_Line`, `LMS_Weight_Storage`, `LMS_Accumulator_Error_Scale`,
   `LMS_Processing_Element` — todos passam.
3. `LMS_Filter_Top` — passa.
4. `autocorrelacao_yw` e a cadeia AR — os testbenches **travam** no `$stop` e
   precisam ser reescritos antes de qualquer conclusão.

> A ordem do exemplo "1) módulos do LMS" é razoável para a branch `feat/LMS`,
> mas **não** para esta integração: o LMS do caminho de dados vive dentro do
> `Feature_Temporal.v`, com FSM própria. Começar pelo `LMS_Filter_Top` testaria
> um bloco que o `SMMA_Top` não instancia.

### 10.3 Resumo da ordem

```
0. FP_Mult_Unit, FP_Arith_Unit, Divider_Q15
1. Sample_Source, FIR_Decimator, Frame_Builder        <- risco de fitting (M10K)
2. FFT: folhas -> Butterfly -> Control_FSM -> FFT_Top
3. Feature_Spectral, Feature_Temporal
4. ML_Tree_Classifier
5. CNN: folhas -> Conv/Dense -> Control_FSM -> CNN_Top
6. SMMA_Top                                            <- compilação completa
---
7. (opcional) trilha LMS / AR, fora do caminho de dados
```

Estado atual: **27 dos 30 testbenches passam**. As três pendências estão todas
na Etapa 7.
