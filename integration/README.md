# Integração SMMA

`RTL/SMMA_Top.v` integra estes blocos das branches remotas:

- `feat/LMS`: filtro adaptativo de 8 taps;
- `fft`: FFT radix-2 de 64 pontos e unidades de ponto fixo;
- `feat/peak_detector`: detector dos três maiores picos locais;
- `feat/MDC`: MDC dos três bins detectados;
- `feat/frequency`: estimador de frequência fundamental;
- `feat/CNN`: classificador CNN;
- `feat/inverse-matrix`: inversor Gauss-Jordan e divisor;
- `feat/fixed_poit`: a branch remota usa esse nome (typo); contém as unidades de ponto fixo também presentes no LMS/FFT. A integração mantém uma única cópia dessas unidades.

O fluxo conectado é **LMS → buffer de 64 amostras → FFT → detector de picos → MDC → f0**. O top aceita uma amostra LMS por vez (`sample_start` e `sample_valid` juntos, quando `sample_ready` está alto). `analysis_done` sinaliza a conclusão da cadeia espectral e libera uma nova janela. Os bins de pico são transmitidos internamente com `valid/ready`; o bin fundamental e a frequência ficam nas saídas `fundamental_bin`, `fundamental_hz_int` e `fundamental_hz_frac`.

A CNN e o inversor também são instanciados no top, mas usam interfaces independentes. O PBL não especifica uma conversão direta das amostras/saídas LMS em espectrograma 32×32, nem define a matriz de estimação e sua origem. Portanto, o espectrograma é fornecido pela interface `cnn_*` e a matriz pela interface `inv_*`. A CNN espera 1024 pixels assinados Q1.15 em ordem raster; carregue todos os elementos de A antes de `inv_start`.

## Requisitos considerados

- Clock alvo de 50 MHz, reset ativo alto e habilitação global.
- Janela da FFT com 64 amostras; índices espectrais de 6 bits.
- LMS com 8 coeficientes; formato padrão Q1.15.
- Três picos acima de `peak_threshold`; `min_gcd_bin` filtra MDC inválido.
- Frequência fundamental calculada a partir de `sample_rate_hz` e do bin MDC.
- CNN para imagem 32×32×1 e quatro classes.
- Inversão Gauss-Jordan até 4×4, com tratamento de pivô pequeno pelo epsilon.
- Sinais de handshaking e estado de conclusão entre os módulos conectados.

## Fontes e compilação

As fontes originais foram preservadas em `RTL/blocks/` e copiadas diretamente das branches; `top_level` não foi usado. As unidades `FP_Arith_Unit` e `FP_Mult_Unit`, duplicadas nas branches de LMS e FFT, aparecem uma vez em `blocks/fixed_point/`.

Com Icarus Verilog, a partir de `integration/RTL`:

```sh
iverilog -g2012 -s SMMA_Top -o smma_top.out -f filelist.f
```

Essa integração conecta e organiza os módulos existentes; ela não altera seus algoritmos internos nem implica validação de temporização/síntese na FPGA-alvo.

## Inserir os arquivos de `vibração/`

Os arquivos `.mat` não são uma memória de entrada que o FPGA consiga abrir em runtime. Eles são arquivos MATLAB para preparação offline/simulação. A leitura representativa de `4Nm_Normal.mat` encontrou:

- `Signal.y_values.values`: matriz `3072000 × 4` de `double`, com unidade `g`;
- `Signal.x_values.increment = 3.90625e-5 s`, portanto `fs = 25,600 Hz`;
- `Signal.function_record.primary_channel.label`: `Point1` a `Point4`;
- o canal Point1 do arquivo verificado teve pico de `9.58 g`.

O script `integration/tools/export_vibration_mat.m` transforma um `.mat` em uma palavra hex por amostra: `{sample_d[15:0], sample_x[15:0]}`. Ele usa Q1.15 com escala configurável e, por padrão, `±32 g`, igual à escala definida no fluxo da CNN da branch `feat/CNN`. Por padrão exporta 64 amostras para uma primeira janela; `maxSamples=0` exporta o arquivo inteiro. O segundo canal LMS é configurável: por padrão copia o canal selecionado para `d`; use dois canais distintos somente quando o papel do canal de referência estiver definido.

Exemplo no MATLAB, a partir da raiz do repositório:

```matlab
export_vibration_mat('vibração/4Nm_Normal.mat', ...
    'integration/data/vibration_input.hex', 1, 1, 32, 64)
```

O último `64` limita a exportação a uma janela de FFT. O argumento `1` seleciona Point1 tanto como `sample_x` quanto como `sample_d`. Para transmitir todos os dados do arquivo, troque `64` por `0`; para selecionar canais diferentes, altere os argumentos terceiro e quarto. O script informa a taxa, canais e quantidade de amostras saturadas.

Para simular, o testbench deve ler `integration/data/vibration_input.hex` com `$readmemh`. Cada palavra tem `sample_x` nos 16 bits baixos e `sample_d` nos 16 bits altos. Para cada palavra, aguarde `sample_ready`, mantenha `sample_start=sample_valid=1` por um ciclo e avance o índice. O top recolhe 64 saídas LMS, executa a FFT e sinaliza `analysis_done`; configure `sample_rate_hz=25600`. No FPGA físico, uma interface de aquisição deve fornecer as amostras pela mesma interface `sample_*`; o arquivo MATLAB não é lido pelo hardware.

O `FFT_Top` integrado processa diretamente os 64 valores recebidos a 25,6 kHz (bin de 400 Hz). A entrada da CNN continua sendo independente: a branch `feat/CNN` define outra preparação para espectrograma — FIR de 63 taps, decimação ×8, FFT de 64 pontos com hop de 32, magnitude e compressão log2 — resultando em pixels 32×32 Q1.15. Esses 1024 pixels precisam ser gerados e enviados pela interface `cnn_*`; o top atual não contém esse pré-processamento. A documentação Python da branch associa seus CSVs a `x_A/y_A/x_B/y_B`, mas os MAT inspecionados identificam os canais apenas como Point1–Point4, então a correspondência física deve ser confirmada antes de fixar o canal para classificação.
