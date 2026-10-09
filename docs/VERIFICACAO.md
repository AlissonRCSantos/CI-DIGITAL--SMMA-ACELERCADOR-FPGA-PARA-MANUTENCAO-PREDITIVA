# SMMA — Verificação (simulação)

```bash
./sim/run_regressao.sh                 # os 39 testbenches (Icarus Verilog 11+, ~4 min)
./sim/run_regressao.sh tb_SMMA_Top     # só os que casam com o nome
```

No Windows, rode pelo **Git Bash**. Outras opções:
- ModelSim, a partir de `quartus/`: `do ../sim/modelsim/sim_tb.do <tb>`;
- Xcelium: `./sim/run_xcelium.sh <tb>`.

Um testbench só é aprovado se três coisas valerem ao mesmo tempo:
- nenhuma linha começa com `[FAIL]`/`[ERRO]`;
- todo contador de falhas é zero;
- aparece a frase de sucesso.

**Resultado atual: 39/39 aprovados.**

| pasta (`sim/tb/`) | testbenches | o que verifica |
|---|---|---|
| `top` | `tb_Equivalencia` | mesmo comportamento da integração gravada na placa: características, scores da CNN e pinos do painel, bit a bit, nas 12 janelas |
| `top` | `tb_SMMA_Top` | ponta a ponta pelos pinos: árvore = modelo Python, 11/12 corretas, f0 = 50 Hz, reuso sem reset |
| `top` | `tb_latencia` | latência de cada bloco numa janela |
| `barramento` | `tb_Stream_Fork` | join com 3 consumidores: sem perda, sem duplicação, em ordem |
| `entrada` | `tb_Sample_Source`, `tb_FIR_Decimator` | ROM do dataset, taxa, FIR bit a bit com Python |
| `lms` | `tb_LMS_*` (7) | blocos do LMS; `tb_LMS_Stage`: repasse intacto sob contrapressão e r_lms bit a bit |
| `memorias` | `tb_Frame_Builder` | quadros de 64 com salto 32 |
| `fft` | `tb_FFT_Top` | FFT bit a bit com o modelo, sob contrapressão |
| `mdc` | `tb_peak_detector`, `tb_mdc_gcd`, `tb_f0_estimator`, `tb_MDC_Chain` | cadeia completa; exemplo do enunciado MDC(12,18,30) = 6 |
| `matriz` | `tb_autocorrelacao_yw`, `tb_gauss_jordan_inv`, `tb_Yule_Walker_Solver` | rho bit a bit; inversas 2×2 a 4×4 e singular; a1..a3 a 1 LSB do numpy |
| `ml` | `tb_Feature_Spectral`, `tb_Parameter_RegFile`, `tb_ML_Tree_Classifier` | características bit a bit; vetor de 16; classe = sklearn |
| `cnn` | `tb_CNN_*` (9), `tb_FFT_Log2_Compress`, `tb_Spectrogram_Buffer` | cada bloco e a rede inteira com 8 espectrogramas reais, bit a bit |
| `aritmetica` | `tb_FP_Mult_Unit`, `tb_FP_Arith_Unit`, `tb_Divider_Q15` | aritmética Q1.15 |

Ordem recomendada, de baixo para cima: aritmética → entrada → memórias → FFT →
MDC → LMS → matriz → ML → CNN → top. Indo nessa ordem, um erro aparece no teste
do bloco que o causou, e não como uma classe errada no top.

Os vetores de teste ficam em `quartus/vetores/` e são gerados por
`python/scripts/`. A exceção é o `equiv_esperado.hex`, capturado da integração
gravada na placa.
