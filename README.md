# CI-DIGITAL--SMMA-ACELERCADOR-FPGA-PARA-MANUTENCAO-PREDITIVA
Acelerador Digital para Monitoramento Inteligente de Máquinas Industriais

## Sobre esta branch

`top_level` integra **todos os módulos desenvolvidos nas branches de feature**
do projeto em um único lugar (todos sob `RTL/`), servindo de base para a
montagem do **top-level** a ser sintetizado no Quartus. Cada módulo mantém sua
própria documentação (cabeçalho do `.v` ou um README dedicado); este arquivo é
só o mapa de onde encontrar cada peça.

As branches de origem (preservadas, cada uma com seu próprio histórico):
`fft`, `feat/CNN`, `feat/LMS`, `feat/MDC`, `feat/fixed_poit`, `feat/frequency`,
`feat/peak_detector`, `feat/inverse-matrix`.

## Pipeline do sistema

```
vibração (ADC) -> FFT -> detector de picos -> MDC (f0) -> features -> CNN -> classe da falha
                                                        -> filtro LMS (ruido) -> AR / Gauss-Jordan
```

## Módulos (em `RTL/`)

| Módulo | Arquivos principais | O que faz |
|---|---|---|
| **FFT** | `FFT_Top.v` + `FFT_*.v` | FFT radix-2 DIT de 64 pontos, in-place, Q1.15. Ver cabeçalho de `FFT_Top.v`. |
| **CNN** | `CNN_Top.v` + `CNN_*.v` | Classificador CNN (conv + pooling + dense) para diagnóstico de falha. Treino e exportação de pesos em `python/` — ver [RTL/README_CNN.md](RTL/README_CNN.md). |
| **LMS** | `LMS_Filter_Top.v` + `LMS_*.v` | Filtro adaptativo LMS (cancelamento de ruído/componentes indesejadas do sinal). |
| **MDC** | `mdc_gcd.v` | Máximo divisor comum dos bins de pico, usado para estimar a frequência fundamental a partir dos harmônicos. |
| **Detector de picos** | `peak_detector.v` | Localiza os bins de maior energia no espectro de saída da FFT. |
| **Estimador de frequência** | `f0_estimator.v` | Estima a frequência fundamental (f0) a partir dos índices de pico. |
| **Autocorrelação / Inversão matricial** | `autocorrelacao_yw.v`, `gauss_jordan_inv (2).v`, `fixed_point_divider (1).v` | Autocorrelação de Yule-Walker e inversão via Gauss-Jordan, para modelagem AR do sinal. Detalhes em [RTL/readme_AR_INV.txt](RTL/readme_AR_INV.txt). |
| **Ponto fixo (comum)** | `FP_Mult_Unit.v`, `FP_Arith_Unit.v` | Multiplicador e somador/subtrator parametrizáveis em ponto fixo, usados por FFT, LMS e outros módulos. |

Cada módulo tem seu(s) testbench(es) próprio(s) (`tb_*.v` / `*_tb.v`), em
geral autoverificáveis (comparam contra um modelo de referência e imprimem
PASS/FAIL).

## Próximos passos

O top-level de integração (instanciando os módulos acima em um único
`SMMA_Top.v`, com o mapeamento de pinos da placa de destino) ainda será
criado nesta branch.
