# Classificador numerico do SMMA (PBL 3.5)

Entradas: 12 caracteristicas (FFT + LMS + estimacao matricial).  
Saidas: 4 classes ['normal', 'desbalanceamento', 'desalinhamento', 'rolamento'].  
Conjunto de teste: 4021 janelas -- as MESMAS da CNN.


## Arvore de decisao: profundidade x acuracia

| Profundidade | Nos | Acuracia (valid) | Balanceada (valid) |
|---|---|---|---|
| 3 | 9 | 0.8096 | 0.8446 |
| 4 | 13 | 0.8096 | 0.8446 |
| 5 | 21 | 0.8332 | 0.8553 |
| 6 | 37 | 0.9076 | 0.8625 |
| 7 | 65 | 0.8914 | 0.8828 |
| 8 | 107 | 0.9197 | 0.8969 |
| 9 | 153 | 0.9406 | 0.9286 |
| 10 | 213 | 0.9411 | 0.9235 |
| 11 | 275 | 0.9447 | 0.9266 |
| 12 | 359 | 0.9470 | 0.9279 |

## Arvore x SVM-RBF (conjunto de teste)

| Modelo | Acuracia | Balanceada | Mult/decisao | Latencia (ciclos) | Memoria |
|---|---|---|---|---|---|
| Arvore de decisao | 0.9333 | 0.9118 | **0** | 9 | 612 B |
| SVM-RBF | 0.9647 | 0.9620 | 22104 | ~22104 | 44208 B |

- Arvore: 153 nos, profundidade 9
- SVM: 1842 vetores de suporte x 12 features

## Modelo escolhido: arvore de decisao

Profundidade 9, 153 nos (76 internos,
77 folhas), 612 bytes de ROM.

| | Acuracia | Balanceada |
|---|---|---|
| float (sklearn) | 0.9333 | 0.9118 |
| Q1.15 (= FPGA) | 0.9331 | 0.9117 |

Float e ponto fixo discordam em 0.124% das janelas.

### Acerto por carga (comparado a CNN nas MESMAS janelas)

| Carga | Arvore acc | Arvore bal | CNN acc | CNN bal |
|---|---|---|---|---|
| 0 Nm | 0.9683 | 0.9699 | 0.8930 | 0.8940 |
| 2 Nm | 0.9439 | 0.9429 | 0.8560 | 0.8450 |
| 4 Nm | 0.8824 | 0.7418 | 0.7380 | 0.6490 |

### Matriz de confusao (Q1.15)

| real \ predito | normal | desbalanceamento | desalinhamento | rolamento | acerto |
|---|---|---|---|---|---|
| **normal** | 372 | 108 | 13 | 0 | 75.5% |
| **desbalanceamento** | 77 | 1512 | 31 | 0 | 93.3% |
| **desalinhamento** | 21 | 19 | 932 | 0 | 95.9% |
| **rolamento** | 0 | 0 | 0 | 936 | 100.0% |

### Recursos

| | Arvore |
|---|---|
| Multiplicadores (DSP) | **0** -- so comparacoes |
| Memoria | 612 B (ROM de nos) |
| Latencia | 12 ciclos de carga + 2 por nivel; medido 21 ciclos (420 ns @ 50 MHz) |
| Entradas | 12 features Q1.15 |
| Saidas | 2 bits (classe) + valid |
