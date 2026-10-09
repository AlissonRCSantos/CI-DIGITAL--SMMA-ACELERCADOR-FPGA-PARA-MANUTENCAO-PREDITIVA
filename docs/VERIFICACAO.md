# SMMA — Verificação (simulação)

## Como rodar

```bash
./sim/run_regressao.sh                 # os 39 testbenches (Icarus Verilog, ~4 min)
./sim/run_regressao.sh tb_SMMA_Top     # só os que casam com o nome
./sim/run_regressao.sh matriz          # ... ou com parte do caminho/nome
```

No Windows, rode pelo **Git Bash** (`bash sim/run_regressao.sh`). Requer
`iverilog` 11+. Para Xcelium (laboratório): `./sim/run_xcelium.sh tb_SMMA_Top`.
Para ModelSim, a partir de `quartus/`: `do ../sim/modelsim/sim_tb.do tb_SMMA_Top`.

Um testbench só é aprovado se (a) nenhuma linha começa com `[FAIL]`/`[ERRO]`,
(b) todo contador de falhas impresso é zero e (c) há uma frase de sucesso.

## Resultado atual: 39/39 aprovados

| grupo | testbench | o que verifica |
|---|---|---|
| sistema | `tb_Equivalencia` | **mesmo comportamento da integração anterior**: 12 features, 4 scores da CNN e todos os pinos do painel, bit a bit, nas 12 janelas |
| sistema | `tb_SMMA_Top` | ponta a ponta pelos pinos da placa: árvore = modelo Python nas 12 janelas, 11/12 corretas, f0 = 50 Hz com `SW[8]`, reuso sem reset |
| sistema | `tb_latencia` | carimba a latência de cada bloco numa janela em tempo real |
| sistema | `tb_Stream_Fork` | join com 3 consumidores aleatórios (base do `Data_Bus_Driver`): sem perda, sem duplicação, em ordem |
| entrada | `tb_Sample_Source`, `tb_FIR_Decimator` | ROM do dataset, taxa, FIR bit a bit com Python |
| buffers | `tb_Frame_Builder`, `tb_Spectrogram_Buffer` | quadros com salto 32; transposição 32×32 |
| FFT | `tb_FFT_Top`, `tb_FFT_Log2_Compress` | FFT bit a bit com o modelo, sob contrapressão; log2 nas 65 536 entradas |
| MDC | `tb_peak_detector`, `tb_mdc_gcd`, `tb_f0_estimator` | testbenches originais das branches |
| MDC | `tb_MDC_Chain` | cadeia completa como no top; **exemplo do enunciado: MDC(12,18,30) = 6 → 300 Hz**; harmônicos; sem picos → erro; reuso |
| LMS | `tb_LMS_*` (6) | testbenches originais da branch `feat/LMS` (o do `LMS_Control_FSM` teve as expectativas corrigidas, ver abaixo) |
| LMS | `tb_LMS_Stage` | estágio LMS em série como no top: 1056 amostras repassadas intactas sob contrapressão, r_lms **bit a bit** e y(n) = modelo Python, em 6 janelas reais |
| matriz | `tb_autocorrelacao_yw` | rho[0..3] **bit a bit** com Python em 6 janelas reais, ordem do protocolo `r_index` |
| matriz | `tb_gauss_jordan_inv` | inversas 2×2, 3×3 com troca de linhas, 4×4, matriz singular — em Q4.12 e Q8.16 |
| matriz | `tb_Yule_Walker_Solver` | autocorrelação → Yule-Walker → Gauss-Jordan; a1..a3 contra `numpy.linalg.solve`: desvio máx. 1 LSB |
| ML | `tb_Feature_Spectral` | `Spectrum_Accumulator` + `Feature_Spectral`: 8 janelas × 8 features bit a bit |
| ML | `tb_Parameter_RegFile` | 16 posições em ordem com chegada embaralhada, contrapressão, reuso |
| ML | `tb_ML_Tree_Classifier` | 64 vetores, classe = sklearn |
| CNN | `tb_CNN_*` (9) | cada bloco e a rede inteira com 8 espectrogramas reais, bit a bit com o golden model |
| comum | `tb_FP_Mult_Unit`, `tb_FP_Arith_Unit`, `tb_Divider_Q15` | aritmética Q1.15 (2005 multiplicações) |

### Correção no `tb_LMS_Control_FSM`

Na integração anterior esse testbench falhava (8 divergências), registrado
como "falha pré-existente da branch". A divergência estava nas **expectativas
do testbench**, não na FSM: ele esperava `wr_addr` com 4 ciclos de atraso e
`valid_out` combinacional no ciclo 12, enquanto a FSM registra `valid_out` (fica
visível no ciclo 13, alinhado ao `out_error` registrado do acumulador) e atrasa
`wr_addr` 5 ciclos — exatamente a latência de escrita da PE. É essa
temporização que faz o `LMS_Filter_Top` completo reproduzir o modelo Python
bit a bit em janelas de 1056 amostras (`tb_LMS_Stage`). As
expectativas foram ajustadas e o teste passa (32 verificações).

## Ordem recomendada de teste (de baixo para cima)

```
0. comum      FP_Mult_Unit, FP_Arith_Unit, Divider_Q15
1. entrada    Sample_Source, FIR_Decimator
2. buffers    Frame_Builder, Spectrogram_Buffer
3. FFT        FFT_Log2_Compress, FFT_Top
4. MDC        peak_detector, mdc_gcd, f0_estimator -> MDC_Chain
5. LMS        LMS_* (folhas) -> LMS_Filter_Top -> LMS_Stage
6. matriz     gauss_jordan_inv, autocorrelacao_yw -> Yule_Walker_Solver
7. ML         Feature_Spectral, Parameter_RegFile, ML_Tree_Classifier
8. CNN        CNN_* (folhas) -> CNN_Top
9. sistema    Stream_Fork -> SMMA_Top -> Equivalencia -> latencia
```

Indo de baixo para cima, um erro de arredondamento no multiplicador aparece no
teste do multiplicador, e não como uma classe errada no top level.

Para sintetizar um módulo isolado no Quartus: no *Project Navigator → Files*,
botão direito no arquivo → **Set as Top-Level Entity** → *Start Analysis &
Synthesis* (não rode o Fitter em submódulos: as portas largas não cabem nos
pinos). Depois, volte `SMMA_Top` como top.

## Vetores de teste

Todos em `quartus/vetores/`, gerados pelos scripts de `python/scripts/`
(exceto `equiv_esperado.hex`, capturado da simulação da integração anterior —
ver o cabeçalho do `tb_Equivalencia`).
