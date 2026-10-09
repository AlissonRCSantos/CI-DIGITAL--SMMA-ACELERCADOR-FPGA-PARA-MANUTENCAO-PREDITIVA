# Arquitetura do `SMMA_Top`

O diagrama mostra os dois caminhos que processam a janela de vibração no modo padrão (`USE_VIBRATION_ROM=1`): o caminho de features/classificação automática e o caminho de análise LMS/FFT já integrado. A inversão de matriz permanece como interface independente.

```mermaid
flowchart LR
    ROM["Vibration_ROM_Source\nROM síncrona: vibration_input.hex"]
    DEC[FIR_Decimator]
    FB[Frame_Builder]
    FFTF["FFT_Top\nFFT de features"]
    SPEC[Feature_Spectral]
    TEMP[Feature_Temporal]
    PACK["Vetor com 12 features"]
    TREE["ML_Tree_Classifier\nárvore de decisão"]
    LOG[FFT_Log2_Compress]
    BUF[Spectrogram_Buffer]
    CNN["CNN_Top\nclassificação da imagem"]

    ROM -->|amostras x/d| DEC
    DEC -->|1056 amostras decimadas| FB
    FB -->|32 frames, 64 pontos, hop 32| FFTF
    FFTF -->|magnitudes| SPEC
    SPEC -->|8 features espectrais| PACK
    TEMP -->|4 features temporais| PACK
    DEC --> TEMP
    PACK --> TREE
    TREE -->|classe e confiança| OUTT[Saídas automáticas da árvore]
    FFTF -->|magnitudes dos bins| LOG
    LOG -->|pixels comprimidos| BUF
    BUF -->|imagem 32 x 32| CNN
    CNN -->|classe e confiança| OUTC[Saídas automáticas da CNN]

    subgraph LEGACY["Caminho de análise integrado existente"]
      LMS[LMS_Filter_Top]
      FFT["FFT_Top\nFFT de análise"]
      PEAK[Peak_Detector]
      MDC[MDC]
      FREQ[Frequency_Estimator]
      LMS --> FFT --> PEAK --> MDC --> FREQ
    end
    ROM -->|mesma amostra x/d| LMS
    FREQ --> OUTF[Resultados de frequência e picos]

    EXT["Entrada externa sample_x/sample_d\nquando USE_VIBRATION_ROM=0"] -. alternativa .-> LMS

    INV["Inverse Matrix Solver\ninterface independente"]
    MAT["matrix_in / start\n(entradas externas)"] --> INV
    INV --> MATOUT["matrix_out / done"]

    START[dataset_start] --> ROM
    ROM --> STATUS["dataset_busy / dataset_done"]
```

## Notas de configuração

- `dataset_start` inicia a leitura da ROM; `dataset_busy` e `dataset_done` indicam o estado da janela.
- A ROM fornece os pares `{d, x}` em formato de ponto fixo. A fonte pode usar o divisor de relógio de amostragem ou o modo rápido de simulação.
- `USE_VIBRATION_ROM=0` seleciona o fluxo externo de amostras. `AUTO_CNN_FROM_VIBRATION=0` mantém a interface externa de pixels da CNN.
- A árvore recebe oito features espectrais e quatro temporais. A imagem da CNN é formada a partir das magnitudes da FFT.
- O caminho LMS/FFT/Peak/MDC/Frequency continua em paralelo. A inversão de matriz não é alimentada pelo dataset automaticamente.
