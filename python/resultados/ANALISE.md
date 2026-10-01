# Análise do treinamento (escrita à mão; `relatorio.md` é gerado pelo passo 04)

## Resultado principal
Arquitetura exatamente como está no RTL (conv 3x3 x8 + ReLU + maxpool 2x2 + GAP +
densa 8x4), pesos de 16 bits em Q1.15, conjunto de TESTE (4021 imagens nunca vistas):

* **Acurácia 83,2 %, balanceada 82,1 %** — em ponto fixo bit-exato (= o que o FPGA calcula).
* Float e ponto fixo discordam em só 0,02 % das imagens: 16 bits Q1.15 não custa precisão.
* **Rolamento: 100 %** em todas as severidades e cargas.
* Desbalanceamento a partir de 1751 mg e desalinhamento a partir de 0,3 mm: 89–100 %
  (exceto 4 Nm / 0,3 mm: 58 %).
* Os erros se concentram nas falhas **leves** (desalinhamento 0,1 mm, desbalanceamento
  583 mg) e no **normal com 4 Nm** — espectros praticamente iguais ao normal.

## Quantização (diferencial do enunciado, seção 9)
| Pesos | Acurácia ponto fixo | Observação |
|---|---|---|
| 16 bits | 83,2 % | modelo gravado na ROM |
| 8 bits (só arredondando o de 16) | 83,3 % | **mesma acurácia com metade dos bits** |
| 8 bits (treino ciente, QAT) | 81,3 % | variação de treino; não superou o PTQ |
| 4 bits (só arredondando) | 68,7 % | perda clara |
| 4 bits (QAT) | 70,2 % | QAT recupera um pouco; 4 bits é pouco para esta rede |

Obs.: na linha "4 bits QAT" do relatorio.md a coluna "float" (49 %) usa os pesos
não-quantizados de um modelo que foi treinado para 4 bits — não tem significado prático.

## Limitação encontrada: a camada GAP
A média global (GAP) joga fora **em que frequência** está a energia; a rede só sabe
"quanto de cada padrão 3x3 existe na imagem". Experimentos (validação, float, mesma
camada convolucional de 8 filtros do enunciado, só trocando a classificação):

| Camada de classificação | Pesos na densa | Acurácia balanceada (validação) |
|---|---|---|
| GAP -> densa 8x4 (**RTL atual**) | 32 | ~80 % |
| média só no TEMPO (16 bins x 8 filtros) -> densa 128x4 | 512 | **93,7 %** |
| sem média (mapa 16x16x8 inteiro) -> densa 2048x4 | 8192 | 95,1 % |
| (referência) CNN maior, 2 camadas conv | ~130 mil | 97,1 % |

A variante "média só no tempo" mantém a informação de frequência, custa 512 pesos
(1 bloco M10K ou LUTs) e ~512 MACs extras por imagem (~10 µs a 50 MHz) — seria a
melhoria mais barata, mas exige alterar o `CNN_Dense_Classifier.v`.

Também por causa do GAP, 4 dos 8 filtros terminam "mortos" (feature sempre 0) —
a rede não consegue usá-los. Isso foi mitigado no treino (bias inicial positivo e
gradiente com vazamento só no backward), sem ganho relevante: o limite é a arquitetura.
