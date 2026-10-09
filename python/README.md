# Python — treino, quantização e geração das ROMs

O hardware só faz a **inferência**. Tudo o que é aprendido (pesos da CNN,
árvore de decisão, coeficientes do FIR) e todos os vetores dos testbenches são
gerados aqui. **Não é preciso rodar nada para usar a placa**: as saídas já estão
no repositório.

## Pastas

| pasta | conteúdo |
|---|---|
| `config.py` | todos os parâmetros e caminhos do fluxo |
| `smma/` | `espectrograma.py` (especificação FIR → FFT → log2 → imagem), `features.py` (as 12 características, bit a bit com o RTL), `modelo.py` (a CNN do RTL em PyTorch), `golden.py` (modelo bit-exato vetorizado) |
| `scripts/` | passos 01 a 11 (tabela abaixo) |
| `resultados/` | pesos treinados (`modelo_16b.pt`, `pesos_16b.npz`), árvore (`arvore_float.npz`, `comparacao_clf.npz`), relatórios gerados (`relatorio.md`, `relatorio_clf.md`) e `matriz_confusao.png` |

## Passos

Rodar da raiz do repositório (`pip install -r python/requirements.txt`; `torch`
só é preciso nos passos 03–05).

| passo | script | gera |
|---|---|---|
| 01 | `01_converter_csv.py` (ou `01b_converter_mat.py`) | `dados/processado/brutos/*.npy` |
| 02 | `02_gerar_espectrogramas.py` | `dados/processado/espectrogramas/dataset.npz` |
| 03 | `03_treinar.py [--bits 16/8/4]` | `resultados/modelo_16b.pt`, `pesos_16b.npz` |
| 04 | `04_avaliar_ponto_fixo.py` | `resultados/relatorio.md`, `matriz_confusao.png` |
| 05 | `05_exportar_rtl.py` | `RTL/cnn/CNN_Weight_ROM.v`, `sim/golden/golden_model_cnn.py`, vetores da CNN |
| 06 | `06_gerar_features.py` | `dados/processado/features/features.npz` |
| 07 | `07_treinar_classificador.py` | árvore × SVM, `resultados/relatorio_clf.md` |
| 08 | `08_exportar_classificador.py` | `quartus/vetores/arvore.hex`, `clf_teste.hex` |
| 09 | `09_exportar_frontend.py` | `fir_coef.hex`, `fir_teste.hex` |
| 10 | `10_exportar_demo_fpga.py` | `demo_amostras.hex`, `demo_rotulos.hex` (12 janelas da placa) |
| 11 | `11_exportar_vetores_features.py` | `feat_teste.hex`, `temp_teste.hex` |

Depois de qualquer passo que gere `.hex`, rode `./sim/run_regressao.sh`: os
testbenches leem os valores novos, nenhum precisa ser editado à mão.

> Regerar `arvore.hex` ou `demo_amostras.hex` muda o comportamento na placa, e o
> `tb_Equivalencia` passa a acusar diferença. É esperado, mas deve ser feito de
> propósito.

## Dataset e pré-processamento

Jung et al., *Data in Brief* 48 (2023) 109049, KAIST. Motor a 3010 rpm
(50,17 Hz), cargas de 0, 2 e 4 N·m, acelerômetros a 25,6 kHz. Usa-se o
**Canal1 (x do mancal A)**: é onde o pico na rotação cresce com o
desbalanceamento. Quatro classes: normal, desbalanceamento, desalinhamento e
rolamento (BPFI + BPFO).

Do sinal à imagem (igual ao hardware):

1. escala Q1.15 (±32 g = ±1);
2. FIR passa-baixa de 63 taps (corte em 1,4 kHz) e decimação ÷8, de 25,6 para 3,2 kHz,
   o que dá raias de 50 Hz;
3. FFT de 64 pontos a cada 32 amostras (10 ms), saída ÷16;
4. |X| dos bins 0..31 e log2 de Mitchell;
5. 32 FFTs formam a imagem 32×32 (linha = frequência, coluna = tempo).

A divisão é feita **por tempo dentro de cada arquivo**: 70% para treino, 15% para
validação e 15% para teste. Assim, nenhuma imagem de teste tem amostras vistas no treino.

## CNN

A mesma rede do RTL: conv 3×3 ×8 + bias → saturação/ReLU → maxpool 2×2 → média
global → densa 8×4 → argmax. São **116 parâmetros**.

Durante o treino valem as mesmas restrições do hardware: pesos limitados a
[−1, 1), quantização simulada (QAT) e saturação nos mesmos pontos. O modelo
escolhido é o melhor na validação **calculada pelo modelo bit-exato**, ou seja,
o melhor no hardware.

Resultado no teste, com o ponto fixo bit-exato (o mesmo que o FPGA calcula):

| pesos | acurácia |
|---|---|
| **16 bits (gravado na ROM)** | **83,2%** (balanceada 82,1%) |
| 8 bits, só arredondando | 83,3% |
| 8 bits, QAT | 81,3% |
| 4 bits, só arredondando / QAT | 68,7% / 70,2% |

Rolamento: 100%. Os erros se concentram nas falhas leves (0,1 mm e 583 mg) e no
normal com 4 N·m.

O limite está na média global (GAP), que descarta *em que frequência* está a
energia. Trocar a GAP por uma média só no tempo (densa 128×4) daria 93,7% de
acurácia balanceada na validação.

## Árvore de decisão

São 12 características: 8 espectrais, r_lms e rho1..3 (detalhes em
`smma/features.py`). A árvore tem profundidade 9 e 141 nós (564 B de ROM, 0
multiplicadores), contra um SVM‑RBF que precisaria de 22 452 multiplicações por
decisão.

| | 0 N·m | 2 N·m | 4 N·m | geral |
|---|---|---|---|---|
| **Árvore** (Q1.15 = FPGA) | 0,9725 | 0,9354 | 0,8832 | 0,9321 |
| CNN | 0,893 | 0,862 | 0,738 | 0,832 |

O ponto fixo e o float discordam em 0,15% das janelas. Matriz de confusão e
curva profundidade × acurácia em `resultados/relatorio_clf.md`.
