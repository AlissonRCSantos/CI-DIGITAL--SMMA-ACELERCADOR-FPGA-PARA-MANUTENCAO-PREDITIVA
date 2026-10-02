# Classificador numerico do SMMA (PBL 3.5)

Entradas: 12 caracteristicas (FFT + LMS + estimacao matricial).  
Saidas: 4 classes ['normal', 'desbalanceamento', 'desalinhamento', 'rolamento'].  
Conjunto de teste: 4021 janelas -- as MESMAS da CNN.


## Arvore de decisao: profundidade x acuracia

| Profundidade | Nos | Acuracia (valid) | Balanceada (valid) |
|---|---|---|---|
| 3 | 9 | 0.8093 | 0.8444 |
| 4 | 13 | 0.8093 | 0.8444 |
| 5 | 21 | 0.8356 | 0.8602 |
| 6 | 37 | 0.8762 | 0.9126 |
| 7 | 65 | 0.9403 | 0.9064 |
| 8 | 101 | 0.9310 | 0.9244 |
| 9 | 141 | 0.9480 | 0.9252 |
| 10 | 189 | 0.9467 | 0.9344 |
| 11 | 237 | 0.9514 | 0.9341 |
| 12 | 291 | 0.9529 | 0.9324 |

## Arvore x SVM-RBF (conjunto de teste)

| Modelo | Acuracia | Balanceada | Mult/decisao | Latencia (ciclos) | Memoria |
|---|---|---|---|---|---|
| Arvore de decisao | 0.9376 | 0.9131 | **0** | 10 | 756 B |
| SVM-RBF | 0.9624 | 0.9541 | 22452 | ~22452 | 44904 B |

- Arvore: 189 nos, profundidade 10
- SVM: 1871 vetores de suporte x 12 features

## Modelo escolhido: arvore de decisao

Profundidade 9, 141 nos (70 internos,
71 folhas), 564 bytes de ROM.

| | Acuracia | Balanceada |
|---|---|---|
| float (sklearn) | 0.9321 | 0.9006 |
| Q1.15 (= FPGA) | 0.9321 | 0.9009 |

Float e ponto fixo discordam em 0.149% das janelas.

### Acerto por carga (comparado a CNN nas MESMAS janelas)

| Carga | Arvore acc | Arvore bal | CNN acc | CNN bal |
|---|---|---|---|---|
| 0 Nm | 0.9725 | 0.9727 | 0.8930 | 0.8940 |
| 2 Nm | 0.9354 | 0.9134 | 0.8560 | 0.8450 |
| 4 Nm | 0.8832 | 0.7191 | 0.7380 | 0.6490 |

### Matriz de confusao (Q1.15)

| real \ predito | normal | desbalanceamento | desalinhamento | rolamento | acerto |
|---|---|---|---|---|---|
| **normal** | 347 | 133 | 13 | 0 | 70.4% |
| **desbalanceamento** | 73 | 1546 | 1 | 0 | 95.4% |
| **desalinhamento** | 10 | 43 | 919 | 0 | 94.5% |
| **rolamento** | 0 | 0 | 0 | 936 | 100.0% |

### Recursos

| | Arvore |
|---|---|
| Multiplicadores (DSP) | **0** -- so comparacoes |
| Memoria | 564 B (ROM de nos) |
| Latencia | 12 ciclos de carga + 2 por nivel; medido 21 ciclos (420 ns @ 50 MHz) |
| Entradas | 12 features Q1.15 |
| Saidas | 2 bits (classe) + valid |
