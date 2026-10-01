# Resultado do treinamento da CNN do SMMA

Conjunto de TESTE: 4021 espectrogramas 32x32 (os ultimos 15% de cada arquivo, nunca vistos no treino).  
Acuracia balanceada = media do acerto de cada classe.

## Float x ponto fixo x numero de bits

| Pesos | Treino | Acuracia float | Acuracia ponto fixo (bit-exata, = FPGA) | Balanceada ponto fixo |
|---|---|---|---|---|
| 16 bits | QAT (treino ciente) | 0.8319 | 0.8319 | 0.8209 |
| 8 bits | PTQ (so arredonda) | - | 0.8334 | 0.8156 |
| 4 bits | PTQ (so arredonda) | - | 0.6866 | 0.6382 |
| 8 bits | QAT (treino ciente) | 0.8097 | 0.8130 | 0.7907 |
| 4 bits | QAT (treino ciente) | 0.4929 | 0.7018 | 0.6032 |

Modelo de 16 bits: float e ponto fixo discordam em 0.02% das imagens.

## Matriz de confusao (16 bits, ponto fixo)

| real \ predito | normal | desbalanceamento | desalinhamento | rolamento | acerto |
|---|---|---|---|---|---|
| **normal** | 365 | 64 | 64 | 0 | 74.0% |
| **desbalanceamento** | 160 | 1360 | 100 | 0 | 84.0% |
| **desalinhamento** | 211 | 77 | 684 | 0 | 70.4% |
| **rolamento** | 0 | 0 | 0 | 936 | 100.0% |

## Acerto por arquivo (condicao / severidade / carga)

| Arquivo | Classe | Imagens | Acerto |
|---|---|---|---|
| 0Nm_BPFI_03 | rolamento | 52 | 100% |
| 0Nm_BPFI_10 | rolamento | 52 | 100% |
| 0Nm_BPFI_30 | rolamento | 52 | 100% |
| 0Nm_BPFO_03 | rolamento | 52 | 100% |
| 0Nm_BPFO_10 | rolamento | 52 | 100% |
| 0Nm_BPFO_30 | rolamento | 52 | 100% |
| 0Nm_Misalign_01 | desalinhamento | 108 | 22% |
| 0Nm_Misalign_03 | desalinhamento | 108 | 100% |
| 0Nm_Misalign_05 | desalinhamento | 108 | 100% |
| 0Nm_Normal | normal | 277 | 93% |
| 0Nm_Unbalance_0583mg | desbalanceamento | 108 | 70% |
| 0Nm_Unbalance_1169mg | desbalanceamento | 108 | 83% |
| 0Nm_Unbalance_1751mg | desbalanceamento | 108 | 98% |
| 0Nm_Unbalance_2239mg | desbalanceamento | 108 | 100% |
| 0Nm_Unbalance_3318mg | desbalanceamento | 108 | 100% |
| 2Nm_BPFI_03 | rolamento | 52 | 100% |
| 2Nm_BPFI_10 | rolamento | 52 | 100% |
| 2Nm_BPFI_30 | rolamento | 52 | 100% |
| 2Nm_BPFO_03 | rolamento | 52 | 100% |
| 2Nm_BPFO_10 | rolamento | 52 | 100% |
| 2Nm_BPFO_30 | rolamento | 52 | 100% |
| 2Nm_Misalign_01 | desalinhamento | 108 | 48% |
| 2Nm_Misalign_03 | desalinhamento | 108 | 100% |
| 2Nm_Misalign_05 | desalinhamento | 108 | 100% |
| 2Nm_Normal | normal | 108 | 74% |
| 2Nm_Unbalance_0583mg | desbalanceamento | 108 | 51% |
| 2Nm_Unbalance_1169mg | desbalanceamento | 108 | 71% |
| 2Nm_Unbalance_1751mg | desbalanceamento | 108 | 89% |
| 2Nm_Unbalance_2239mg | desbalanceamento | 108 | 98% |
| 2Nm_Unbalance_3318mg | desbalanceamento | 108 | 97% |
| 4Nm_BPFI_03 | rolamento | 52 | 100% |
| 4Nm_BPFI_10 | rolamento | 52 | 100% |
| 4Nm_BPFI_30 | rolamento | 52 | 100% |
| 4Nm_BPFO_03 | rolamento | 52 | 100% |
| 4Nm_BPFO_10 | rolamento | 52 | 100% |
| 4Nm_BPFO_30 | rolamento | 52 | 100% |
| 4Nm_Misalign_01 | desalinhamento | 108 | 8% |
| 4Nm_Misalign_03 | desalinhamento | 108 | 58% |
| 4Nm_Misalign_05 | desalinhamento | 108 | 96% |
| 4Nm_Normal | normal | 108 | 25% |
| 4Nm_Unbalance_0583mg | desbalanceamento | 108 | 46% |
| 4Nm_Unbalance_1169mg | desbalanceamento | 108 | 76% |
| 4Nm_Unbalance_1751mg | desbalanceamento | 108 | 89% |
| 4Nm_Unbalance_2239mg | desbalanceamento | 108 | 94% |
| 4Nm_Unbalance_3318mg | desbalanceamento | 108 | 95% |

## Acerto por carga

| Carga | Acerto | Balanceada |
|---|---|---|
| 0Nm | 89.3% | 89.4% |
| 2Nm | 85.6% | 84.5% |
| 4Nm | 73.8% | 64.9% |
