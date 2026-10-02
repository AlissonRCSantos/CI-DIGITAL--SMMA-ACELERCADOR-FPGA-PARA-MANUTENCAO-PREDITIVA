# Classificador numerico do SMMA (PBL 3.5)

Entradas: 12 caracteristicas (FFT + LMS + estimacao matricial).  
Saidas: 4 classes ['normal', 'desbalanceamento', 'desalinhamento', 'rolamento'].  
Conjunto de teste: 4021 janelas -- as MESMAS da CNN.


## Arvore de decisao: profundidade x acuracia

| Profundidade | Nos | Acuracia (valid) | Balanceada (valid) |
|---|---|---|---|
| 3 | 9 | 0.8093 | 0.8444 |
| 4 | 13 | 0.8093 | 0.8444 |
| 5 | 21 | 0.8335 | 0.8571 |
| 6 | 37 | 0.9076 | 0.8615 |
| 7 | 65 | 0.8914 | 0.8847 |
| 8 | 103 | 0.9171 | 0.8990 |
| 9 | 149 | 0.9390 | 0.9307 |
| 10 | 207 | 0.9346 | 0.9207 |
| 11 | 281 | 0.9506 | 0.9333 |
| 12 | 359 | 0.9511 | 0.9337 |

## Arvore x SVM-RBF (conjunto de teste)

| Modelo | Acuracia | Balanceada | Mult/decisao | Latencia (ciclos) | Memoria |
|---|---|---|---|---|---|
| Arvore de decisao | 0.9378 | 0.9124 | **0** | 12 | 1436 B |
| SVM-RBF | 0.9637 | 0.9602 | 22008 | ~22008 | 44016 B |

- Arvore: 359 nos, profundidade 12
- SVM: 1834 vetores de suporte x 12 features

## Modelo escolhido: arvore de decisao

Profundidade 9, 149 nos (74 internos,
75 folhas), 596 bytes de ROM.

| | Acuracia | Balanceada |
|---|---|---|
| float (sklearn) | 0.9269 | 0.9069 |
| Q1.15 (= FPGA) | 0.9276 | 0.9073 |

Float e ponto fixo discordam em 0.075% das janelas.

### Acerto por carga (comparado a CNN nas MESMAS janelas)

| Carga | Arvore acc | Arvore bal | CNN acc | CNN bal |
|---|---|---|---|---|
| 0 Nm | 0.9718 | 0.9723 | 0.8930 | 0.8940 |
| 2 Nm | 0.9408 | 0.9407 | 0.8560 | 0.8450 |
| 4 Nm | 0.8645 | 0.7247 | 0.7380 | 0.6490 |

### Matriz de confusao (Q1.15)

| real \ predito | normal | desbalanceamento | desalinhamento | rolamento | acerto |
|---|---|---|---|---|---|
| **normal** | 369 | 113 | 11 | 0 | 74.8% |
| **desbalanceamento** | 75 | 1492 | 53 | 0 | 92.1% |
| **desalinhamento** | 23 | 16 | 933 | 0 | 96.0% |
| **rolamento** | 0 | 0 | 0 | 936 | 100.0% |

### Recursos

| | Arvore |
|---|---|
| Multiplicadores (DSP) | **0** -- so comparacoes |
| Memoria | 596 B (ROM de nos) |
| Latencia | 12 ciclos de carga + 2 por nivel; medido 21 ciclos (420 ns @ 50 MHz) |
| Entradas | 12 features Q1.15 |
| Saidas | 2 bits (classe) + valid |
